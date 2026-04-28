// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ILAWPComplianceEngine } from "../interfaces/ILAWPComplianceEngine.sol";
import { ILAWPTreasury } from "../interfaces/ILAWPTreasury.sol";
import { ILAWPImpactToken } from "../interfaces/ILAWPImpactToken.sol";
import { ILAWPActorRegistry } from "../interfaces/ILAWPActorRegistry.sol";
import { LAWPStructs } from "../libraries/LAWPStructs.sol";
import { LAWPErrors } from "../libraries/LAWPErrors.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title LAWPComplianceEngine
/// @author Obinna Franklin Duru (BinnaDev)
/// @notice Enforces 7-10% risk fee deductions and strict LTD/GTE fractional splits.
contract LAWPComplianceEngine is
    ILAWPComplianceEngine,
    LAWPErrors,
    Ownable2Step,
    ReentrancyGuard,
    Pausable
{
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    ILAWPTreasury public immutable treasury;
    ILAWPImpactToken public immutable impactToken;
    ILAWPActorRegistry public immutable registry;
    IERC20 public immutable cngnToken;

    address public multiSigController;

    uint256 public riskFeeBPS; // e.g., 1000 = 10%
    uint256 public constant MAX_RISK_FEE = 1000; // Circuit Breaker: Absolute max 10%
    uint256 public constant MAX_CONTRIBUTORS = 50; // Circuit Breaker: Max contributors per pool to prevent DoS
    uint256 public constant TOTAL_BPS = 10_000; // 100%

    // Structural Tracking
    struct Pool {
        bool exists;
        uint256 createdAt;
    }
    mapping(uint256 => Pool) public pools;

    // O(1) Global Yield Trackers
    mapping(uint256 => uint256) public poolYieldTracker; // Tracks global Yield per poolId
    mapping(uint256 => uint256) public poolRocTracker; // Tracks global RoC per poolId

    // Per-Token Accounting
    mapping(uint256 => uint256) public yieldClaimed;

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyMultiSig() {
        if (msg.sender != multiSigController) revert LAWPComplianceEngine_UnauthorizedCaller();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(
        address _admin,
        address _treasury,
        address _impactToken,
        address _registry,
        address _cngnToken,
        address _devWallet,
        uint256 _initialRiskFeeBPS
    ) Ownable(_admin) {
        if (
            _treasury == address(0) || _impactToken == address(0) || _registry == address(0)
                || _cngnToken == address(0) || _devWallet == address(0)
        ) {
            revert LAWPComplianceEngine_ZeroAddress();
        }
        if (_initialRiskFeeBPS == 0 || _initialRiskFeeBPS > MAX_RISK_FEE) {
            revert LAWPComplianceEngine_InvalidRiskFee();
        }

        treasury = ILAWPTreasury(_treasury);
        impactToken = ILAWPImpactToken(_impactToken);
        registry = ILAWPActorRegistry(_registry);
        cngnToken = IERC20(_cngnToken);
        riskFeeBPS = _initialRiskFeeBPS;
    }

    function renounceOwnership() public view override onlyOwner {
        revert("LAWPComplianceEngine: renounceOwnership is disabled");
    }

    /*//////////////////////////////////////////////////////////////
                        ADMIN & CIRCUIT BREAKERS
    //////////////////////////////////////////////////////////////*/

    function setMultiSigController(address _multiSig) external onlyOwner {
        if (_multiSig == address(0)) revert LAWPComplianceEngine_ZeroAddress();
        multiSigController = _multiSig;
    }

    function updateRiskFee(uint256 _newFeeBPS) external onlyOwner {
        if (_newFeeBPS == 0 || _newFeeBPS > MAX_RISK_FEE) {
            revert LAWPComplianceEngine_InvalidRiskFee();
        }
        riskFeeBPS = _newFeeBPS;
    }

    /// @notice Multi-Sig can freeze the system instantly in emergencies.
    function emergencyPause() external onlyMultiSig {
        _pause();
        emit EnginePaused(msg.sender);
    }

    /// @notice Unpausing is strictly restricted to the 48-hour Timelock (Owner).
    function unpause() external onlyOwner {
        _unpause();
        emit EngineUnpaused(msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                        CAPITAL FORMATION (DEPOSIT)
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ILAWPComplianceEngine
    function processPoolDeposit(
        uint256 _poolId,
        uint256 _grossAmount,
        address[] calldata _contributors,
        uint256[] calldata _bpsShares
    ) external override whenNotPaused nonReentrant {
        if (pools[_poolId].exists) {
            revert LAWPComplianceEngine_PoolAlreadyExists();
        }
        if (_grossAmount == 0) revert LAWPComplianceEngine_InvalidAmount();

        uint256 contributorsLength = _contributors.length;

        // Bounded loops to prevent DoS
        if (contributorsLength == 0 || contributorsLength != _bpsShares.length) {
            revert LAWPComplianceEngine_ArrayMismatch();
        }
        if (contributorsLength > MAX_CONTRIBUTORS) revert LAWPComplianceEngine_ArrayTooLarge();

        // 1. Verify exact 100% allocation
        uint256 totalBPS = 0;
        for (uint256 i = 0; i < contributorsLength;) {
            totalBPS += _bpsShares[i];

            unchecked {
                ++i;
            }
        }
        if (totalBPS != TOTAL_BPS) revert LAWPComplianceEngine_InvalidBPS();

        // 2. Math & Fee Deduction
        uint256 riskFee = (_grossAmount * riskFeeBPS) / TOTAL_BPS;
        uint256 netCapital = _grossAmount - riskFee;

        // 3. Effects: Register Pool and Mint fractional bearer assets (CEI: State changes first)
        pools[_poolId] = Pool({ exists: true, createdAt: block.timestamp });
        emit PoolCreated(_poolId, block.timestamp);
        emit RiskFeeAssessed(_poolId, _grossAmount, riskFee, netCapital);

        for (uint256 i = 0; i < contributorsLength;) {
            uint256 userNetPrincipal = (netCapital * _bpsShares[i]) / TOTAL_BPS;
            impactToken.mint(_contributors[i], userNetPrincipal, _bpsShares[i], _poolId);

            unchecked {
                ++i;
            }
        }

        // 4. Interactions: Atomic Pull -> Vault -> Route Fee
        cngnToken.safeTransferFrom(msg.sender, address(treasury), _grossAmount);
        if (riskFee > 0) treasury.routeRiskFee(riskFee);

        emit CapitalPooled(_poolId, _grossAmount, riskFee);
    }

    /*//////////////////////////////////////////////////////////////
                        LTD/GTE REVENUE ROUTING
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ILAWPComplianceEngine
    function validateAndRoute(uint256 _poolId, uint256 _totalAmount, LAWPStructs.FlowType _flowType)
        external
        override
        whenNotPaused
        nonReentrant
        onlyMultiSig
    {
        if (_totalAmount == 0) revert LAWPComplianceEngine_InvalidAmount();

        if (_flowType == LAWPStructs.FlowType.RoC) {
            // 100% of this specific routed amount goes to the Return of Contribution tracker
            poolRocTracker[_poolId] += _totalAmount;
        } else if (_flowType == LAWPStructs.FlowType.GRANT_INITIAL) {
            address la2 = registry.la2Wallet();
            if (la2 == address(0)) revert LAWPComplianceEngine_InvalidActor();

            address mvi = registry.mvi1Wallet();
            if (mvi == address(0)) revert LAWPComplianceEngine_InvalidActor();

            // System 1: 30% Collective, 50% LA2, 20% MVI1
            uint256 la2Split = (_totalAmount * 5000) / TOTAL_BPS;
            uint256 colSplit = (_totalAmount * 3000) / TOTAL_BPS;
            uint256 mviSplit = _totalAmount - (la2Split - colSplit); // Math corrected: Safe dust prevention

            poolYieldTracker[_poolId] += colSplit;
            treasury.executeTransfer(la2, la2Split);
            treasury.executeTransfer(mvi, mviSplit);
        } else if (_flowType == LAWPStructs.FlowType.GRANT_CONTINUOUS) {
            address la2 = registry.la2Wallet();
            if (la2 == address(0)) revert LAWPComplianceEngine_InvalidActor();

            address mvi = registry.mvi1Wallet();
            if (mvi == address(0)) revert LAWPComplianceEngine_InvalidActor();

            address devWallet = registry.devWallet();
            if (devWallet == address(0)) revert LAWPComplianceEngine_InvalidActor();

            // System 2: 10% Collective, 55% LA2, 25% MVI1, 10% Dev
            uint256 la2Split = (_totalAmount * 5500) / TOTAL_BPS;
            uint256 mviSplit = (_totalAmount * 2500) / TOTAL_BPS;
            uint256 colSplit = (_totalAmount * 1000) / TOTAL_BPS;
            uint256 devSplit = _totalAmount - colSplit - (la2Split - mviSplit); // Math corrected: Safe dust prevention

            poolYieldTracker[_poolId] += colSplit;
            treasury.executeTransfer(la2, la2Split);
            treasury.executeTransfer(mvi, mviSplit);
            treasury.executeTransfer(devWallet, devSplit);
        } else {
            revert LAWPComplianceEngine_InvalidFlowType();
        }

        emit RevenueRouted(_poolId, _flowType, _totalAmount);
    }

    /*//////////////////////////////////////////////////////////////
                         PULL-OVER-PUSH YIELD
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ILAWPComplianceEngine
    function claimYield(uint256 _tokenId) external override nonReentrant {
        LAWPStructs.TokenData memory data = impactToken.getTokenData(_tokenId);

        // 1. Calculate claimable Continuous Yield (Safe subtraction to prevent silent underflows)
        uint256 totalYieldForToken = (poolYieldTracker[data.poolId] * data.poolShareBPS) / TOTAL_BPS;

        uint256 claimableYield = 
            totalYieldForToken > yieldClaimed[_tokenId] ? totalYieldForToken - yieldClaimed[_tokenId] : 0;

        // 2. Calculate claimable RoC (Strictly capped at netPrincipal)
        uint256 totalRocForToken = (poolRocTracker[data.poolId] * data.poolShareBPS) / TOTAL_BPS;
        
        uint256 claimableRoc =
            totalRocForToken > data.rocReturned ? totalRocForToken - data.rocReturned : 0;

        uint256 maxRemainingRoc = data.netPrincipal - data.rocReturned;
        if (claimableRoc > maxRemainingRoc) {
            claimableRoc = maxRemainingRoc;
        }

        uint256 totalClaim = claimableYield + claimableRoc;
        if (totalClaim == 0) revert LAWPTreasury_YieldAlreadyClaimed();

        // 3. Effects (State Updates)
        if (claimableYield > 0) {
            yieldClaimed[_tokenId] += claimableYield;
        }
        if (claimableRoc > 0) {
            impactToken.updateRocReturned(_tokenId, claimableRoc);
        }

        // 4. Interactions (Transfer)
        // Fetch current owner. Uses low-level call approach if called via Interception Hook
        address owner = impactToken.ownerOf(_tokenId);
        treasury.executeTransfer(owner, totalClaim);

        emit YieldClaimed(_tokenId, owner, claimableYield, claimableRoc);
    }

    /// @inheritdoc ILAWPComplianceEngine
    function calculateProportionalYield(uint256 _tokenId) external view override returns (uint256) {
        // Mirrors the math in claimYield exactly, but acts only as a getter for frontends
        LAWPStructs.TokenData memory data = impactToken.getTokenData(_tokenId);

        uint256 totalYieldForToken = (poolYieldTracker[data.poolId] * data.poolShareBPS) / TOTAL_BPS;
        uint256 claimableYield = totalYieldForToken > yieldClaimed[_tokenId]
            ? totalYieldForToken - yieldClaimed[_tokenId]
            : 0;

        uint256 totalRocForToken = (poolRocTracker[data.poolId] * data.poolShareBPS) / TOTAL_BPS;
        uint256 claimableRoc =
            totalRocForToken > data.rocReturned ? totalRocForToken - data.rocReturned : 0;

        uint256 maxRemainingRoc = data.netPrincipal - data.rocReturned;
        if (claimableRoc > maxRemainingRoc) {
            claimableRoc = maxRemainingRoc;
        }

        return claimableYield + claimableRoc;
    }
}
