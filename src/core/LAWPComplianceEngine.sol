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
/// @notice Enforces systemic risk fee deductions and strict LTD/GTE fractional revenue routing.
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

    /// @notice Treasury contract for secure fund management and transfers.
    ILAWPTreasury public immutable treasury;

    /// @notice Impact Token contract for minting shares and tracking ownership/metadata.
    ILAWPImpactToken public immutable impactToken;

    /// @notice Actor Registry for validating and pulling operational wallet addresses dynamically.
    ILAWPActorRegistry public immutable registry;

    /// @notice The ERC20 token used for all deposits, fees, and yield distributions (e.g., cNGN).
    IERC20 public immutable cngnToken;

    /// @notice Multi-Sig Controller address authorized to route revenue and trigger emergency pauses.
    address public multiSigController;

    /// @notice Current systemic risk fee in basis points (BPS) deducted from gross pool deposits.
    uint256 public riskFeeBPS;

    /// @notice Circuit Breaker: Absolute maximum permissible risk fee to prevent misconfiguration (10% = 1000 BPS).
    uint256 public constant MAX_RISK_FEE = 1000;

    /// @notice Circuit Breaker: Maximum number of contributors allowed per pool deposit to prevent block gas limit DoS.
    uint256 public constant MAX_CONTRIBUTORS = 20; 
    
    /// @notice Circuit Breaker: Maximum number of tokens processed in a single batch claim to prevent block gas limit DoS.
    uint256 public constant MAX_BATCH_CLAIM = 20;

    /// @notice Total basis points constant representing 100% for proportional calculations.
    uint256 public constant TOTAL_BPS = 10_000;

    /// @notice Tracks the cumulative Continuous Yield routed to a specific poolId. Updated during revenue routing.
    mapping(uint256 poolId => uint256 cumulativeYield) public poolYieldTracker;

    /// @notice Tracks the cumulative Return of Contribution (RoC) routed to a specific poolId. Updated during revenue routing.
    mapping(uint256 poolId => uint256 cumulativeRoc) public poolRocTracker;

    /// @notice Tracks the total yield already claimed by a specific tokenId to ensure accurate O(1) pro-rata math.
    mapping(uint256 tokenId => uint256 claimedAmount) public yieldClaimed;

    /// @notice Structure defining the creation state of a project pool.
    struct Pool {
        bool exists;
        uint256 createdAt;
    }

    /// @notice Registry tracking the existence and creation timestamp of all deployed project pools.
    /// @dev Acts as a strict circuit breaker preventing `poolId` reuse. Guarantees the 'One Pool ID = One Capital Event' invariant, securing the O(1) cumulative yield trackers against time-travel exploits.
    mapping(uint256 poolId => Pool poolData) public pools;

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Restricts execution strictly to the authorized Multi-Sig Controller.
    modifier onlyMultiSig() {
        if (msg.sender != multiSigController) revert LAWPComplianceEngine_UnauthorizedCaller();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Initializes the Compliance Engine with essential system dependencies.
    /// @param _admin Address of the Owner / Timelock controller.
    /// @param _treasury Address of the LAWPTreasury contract.
    /// @param _impactToken Address of the LAWPImpactToken contract.
    /// @param _registry Address of the LAWPActorRegistry contract.
    /// @param _cngnToken Address of the primary ERC20 asset (cNGN).
    /// @param _initialRiskFeeBPS Starting risk fee applied to all deposits (max 1000 BPS).
    constructor(
        address _admin,
        address _treasury,
        address _impactToken,
        address _registry,
        address _cngnToken,
        uint256 _initialRiskFeeBPS
    ) Ownable(_admin) {
        if (
            _treasury == address(0) || _impactToken == address(0) || _registry == address(0)
                || _cngnToken == address(0)
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

    /// @notice Overridden to prevent the accidental renunciation of ownership.
    function renounceOwnership() public view override onlyOwner {
        revert("LAWPComplianceEngine: renounceOwnership is disabled");
    }

    /*//////////////////////////////////////////////////////////////
                        ADMIN & CIRCUIT BREAKERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Sets the operational Multi-Sig Controller address.
    /// @param _multiSig The address of the authorized Multi-Sig wallet.
    function setMultiSigController(address _multiSig) external onlyOwner {
        if (_multiSig == address(0)) revert LAWPComplianceEngine_ZeroAddress();
        multiSigController = _multiSig;
    }

    /// @notice Updates the systemic risk fee applied to incoming pool deposits.
    /// @param _newFeeBPS The new fee in basis points (must not exceed MAX_RISK_FEE).
    function updateRiskFee(uint256 _newFeeBPS) external onlyOwner {
        if (_newFeeBPS == 0 || _newFeeBPS > MAX_RISK_FEE) {
            revert LAWPComplianceEngine_InvalidRiskFee();
        }
        riskFeeBPS = _newFeeBPS;
    }

    /// @notice Instantly freezes capital formation and revenue routing in emergencies.
    /// @dev Action is strictly restricted to the Multi-Sig Controller to allow rapid response.
    function emergencyPause() external onlyMultiSig {
        _pause();
        emit EnginePaused(msg.sender);
    }

    /// @notice Unfreezes the system, allowing normal operations to resume.
    /// @dev Strictly restricted to the Owner (Timelock) to prevent Multi-Sig administrative abuse.
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
        // Checks: Validate inputs, enforce maximum contributors bound, and confirm new poolId.
        if (pools[_poolId].exists) revert LAWPComplianceEngine_PoolAlreadyExists();
        if (_grossAmount == 0) revert LAWPComplianceEngine_InvalidAmount();

        uint256 contributorsLength = _contributors.length;
        if (contributorsLength > MAX_CONTRIBUTORS) revert LAWPComplianceEngine_ArrayTooLarge();

        if (contributorsLength == 0 || contributorsLength != _bpsShares.length) {
            revert LAWPComplianceEngine_ArrayMismatch();
        }

        // 1. Verify exact 100% allocation across all contributors.
        _validateBPS(_bpsShares, contributorsLength);

        // Effects: Compute state, register the pool, and emit localized events before external calls.
        // 2. Math & Fee Deduction
        (uint256 riskFee, uint256 netCapital) = _computeFees(_grossAmount);

        pools[_poolId] = Pool({exists: true, createdAt: block.timestamp});
        emit PoolCreated(_poolId, block.timestamp);

        // Interactions: Securely transfer funds and mint fractional equity.
        // 3. Pull total gross amount from sender to the Treasury Vault.
        cngnToken.safeTransferFrom(msg.sender, address(treasury), _grossAmount);
        if (riskFee > 0) treasury.routeRiskFee(riskFee);
        emit RiskFeeAssessed(_poolId, _grossAmount, riskFee, netCapital);

        // 4. Mint fractional shares to contributors based on net capital.
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
            // 100% of this specific routed amount is assigned to the Return of Contribution tracker
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
        address owner = impactToken.ownerOf(_tokenId);
        
        uint256 totalClaim = _claimYieldForToken(_tokenId, owner);
        if (totalClaim == 0) revert LAWPComplianceEngine_NothingToClaim();

        // Single external transfer to the token owner
        treasury.executeTransfer(owner, totalClaim);
    }

    /// @inheritdoc ILAWPComplianceEngine
    function claimYieldBatch(uint256[] calldata _tokenIds) external override nonReentrant {
        uint256 length = _tokenIds.length;
        if (length > MAX_BATCH_CLAIM) revert LAWPComplianceEngine_BatchTooLarge();
        
        uint256 aggregateClaim;
        
        for (uint256 i; i < length;) {
            uint256 tokenId = _tokenIds[i];
            
            // Ownership validation: Enforce that the caller owns every token in the batch
            address owner = impactToken.ownerOf(tokenId);
            if (owner != msg.sender) revert LAWPComplianceEngine_NotTokenOwner(tokenId);

            // Compute claimable amount and securely update token state
            aggregateClaim += _claimYieldForToken(tokenId, owner);
            
            unchecked { ++i; }
        }
        
        if (aggregateClaim == 0) revert LAWPComplianceEngine_NothingToClaim();
        
        // Single aggregated external transfer to optimize gas
        treasury.executeTransfer(msg.sender, aggregateClaim);
    }

    /// @inheritdoc ILAWPComplianceEngine
    function calculateProportionalYield(uint256 _tokenId) external view override returns (uint256) {
        // ============================================================================
        // O(1) CUMULATIVE MATH ENGINE (Read-Only)
        // ----------------------------------------------------------------------------
        // Mirrors the math in `_claimYieldForToken` explicitly, serving solely as a 
        // read-only getter for frontends. See `_claimYieldForToken` for math breakdown.
        // ============================================================================
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

    /// @notice Calculates the accurate Continuous Yield and RoC owed, processes state updates, and emits events.
    /// @dev Silently returns 0 if no funds are claimable to facilitate uninterrupted batch processing.
    /// @param _tokenId The specific ID of the Impact Token.
    /// @param _owner The explicitly pre-fetched owner of the token to guarantee correct event emission.
    /// @return claimable The aggregate CNGN amount owed to the token.
    function _claimYieldForToken(uint256 _tokenId, address _owner) internal returns (uint256 claimable) {
        // ============================================================================
        // O(1) CUMULATIVE MATH ENGINE
        // ----------------------------------------------------------------------------
        // Instead of looping to calculate yield on every transaction, we track the 
        // ALL-TIME historical yield of the pool. A token's claimable amount is its 
        // lifetime slice of that all-time yield, minus what it has already claimed.
        //
        // YIELD MATH: (Historical Pool Yield * Token BPS / 100%) - Already Claimed Yield
        // ROC MATH: (Historical Pool RoC * Token BPS / 100%) - Already Claimed RoC
        //
        // CONTEXT FOR "ALREADY CLAIMED":
        // - Already Claimed Yield: The running total of continuous yield this exact 
        //   tokenId has successfully withdrawn in all past claim transactions.
        // - Already Claimed RoC: The running total of RoC this exact tokenId has 
        //   successfully withdrawn in all past claim transactions (`data.rocReturned`).
        //
        // HARD CAP: RoC payout is strictly capped to never exceed `netPrincipal`.
        // Once a user gets their original investment back in full,
        // they stop receiving RoC payouts (but they keep earning Yield forever).
        // ============================================================================
        
        LAWPStructs.TokenData memory data = impactToken.getTokenData(_tokenId);

        // 1. Continuous Yield Calculation (O(1) Pro-Rata Math)
        uint256 totalYield = (poolYieldTracker[data.poolId] * data.poolShareBPS) / TOTAL_BPS;
        uint256 claimableYield = totalYield > yieldClaimed[_tokenId]
            ? totalYield - yieldClaimed[_tokenId]
            : 0;

        // 2. RoC Calculation (Strictly capped at net principal)
        uint256 totalRoc = (poolRocTracker[data.poolId] * data.poolShareBPS) / TOTAL_BPS;
        uint256 claimableRoc = totalRoc > data.rocReturned ? totalRoc - data.rocReturned : 0;

        // 3. Hard Cap: Ensure RoC payout never exceeds the net principal.
        uint256 maxRemainingRoc = data.netPrincipal - data.rocReturned;
        if (claimableRoc > maxRemainingRoc) {
            claimableRoc = maxRemainingRoc;
        }

        claimable = claimableYield + claimableRoc;

        // 4. Effects: Safely update token state before any external interactions occur.
        if (claimable > 0) {
            if (claimableYield > 0) {
                yieldClaimed[_tokenId] += claimableYield;
            }
            if (claimableRoc > 0) {
                impactToken.updateRocReturned(_tokenId, claimableRoc);
            }
            emit YieldClaimed(_tokenId, _owner, claimableYield, claimableRoc);
        }
    }

    /// @notice Iterates over the `_bpsShares` array to confirm the sum equals exactly 10,000 (100%).
    /// @dev Extracted internally to optimize stack depth inside the `processPoolDeposit` function.
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

    /// @notice Determines the systemic risk fee and final net capital from a gross deposit amount.
    /// @dev Named return variables utilized to avoid stack-too-deep complications in the caller.
    function _computeFees(uint256 _grossAmount)
        internal
        view
        returns (uint256 riskFee, uint256 netCapital)
    {
        riskFee = (_grossAmount * riskFeeBPS) / TOTAL_BPS;
        netCapital = _grossAmount - riskFee;
    }

    /// @notice Loops through contributors to mint their fractional Impact Equity tokens.
    /// @dev Transfers all rounding dust (wei) to the final contributor in the array to ensure the total principal equals exact net capital.
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
                // Final contributor absorbs any mathematical dust to maintain total principal integrity
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