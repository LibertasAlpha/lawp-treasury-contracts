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
    uint256 public constant MAX_CONTRIBUTORS = 20; // Circuit Breaker: Max contributors per pool to prevent DoS
    uint256 public constant TOTAL_BPS = 10_000; // 100%

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
        // checks: validate inputs, enforce max contributors, and ensure BPS sums to 100%
        if (_grossAmount == 0) revert LAWPComplianceEngine_InvalidAmount();

        uint256 contributorsLength = _contributors.length;
        if (contributorsLength > MAX_CONTRIBUTORS) revert LAWPComplianceEngine_ArrayTooLarge();

        // Bounded loops to prevent DoS
        if (contributorsLength == 0 || contributorsLength != _bpsShares.length) {
            revert LAWPComplianceEngine_ArrayMismatch();
        }

        // 1. Verify exact 100% allocation
        _validateBPS(_bpsShares, contributorsLength);

        // Effects: Register Pool and transfer funds before minting
        // 2. Math & Fee Deduction
        (uint256 riskFee, uint256 netCapital) = _computeFees(_grossAmount);

        // Interactions: Pull funds first, then mint shares to contributors based on net capital after fees
        // 3. Pull total gross amount from sender to Treasury
        cngnToken.safeTransferFrom(msg.sender, address(treasury), _grossAmount);
        if (riskFee > 0) treasury.routeRiskFee(riskFee);
        emit RiskFeeAssessed(_poolId, _grossAmount, riskFee, netCapital);

        // 4. Mint shares to contributors based on net capital after fees
        _mintContributorShares(_poolId, netCapital, _contributors, _bpsShares, contributorsLength);

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
            uint256 mviSplit = _totalAmount - la2Split - colSplit;

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
            uint256 devSplit = _totalAmount - la2Split - mviSplit - colSplit;

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
        // 1. Load token data
        LAWPStructs.TokenData memory data = impactToken.getTokenData(_tokenId);

        // 2. Calculate claimable Continuous Yield
        uint256 totalYieldForToken = (poolYieldTracker[data.poolId] * data.poolShareBPS) / TOTAL_BPS;
        uint256 claimableYield = totalYieldForToken > yieldClaimed[_tokenId]
            ? totalYieldForToken - yieldClaimed[_tokenId]
            : 0;

        // 3. Calculate claimable RoC (strictly capped at netPrincipal)
        uint256 totalRocForToken = (poolRocTracker[data.poolId] * data.poolShareBPS) / TOTAL_BPS;
        uint256 claimableRoc =
            totalRocForToken > data.rocReturned ? totalRocForToken - data.rocReturned : 0;

        uint256 maxRemainingRoc = data.netPrincipal - data.rocReturned;
        if (claimableRoc > maxRemainingRoc) {
            claimableRoc = maxRemainingRoc;
        }

        uint256 totalClaim = claimableYield + claimableRoc;
        if (totalClaim == 0) revert LAWPComplianceEngine_NothingToClaim();

        // 4. Effects: Update all state BEFORE any external calls
        if (claimableYield > 0) {
            yieldClaimed[_tokenId] += claimableYield;
        }
        if (claimableRoc > 0) {
            impactToken.updateRocReturned(_tokenId, claimableRoc);
        }

        // 5. Interactions: Transfer funds LAST
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

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Verifies contributor BPS shares sum exactly to TOTAL_BPS.
    /// @dev Extracted to relieve the outer frame of `totalBPS` and the loop counter `i`.
    function _validateBPS(uint256[] calldata _bpsShares, uint256 _contributorsLength)
        internal
        pure
    {
        uint256 totalBPS;
        for (uint256 i; i < _contributorsLength;) {
            totalBPS += _bpsShares[i];
            unchecked {
                ++i;
            }
        }
        if (totalBPS != TOTAL_BPS) revert LAWPComplianceEngine_InvalidBPS();
    }

    /// @notice Computes risk fee and net capital from gross amount.
    /// @dev Named return values avoid two additional stack slots in the caller.
    function _computeFees(uint256 _grossAmount)
        internal
        view
        returns (uint256 riskFee, uint256 netCapital)
    {
        riskFee = (_grossAmount * riskFeeBPS) / TOTAL_BPS;
        netCapital = _grossAmount - riskFee;
    }

    /// @notice Mints fractional bearer tokens to each contributor.
    /// @dev Extracted to relieve the outer frame of `netCapital` and the loop counter `i`.  Called only after treasury has received funds (CEI: Interactions -> mint is the last external call).
    function _mintContributorShares(
        uint256 _poolId,
        uint256 _netCapital,
        address[] calldata _contributors,
        uint256[] calldata _bpsShares,
        uint256 _contributorsLength
    ) internal {
        uint256 remainingCapital = _netCapital;
        uint256 lastIndex = _contributorsLength - 1;

        for (uint256 i; i < _contributorsLength;) {
            if (i == lastIndex) {
                // Last contributor gets everything remaining to eliminate zero dust
                impactToken.mint(_contributors[i], remainingCapital, _bpsShares[i], _poolId);
            } else {
                uint256 userNetPrincipal = (_netCapital * _bpsShares[i]) / TOTAL_BPS;
                remainingCapital -= userNetPrincipal;
                impactToken.mint(_contributors[i], userNetPrincipal, _bpsShares[i], _poolId);
            }
            unchecked {
                ++i;
            }
        }
    }
}
