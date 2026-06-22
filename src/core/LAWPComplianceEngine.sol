// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ILAWPComplianceEngine } from "../interfaces/ILAWPComplianceEngine.sol";
import { ILAWPYieldVault } from "../interfaces/ILAWPYieldVault.sol";
import { ILAWPOperationalVault } from "../interfaces/ILAWPOperationalVault.sol";
import { ILAWPImpactToken } from "../interfaces/ILAWPImpactToken.sol";
import { ILAWPActorRegistry } from "../interfaces/ILAWPActorRegistry.sol";
import { LAWPStructs } from "../libraries/LAWPStructs.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title LAWPComplianceEngine
/// @author Obinna Franklin Duru (BinnaDev)
/// @notice The Zero-Custody Switchboard and Deterministic Accounting Layer
///         for strict LTD/GTE fractional revenue routing.
/// @dev LAWPComplianceEngine is the core orchestrator of the LAWP Treasury system, responsible for:
///      1. Processing incoming capital and minting fractional equity tokens.
///      2. Calculating and routing off-chain revenue splits with strict mathematical precision.
///      3. Maintaining O(1) cumulative yield trackers and a pull-based claiming mechanism
///         for investors and operational actors.
///      The contract is fortified with robust access controls, circuit breakers, and
///      comprehensive event logging to ensure security, transparency, and efficient operations.
contract LAWPComplianceEngine is ILAWPComplianceEngine, Ownable2Step, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                        COMPLIANCE ENGINE ERRORS
    //////////////////////////////////////////////////////////////*/
    error LAWPComplianceEngine_InvalidRiskFee();
    error LAWPComplianceEngine_SystemPaused();
    error LAWPComplianceEngine_UnauthorizedCaller();
    error LAWPComplianceEngine_InvalidFlowType();
    error LAWPComplianceEngine_ExceedsPrincipalCap();
    error LAWPComplianceEngine_ArrayMismatch();
    error LAWPComplianceEngine_InvalidBPS();
    error LAWPComplianceEngine_ZeroAddress();
    error LAWPComplianceEngine_InvalidAmount();
    error LAWPComplianceEngine_PoolAlreadyExists();
    error LAWPComplianceEngine_InvalidActor();
    error LAWPComplianceEngine_ArrayTooLarge();
    error LAWPComplianceEngine_NothingToClaim();
    error LAWPComplianceEngine_BatchTooLarge();
    error LAWPComplianceEngine_NotTokenOwner(uint256 tokenId);
    error LAWPComplianceEngine_NoOperationalFunds();
    error LAWPComplianceEngine_UnauthorizedInjector(address fundProvider);
    error LAWPComplianceEngine_ZeroAddressInjector();
    error LAWPComplianceEngine_InvalidPool();
    /// @notice Reverts when a transfer arrives with zero net tokens despite a non-zero request.
    ///         Indicates a 100% fee-on-transfer token or a rebasing token that zeroed the balance.
    ///         Accounting with zero actualReceived would silently corrupt pool state.
    error LAWPComplianceEngine_ZeroActualReceived();

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Dedicated vault for isolating Investor RoC and Continuous Yield.
    ///         Funded exclusively by revenue routing (GRANT_INITIAL, GRANT_CONTINUOUS, RoC).
    ///         No campaign principal is held here - deposit capital flows to the Operational Vault.
    ILAWPYieldVault public immutable yieldVault;

    /// @notice Dedicated vault for isolating Systemic Risk Fees, Dev, LA2, and MVI1 payouts.
    ILAWPOperationalVault public immutable operationalVault;

    /// @notice Impact Token contract for minting shares and tracking ownership/metadata.
    ILAWPImpactToken public immutable impactToken;

    /// @notice Actor Registry for validating and pulling operational wallet addresses dynamically.
    ILAWPActorRegistry public immutable registry;

    /// @notice The immutable ERC20 settlement token (cNGN) for all deposits, fees, and yield distributions.
    IERC20 public immutable cNGNToken;

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

    /// @notice Records the total net campaign capital committed to a pool at deposit time.
    ///         Written once during `processPoolDeposit` and never mutated thereafter.
    ///         Used as the hard upper bound for cumulative RoC routing - ensures
    ///         Σ(RoC routed) ≤ poolTotalPrincipal, preventing stranded funds in the Yield Vault.
    mapping(uint256 poolId => uint256 principal) public poolTotalPrincipal;

    /// @notice Tracks the total yield already claimed by a specific tokenId to ensure accurate O(1) pro-rata math.
    mapping(uint256 tokenId => uint256 claimedAmount) public yieldClaimed;

    /// @notice The Pull-over-Push Operational Ledger tracking pullable balances for operational actors.
    mapping(address wallet => uint256 balance) public operationalBalances;

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
        _onlyMultiSig();
        _;
    }

    function _onlyMultiSig() internal view {
        if (msg.sender != multiSigController) revert LAWPComplianceEngine_UnauthorizedCaller();
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Initializes the Compliance Engine with essential system dependencies.
    /// @param _admin Address of the Owner / Admin Safe.
    /// @param _yieldVault Address of the LAWPYieldVault contract.
    /// @param _operationalVault Address of the ILAWPOperationalVault contract.
    /// @param _impactToken Address of the LAWPImpactToken contract.
    /// @param _registry Address of the LAWPActorRegistry contract.
    /// @param _cNGNToken Address of the immutable cNGN ERC20 settlement token.
    /// @param _initialRiskFeeBPS Starting risk fee applied to all deposits (max 1000 BPS).
    constructor(
        address _admin,
        address _yieldVault,
        address _operationalVault,
        address _impactToken,
        address _registry,
        address _cNGNToken,
        uint256 _initialRiskFeeBPS
    ) Ownable(_admin) {
        if (
            _yieldVault == address(0) || _operationalVault == address(0)
                || _impactToken == address(0) || _registry == address(0) || _cNGNToken == address(0)
        ) {
            revert LAWPComplianceEngine_ZeroAddress();
        }
        if (_initialRiskFeeBPS == 0 || _initialRiskFeeBPS > MAX_RISK_FEE) {
            revert LAWPComplianceEngine_InvalidRiskFee();
        }

        yieldVault = ILAWPYieldVault(_yieldVault);
        operationalVault = ILAWPOperationalVault(_operationalVault);
        impactToken = ILAWPImpactToken(_impactToken);
        registry = ILAWPActorRegistry(_registry);
        cNGNToken = IERC20(_cNGNToken);
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
        address oldController = multiSigController;
        multiSigController = _multiSig;

        emit MultiSigControllerUpdated(oldController, _multiSig);
    }

    /// @notice Updates the systemic risk fee applied to incoming pool deposits.
    /// @param _newFeeBPS The new fee in basis points (must not exceed MAX_RISK_FEE).
    function updateRiskFee(uint256 _newFeeBPS) external onlyOwner {
        if (_newFeeBPS == 0 || _newFeeBPS > MAX_RISK_FEE) {
            revert LAWPComplianceEngine_InvalidRiskFee();
        }
        uint256 oldFee = riskFeeBPS;
        riskFeeBPS = _newFeeBPS;

        emit RiskFeeUpdated(oldFee, _newFeeBPS);
    }

    /// @notice Instantly freezes capital formation and revenue routing in emergencies.
    /// @dev Designed as a critical safety mechanism to mitigate potential exploits or systemic risks. Only the Owner can trigger this to ensure deliberate action during crises.
    function emergencyPause() external onlyOwner {
        _pause();
        emit EnginePaused(msg.sender);
    }

    /// @notice Unfreezes the system, allowing normal operations to resume.
    /// @dev Strictly restricted to the Only Owner to ensure deliberate and secure unpausing after an emergency.
    function unpause() external onlyOwner {
        _unpause();
        emit EngineUnpaused(msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                        CAPITAL FORMATION (DEPOSIT)
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ILAWPComplianceEngine
    /// @dev BALANCE-DELTA ACCOUNTING: All downstream state is derived from the actual tokens
    ///      received in the Operational Vault (measured via pre/post balance snapshot), NOT from
    ///      the caller-supplied `_grossAmount`. This guards against fee-on-transfer tokens,
    ///      upgradeable tokens introducing transfer taxes, and any token that delivers fewer
    ///      tokens than requested.
    ///
    ///      CEI NOTE: Pool registration (Effects) occurs before the ERC20 transfer (Interaction)
    ///      to preserve replay protection. The pool guard (`pools[_poolId].exists`) and
    ///      `nonReentrant` together eliminate any reentrancy window opened by this ordering.
    ///      Ledger credits (operationalBalances, poolTotalPrincipal) are written AFTER the
    ///      transfer so they reflect the actual amount; this is safe because the pool is already
    ///      locked before the first external call.
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

        // 2. Resolve the Operational Treasury address before any state mutation.
        address opTreasury = registry.operationalTreasuryWallet();
        if (opTreasury == address(0)) revert LAWPComplianceEngine_InvalidActor();

        // Effects (partial): register pool to lock replay before Interaction
        pools[_poolId] = Pool({ exists: true, createdAt: block.timestamp });
        emit PoolCreated(_poolId, block.timestamp);

        // Interaction: execute the ERC20 transfer with balance-delta measurement
        // 3. Snapshot the vault balance BEFORE the transfer.
        uint256 balBefore = cNGNToken.balanceOf(address(operationalVault));

        cNGNToken.safeTransferFrom(msg.sender, address(operationalVault), _grossAmount);

        // 4. Measure what actually landed in the vault.
        //    This is the canonical amount for ALL downstream accounting.
        //    If cNGN ever gains a transfer fee (proxy upgrade), this captures the true net.
        uint256 actualReceived = cNGNToken.balanceOf(address(operationalVault)) - balBefore;
        if (actualReceived == 0) revert LAWPComplianceEngine_ZeroActualReceived();

        // Effects (remainder): derive every ledger entry from actualReceived
        // 5. Compute protocol fee and net campaign capital from the actual deposit.
        (uint256 riskFee, uint256 netCapital) = _computeFees(actualReceived);

        // 6. Credit the internal pull-ledger for the Operational Treasury.
        //    riskFee + netCapital always reconstructs to actualReceived (no wei lost).
        if (riskFee > 0) operationalBalances[opTreasury] += riskFee;
        operationalBalances[opTreasury] += netCapital;

        // 7. Write the immutable RoC ceiling for this pool.
        //    Written once; enforced during RoC routing to prevent over-routing.
        poolTotalPrincipal[_poolId] = netCapital;

        emit RiskFeeAssessed(_poolId, actualReceived, riskFee, netCapital);

        // 8. Mint fractional shares to contributors based on actual net capital.
        _mintContributorShares(_poolId, netCapital, _contributors, _bpsShares, contributorsLength);

        emit CapitalPooled(_poolId, actualReceived, riskFee);
    }

    /*//////////////////////////////////////////////////////////////
                        LTD/GTE REVENUE ROUTING
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ILAWPComplianceEngine
    /// @dev BALANCE-DELTA ACCOUNTING: Every ledger entry (poolRocTracker, poolYieldTracker,
    ///      operationalBalances) is derived from actual tokens received in each vault, measured
    ///      via pre/post balance snapshots around each safeTransferFrom call.
    ///
    ///      For GRANT_INITIAL and GRANT_CONTINUOUS the two-vault split pattern means two
    ///      independent snapshots are taken - one per vault. The operational sub-allocations
    ///      (la2, mvi, dev) are then pro-rated from `actualOpReceived` using the original BPS
    ///      ratios, preserving relative proportionality even if a transfer tax applies.
    ///
    ///      RoC cap pre-check: the guard uses the caller-supplied `_totalAmount` as a
    ///      conservative request-level ceiling. Actual tracking uses `actualRocReceived`,
    ///      which is always ≤ `_totalAmount`, so the cap invariant is never violated.
    function routeOperationalAllocation(
        uint256 _poolId,
        uint256 _totalAmount,
        address _fundProvider,
        LAWPStructs.FlowType _flowType
    ) external override whenNotPaused nonReentrant onlyMultiSig {
        if (_totalAmount == 0) {
            revert LAWPComplianceEngine_InvalidAmount();
        }

        if (_flowType == LAWPStructs.FlowType.RoC) {
            _routeRoC(_poolId, _totalAmount, _fundProvider);
        } else if (_flowType == LAWPStructs.FlowType.GRANT_INITIAL) {
            _routeGrantInitial(_totalAmount, _fundProvider, _poolId);
        } else if (_flowType == LAWPStructs.FlowType.GRANT_CONTINUOUS) {
            _routeGrantContinuous(_totalAmount, _fundProvider, _poolId);
        } else {
            revert LAWPComplianceEngine_InvalidFlowType();
        }

        // Event emits the originally requested _totalAmount for indexer traceability.
        // The actual received amounts are captured on-chain via ledger state changes.
        emit OperationalAllocationRouted(_poolId, _flowType, _totalAmount);
    }

    /*//////////////////////////////////////////////////////////////
                         PULL-OVER-PUSH YIELD
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ILAWPComplianceEngine
    function claimOperationalFunds(address _wallet) external override nonReentrant {
        uint256 amount = operationalBalances[_wallet];
        if (amount == 0) revert LAWPComplianceEngine_NoOperationalFunds();

        // Strict CEI Pattern
        operationalBalances[_wallet] = 0;

        operationalVault.executeTransfer(_wallet, amount);

        emit OperationalFundsClaimed(_wallet, amount);
    }

    /// @inheritdoc ILAWPComplianceEngine
    function claimYield(uint256 _tokenId) external override nonReentrant {
        address tokenOwner = impactToken.ownerOf(_tokenId);

        if (msg.sender != tokenOwner && msg.sender != address(impactToken)) {
            revert LAWPComplianceEngine_NotTokenOwner(_tokenId);
        }

        uint256 totalClaim = _claimYieldForToken(_tokenId, tokenOwner);
        if (totalClaim == 0) revert LAWPComplianceEngine_NothingToClaim();

        // Single external transfer to the token owner
        yieldVault.executeTransfer(tokenOwner, totalClaim);
    }

    /// @inheritdoc ILAWPComplianceEngine
    function claimYieldBatch(uint256[] calldata _tokenIds) external override nonReentrant {
        uint256 length = _tokenIds.length;
        if (length > MAX_BATCH_CLAIM) revert LAWPComplianceEngine_BatchTooLarge();

        uint256 aggregateClaim = 0;

        for (uint256 i; i < length;) {
            uint256 tokenId = _tokenIds[i];

            // Ownership validation: Enforce that the caller owns every token in the batch
            address tokenOwner = impactToken.ownerOf(tokenId);
            if (tokenOwner != msg.sender) revert LAWPComplianceEngine_NotTokenOwner(tokenId);

            // Compute claimable amount and securely update token state
            aggregateClaim += _claimYieldForToken(tokenId, tokenOwner);

            unchecked {
                ++i;
            }
        }

        if (aggregateClaim == 0) revert LAWPComplianceEngine_NothingToClaim();

        // Single aggregated external transfer to optimize gas
        yieldVault.executeTransfer(msg.sender, aggregateClaim);
    }

    /*//////////////////////////////////////////////////////////////
                               PRIVATE HELPERS
    //////////////////////////////////////////////////////////////*/

    function _routeRoC(uint256 _poolId, uint256 _totalAmount, address _fundProvider) private {
        // Conservative cap pre-check on the requested amount.
        // Actual tracking (below) uses actualRocReceived which is always ≤ _totalAmount.
        uint256 rocCap = poolTotalPrincipal[_poolId];
        if (poolRocTracker[_poolId] + _totalAmount > rocCap) {
            revert LAWPComplianceEngine_ExceedsPrincipalCap();
        }

        // Balance-delta: snapshot -> transfer -> measure.
        uint256 yieldBalBefore = cNGNToken.balanceOf(address(yieldVault));
        cNGNToken.safeTransferFrom(_fundProvider, address(yieldVault), _totalAmount);
        uint256 actualRocReceived = cNGNToken.balanceOf(address(yieldVault)) - yieldBalBefore;
        if (actualRocReceived == 0) revert LAWPComplianceEngine_ZeroActualReceived();

        // Track actual routed RoC, not requested amount.
        poolRocTracker[_poolId] += actualRocReceived;
    }

    function _routeGrantInitial(uint256 _totalAmount, address _fundProvider, uint256 _poolId)
        private
    {
        address la2 = registry.la2Wallet();
        address mvi = registry.mvi1Wallet();
        if (la2 == address(0) || mvi == address(0)) revert LAWPComplianceEngine_InvalidActor();

        // System 1 target splits from requested amount (used only for transfer sizing):
        // 30% Collective -> YieldVault, 50% LA2 + 20% MVI1 -> OperationalVault
        uint256 la2Split = (_totalAmount * 5000) / TOTAL_BPS;
        uint256 colSplit = (_totalAmount * 3000) / TOTAL_BPS;
        uint256 mviSplit = _totalAmount - la2Split - colSplit;

        // Transfer 1: Collective share -> YieldVault.
        uint256 yieldBalBefore = cNGNToken.balanceOf(address(yieldVault));
        cNGNToken.safeTransferFrom(_fundProvider, address(yieldVault), colSplit);
        uint256 actualColReceived = cNGNToken.balanceOf(address(yieldVault)) - yieldBalBefore;
        if (actualColReceived == 0) revert LAWPComplianceEngine_ZeroActualReceived();

        // Transfer 2: LA2 + MVI1 combined -> OperationalVault.
        uint256 opBalBefore = cNGNToken.balanceOf(address(operationalVault));
        cNGNToken.safeTransferFrom(_fundProvider, address(operationalVault), la2Split + mviSplit);
        uint256 actualOpReceived = cNGNToken.balanceOf(address(operationalVault)) - opBalBefore;
        if (actualOpReceived == 0) revert LAWPComplianceEngine_ZeroActualReceived();

        // Pro-rate la2 and mvi from actualOpReceived using original 5000:2000 ratio.
        // This preserves relative allocation even if a transfer tax reduces the total.
        // Rounding dust flows to mvi (last assignment absorbs remainder).
        uint256 actualLa2 = (actualOpReceived * 5000) / 7000;
        uint256 actualMvi = actualOpReceived - actualLa2;

        // Credit internal ledger from actual amounts.
        poolYieldTracker[_poolId] += actualColReceived;
        operationalBalances[la2] += actualLa2;
        operationalBalances[mvi] += actualMvi;
    }

    function _routeGrantContinuous(uint256 _totalAmount, address _fundProvider, uint256 _poolId)
        private
    {
        address la2 = registry.la2Wallet();
        address mvi = registry.mvi1Wallet();
        address devWallet = registry.devWallet();
        if (la2 == address(0) || mvi == address(0) || devWallet == address(0)) {
            revert LAWPComplianceEngine_InvalidActor();
        }

        // // System 2 target splits from requested amount (used only for transfer sizing):
        // // 10% Collective -> YieldVault, 55% LA2 + 25% MVI1 + 10% Dev -> OperationalVault
        // uint256 la2Split = (_totalAmount * 5500) / TOTAL_BPS;
        // uint256 mviSplit = (_totalAmount * 2500) / TOTAL_BPS;
        // uint256 colSplit = (_totalAmount * 1000) / TOTAL_BPS;
        // uint256 devSplit = _totalAmount - la2Split - mviSplit - colSplit;

        uint256 colSplit = (_totalAmount * 1000) / TOTAL_BPS;
        uint256 opTransferAmount = _totalAmount - colSplit;

        // Transfer 1: Collective share -> YieldVault.
        uint256 yieldBalBefore = cNGNToken.balanceOf(address(yieldVault));
        cNGNToken.safeTransferFrom(_fundProvider, address(yieldVault), colSplit);
        uint256 actualColReceived = cNGNToken.balanceOf(address(yieldVault)) - yieldBalBefore;
        if (actualColReceived == 0) revert LAWPComplianceEngine_ZeroActualReceived();

        // Transfer 2: LA2 + MVI1 + Dev combined -> OperationalVault.
        uint256 opBalBefore = cNGNToken.balanceOf(address(operationalVault));
        cNGNToken.safeTransferFrom(_fundProvider, address(operationalVault), opTransferAmount);
        uint256 actualOpReceived = cNGNToken.balanceOf(address(operationalVault)) - opBalBefore;
        if (actualOpReceived == 0) revert LAWPComplianceEngine_ZeroActualReceived();

        // Pro-rate operational sub-allocations from actualOpReceived.
        // Original operational bucket: la2=5500, mvi=2500, dev=1000 (total=9000 BPS).
        // Rounding dust flows to devWallet (last assignment absorbs remainder).
        uint256 actualLa2 = (actualOpReceived * 5500) / 9000;
        uint256 actualMvi = (actualOpReceived * 2500) / 9000;
        uint256 actualDev = actualOpReceived - actualLa2 - actualMvi;

        // Credit internal ledger from actual amounts.
        poolYieldTracker[_poolId] += actualColReceived;
        operationalBalances[la2] += actualLa2;
        operationalBalances[mvi] += actualMvi;
        operationalBalances[devWallet] += actualDev;
    }

    /*//////////////////////////////////////////////////////////////
                               VIEW HELPERS
    //////////////////////////////////////////////////////////////*/

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

    /// @inheritdoc ILAWPComplianceEngine
    function isPoolActive(uint256 poolId) external view returns (bool) {
        return pools[poolId].exists;
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice            Calculates the accurate Continuous Yield and RoC owed,
    ///                    processes state updates, and emits events.
    /// @dev               Silently returns 0 if no funds are claimable to
    ///                    facilitate uninterrupted batch processing.
    /// @param _tokenId    The specific ID of the Impact Token.
    /// @param _tokenOwner The explicitly pre-fetched owner of the token to
    ///                    guarantee correct event emission.
    /// @return            claimable The aggregate cNGN amount owed to the token.
    function _claimYieldForToken(uint256 _tokenId, address _tokenOwner)
        internal
        returns (uint256 claimable)
    {
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
        uint256 claimableYield =
            totalYield > yieldClaimed[_tokenId] ? totalYield - yieldClaimed[_tokenId] : 0;

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
            emit YieldClaimed(_tokenId, _tokenOwner, claimableYield, claimableRoc);
        }
    }

    /// @notice Iterates over the `_bpsShares` array to confirm the sum equals exactly 10,000 (100%).
    /// @dev Extracted internally to optimize stack depth inside the `processPoolDeposit` function.
    function _validateBPS(uint256[] calldata _bpsShares, uint256 _contributorsLength)
        internal
        pure
    {
        uint256 totalBPS = 0;
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
                /* uint256 mintedTokenId = */
                impactToken.mint(_contributors[i], remainingCapital, _bpsShares[i], _poolId);
            } else {
                uint256 userNetPrincipal = (_netCapital * _bpsShares[i]) / TOTAL_BPS;
                remainingCapital -= userNetPrincipal;
                /* uint256 mintedTokenId = */
                impactToken.mint(_contributors[i], userNetPrincipal, _bpsShares[i], _poolId);
            }
            unchecked {
                ++i;
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                         OPERATOR VIEW HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ILAWPComplianceEngine
    function getPoolNetCapital(uint256 _poolId) external view returns (uint256) {
        if (!pools[_poolId].exists) revert LAWPComplianceEngine_InvalidPool();
        return poolTotalPrincipal[_poolId];
    }

    /// @inheritdoc ILAWPComplianceEngine
    function getRemainingRocCapacity(uint256 _poolId) external view returns (uint256) {
        if (!pools[_poolId].exists) revert LAWPComplianceEngine_InvalidPool();
        uint256 principal = poolTotalPrincipal[_poolId];
        uint256 routed = poolRocTracker[_poolId];
        return routed >= principal ? 0 : principal - routed;
    }

    /// @inheritdoc ILAWPComplianceEngine
    function getPoolRocStatus(uint256 _poolId)
        external
        view
        returns (uint256 netCapital, uint256 routedRoc, uint256 remainingRoc, bool settled)
    {
        if (!pools[_poolId].exists) revert LAWPComplianceEngine_InvalidPool();
        netCapital = poolTotalPrincipal[_poolId];
        routedRoc = poolRocTracker[_poolId];
        remainingRoc = routedRoc >= netCapital ? 0 : netCapital - routedRoc;
        settled = remainingRoc == 0;
    }
}
