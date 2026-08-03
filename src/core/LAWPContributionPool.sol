// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {ILAWPContributionPool} from "../interfaces/ILAWPContributionPool.sol";
import {ILAWPComplianceEngine} from "../interfaces/ILAWPComplianceEngine.sol";

/// @title LAWPContributionPool
/// @author Obinna Franklin Duru (BinnaDev)
/// @notice Permissionless, time-bound, goal-gated contribution pool for the LAWP Protocol.
/// @dev Replaces the off-chain assembly of contributor arrays with a transparent, on-chain
///      escrow that records individual contributions, computes pro-rata WAD shares at
///      settlement time, and routes capital to the ComplianceEngine's permissionless
///      processPoolDeposit in a single atomic call.
///
///      DESIGN INVARIANTS:
///      1. One contract - many pools.
///         Uses a nextPoolId counter + mapping pattern to store per-pool config and state,
///         so a single deployment serves all future pools without redeployment cost.
///
///      2. Strict CEI throughout.
///         In settle(): status -> Settled BEFORE the external engine call.
///         In claimRefund(): record zeroed BEFORE the cNGNToken transfer.
///         In contribute(): storage written BEFORE safeTransferFrom.
///
///      3. WAD dust absorption.
///         The last contributor in the ordered list absorbs rounding dust so
///         sum(wadShares) == TOTAL_SHARES == 1e18 is always guaranteed before
///         the array is forwarded to processPoolDeposit.
///
///      4. Approval hygiene.
///         The engine allowance is set to totalRaised immediately before the engine
///         call and reset to 0 immediately after, limiting the approval window to
///         the duration of a single call stack.
///
///      5. MAX_CONTRIBUTORS mirrors the ComplianceEngine's hard cap (20).
///         Configurable per pool up to this ceiling; enforced in createPool().
contract LAWPContributionPool is ILAWPContributionPool, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                            CONTRIBUTION POOL ERRORS
    //////////////////////////////////////////////////////////////*/

    error LAWPContributionPool__PoolFull();
    error LAWPContributionPool__NotFailed();
    error LAWPContributionPool__GoalNotMet();
    error LAWPContributionPool__ZeroAddress();
    error LAWPContributionPool__InvalidPool();
    error LAWPContributionPool__InvalidGoal();
    error LAWPContributionPool__PoolNotOpen();
    error LAWPContributionPool__PoolNotEmpty();
    error LAWPContributionPool__InvalidWindow();
    error LAWPContributionPool__WindowNotOpen();
    error LAWPContributionPool__AlreadySettled();
    error LAWPContributionPool__NoContribution();
    error LAWPContributionPool__WindowNotClosed();
    error LAWPContributionPool__EngineInvalidPool();
    error LAWPContributionPool__ZeroActualReceived();
    error LAWPContributionPool__RefundAlreadyClaimed();
    error LAWPContributionPool__ContributionTooSmall();
    error LAWPContributionPool__UnauthorizedCaller();

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Maximum unique contributors per pool - mirrors ComplianceEngine.MAX_CONTRIBUTORS.
    ///         Enforced in createPool() so that the wadShares array passed to
    ///         processPoolDeposit never exceeds the engine's ArrayTooLarge guard.
    uint256 public constant MAX_CONTRIBUTORS = 20;

    /// @notice WAD denominator for contributor equity shares (1e18 = 100%).
    ///         Matches the LAWPComplianceEngine.TOTAL_SHARES constant.
    ///         With a 1e18 denominator, a contributor's share rounds to 0 only if they
    ///         provide less than 1 quintillionth of the pool - economically impossible
    ///         at cNGN's 6-decimal scale.
    uint256 public constant TOTAL_SHARES = 1e18;

    /// @notice Minimum single contribution accepted by this pool (100 cNGN or ₦100).
    /// @dev Enforced at entry so every accepted contribution
    ///      receives a non-zero WAD share.
    ///
    ///      Zero-share condition:
    ///          (amount * 1e18) < totalRaised
    ///
    ///      With MIN_CONTRIBUTION = 100 * 1e6 = 1e9:
    ///          totalRaised >  (1e8 * 1e18 = 1e26 base units)
    ///      Reaching 1e26 base units would require totalRaised > 1e20 cNGN (100 Quintillion cNGN).
    ///
    ///      Therefore, accepted contributions cannot realistically
    ///      round to zero during settlement.
    uint256 public constant MIN_CONTRIBUTION = 100 * 1e6; // 100 cNGN (6 decimals)

    /*//////////////////////////////////////////////////////////////
                        PROTOCOL-LEVEL VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice The LAWPComplianceEngine contract that controls minting, updates, and claims. Critical for enforcing invariants and preventing double-spend exploits.
    ILAWPComplianceEngine public immutable complianceEngine;

    bytes32 public constant CAMPAIGN_MANAGER_ROLE = keccak256("CAMPAIGN_MANAGER_ROLE");

    /// @notice The cNGNToken ERC20 settlement token - the only accepted contribution currency.
    /// @dev Immutable: cNGNToken is the single accepted asset across the LAWP Protocol.
    IERC20 public immutable cNGNToken;

    /*//////////////////////////////////////////////////////////////
                         MULTI-POOL STATE REGISTRY
    //////////////////////////////////////////////////////////////*/

    /// @notice Next pool identifier to assign. Starts at 1; poolId 0 is reserved.
    uint256 public nextPoolId = 1;

    /// @notice Core configuration and runtime state for each pool.
    mapping(uint256 poolId => PoolConfig) private _pools;

    /// @notice Ordered list of unique contributor addresses per pool.
    /// @dev Insertion order is preserved. Used by settle() to build the calldata arrays
    ///      for processPoolDeposit. First-contribution order determines slot assignment.
    mapping(uint256 poolId => address[] contributors) private _contributorLists;

    /// @notice Per-contributor deposit records keyed by pool then address.
    mapping(uint256 poolId => mapping(address contributor => ContributionRecord)) private _contributions;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Initialises the contract with protocol-level constants.
    /// @dev All pool-specific parameters are configured via createPool().
    /// @param _cNGNToken   The cNGNToken ERC20 token address.
    /// @param _engine The LAWPComplianceEngine contract address.
    constructor(address _cNGNToken, address _engine) {
        if (_cNGNToken == address(0) || _engine == address(0)) revert LAWPContributionPool__ZeroAddress();

        cNGNToken = IERC20(_cNGNToken);
        complianceEngine = ILAWPComplianceEngine(_engine);
    }

    /*//////////////////////////////////////////////////////////////
                           ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ILAWPContributionPool
    /// @dev Uses nextPoolId++ (current value assigned, then incremented)
    function createPool(uint256 _enginePoolId, uint256 _goal, uint256 _startTime, uint256 _endTime)
        external
        override
        returns (uint256 poolId)
    {
        if (!IAccessControl(address(complianceEngine)).hasRole(CAMPAIGN_MANAGER_ROLE, msg.sender)) {
            revert LAWPContributionPool__UnauthorizedCaller();
        }
        // Checks
        if (_enginePoolId == 0 || complianceEngine.isPoolActive(_enginePoolId)) {
            revert LAWPContributionPool__EngineInvalidPool();
        }
        if (_goal == 0) revert LAWPContributionPool__InvalidGoal();

        // NOTE: The startTime may be in the past to tolerate transaction delays, but the endTime must be in the future to allow contributions.
        if (_startTime >= _endTime || _endTime <= block.timestamp) {
            revert LAWPContributionPool__InvalidWindow();
        }

        // Effects
        poolId = nextPoolId++;
        _pools[poolId] = PoolConfig({
            enginePoolId: _enginePoolId,
            goal: _goal,
            startTime: _startTime,
            endTime: _endTime,
            totalRaised: 0,
            contributorCount: 0,
            status: PoolStatus.Open
        });

        emit PoolCreated(poolId, _enginePoolId, _goal, _startTime, _endTime);
    }

    /// @inheritdoc ILAWPContributionPool
    /// @dev Cancellation is only permitted while the pool is Open AND has received no
    ///      contributions (totalRaised == 0).
    ///      Setting status to Failed is the correct terminal state - it makes the pool
    ///      ineligible for future contributions and eligible for refund queries (though
    ///      with zero raised, no refunds will be exercised).
    function cancelPool(uint256 _poolId) external override {
        if (!IAccessControl(address(complianceEngine)).hasRole(CAMPAIGN_MANAGER_ROLE, msg.sender)) {
            revert LAWPContributionPool__UnauthorizedCaller();
        }
        if (_poolId >= nextPoolId) revert LAWPContributionPool__InvalidPool();

        PoolConfig storage pool = _pools[_poolId];
        if (pool.status != PoolStatus.Open) revert LAWPContributionPool__PoolNotOpen();
        if (pool.totalRaised != 0) revert LAWPContributionPool__PoolNotEmpty();

        // Effects
        pool.status = PoolStatus.Failed;

        emit PoolCancelled(_poolId);
    }

    /*//////////////////////////////////////////////////////////////
                       PERMISSIONLESS FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ILAWPContributionPool
    /// @dev SECURITY - CEI ordering:
    ///      1. Minimum contribution floor enforced FIRST to close the WAD zero-rounding
    ///         DoS vector at the point of entry (see MIN_CONTRIBUTION for full proof).
    ///      2. Validate all remaining conditions (Checks)
    ///      3. Write storage: slot registration, amount accumulation, totalRaised (Effects)
    ///      4. Pull cNGNToken from caller (Interaction)
    ///      Storage is mutated before the external call so a re-entrant contribute()
    ///      would see the already-updated contributorCount and amount, preventing
    ///      any double-slot or double-amount exploit.
    ///
    ///      CONTRIBUTOR SLOT LOGIC:
    ///      - First contribution from an address -> consumes one slot,
    ///        pushed to _contributorLists.
    ///      - Subsequent contributions from the same address -> amount aggregated, no new slot.
    ///      This lets a contributor top up their position after the initial deposit.
    function contribute(uint256 _poolId, uint256 _amount) external override nonReentrant {
        // Checks
        if (_poolId >= nextPoolId) revert LAWPContributionPool__InvalidPool();
        if (_amount < MIN_CONTRIBUTION) revert LAWPContributionPool__ContributionTooSmall();

        PoolConfig storage pool = _pools[_poolId];
        if (pool.status != PoolStatus.Open) revert LAWPContributionPool__PoolNotOpen();
        if (block.timestamp < pool.startTime || block.timestamp >= pool.endTime) {
            revert LAWPContributionPool__WindowNotOpen();
        }

        ContributionRecord storage record = _contributions[_poolId][msg.sender];
        bool isNewContributor = record.amount == 0;

        // New contributor: enforce the slot capacity guard BEFORE mutating any state.
        if (isNewContributor && pool.contributorCount >= MAX_CONTRIBUTORS) {
            revert LAWPContributionPool__PoolFull();
        }

        // Effects
        if (isNewContributor) {
            // Register the contributor slot first - subsequent checks in the same tx
            // will see the updated contributorCount and find this address already recorded.
            pool.contributorCount++;
            _contributorLists[_poolId].push(msg.sender);
        }
        record.amount += _amount;
        pool.totalRaised += _amount;

        // Interaction
        // Snapshot the vault balance BEFORE the transfer.
        uint256 balBefore = cNGNToken.balanceOf(address(this));

        cNGNToken.safeTransferFrom(msg.sender, address(this), _amount);

        // Measure what actually landed in the vault.
        uint256 actualReceived = cNGNToken.balanceOf(address(this)) - balBefore;
        if (actualReceived == 0) revert LAWPContributionPool__ZeroActualReceived();

        // If the actual received is less than the intended amount, adjust the record and totalRaised accordingly.
        if (actualReceived != _amount) {
            uint256 delta = _amount - actualReceived;

            record.amount -= delta;
            pool.totalRaised -= delta;
        }

        emit ContributionMade(_poolId, msg.sender, actualReceived, pool.totalRaised);
    }

    /// @inheritdoc ILAWPContributionPool
    /// @dev SECURITY - CEI ordering:
    ///      1. Validate: deadline passed, goal met, pool not already settled (Checks)
    ///      2. Build in-memory contributors[] and bpsShares[] (no storage writes yet)
    ///      3. Write wadShare to each ContributionRecord (Effects - storage)
    ///      4. Set pool.status = Settled (Effects - critical guard before external call)
    ///      5. forceApprove(engine, totalRaised) (Interaction setup)
    ///      6. engine.processPoolDeposit(...) - pulls cNGNToken from this contract (Interaction)
    ///      7. forceApprove(engine, 0) - resets allowance (Approval hygiene)
    ///
    ///      WAD DUST ABSORPTION:
    ///      For each contributor i < last:  wad[i] = floor(amount[i] * 1e18 / totalRaised)
    ///      For the last contributor:       wad[last] = 1e18 - Σ(wad[0..last-1])
    ///      This guarantees Σ(wadShares) == 1e18 regardless of contributor count or
    ///      amounts, matching the engine's own _mintContributorShares dust-absorption
    ///      pattern. Because the denominator is 1e18, any contributor providing less
    ///      than 100 Quintillion cNGN of the pool rounds to 0 - economically impossible.
    function settle(uint256 _poolId) external override nonReentrant {
        if (!IAccessControl(address(complianceEngine)).hasRole(CAMPAIGN_MANAGER_ROLE, msg.sender)) {
            revert LAWPContributionPool__UnauthorizedCaller();
        }
        // Checks
        if (_poolId >= nextPoolId) revert LAWPContributionPool__InvalidPool();

        PoolConfig storage pool = _pools[_poolId];
        if (pool.status != PoolStatus.Open) revert LAWPContributionPool__AlreadySettled();
        if (block.timestamp < pool.endTime && pool.totalRaised < pool.goal) {
            revert LAWPContributionPool__WindowNotClosed();
        }
        if (pool.totalRaised < pool.goal) revert LAWPContributionPool__GoalNotMet();

        uint256 totalRaised = pool.totalRaised;
        uint256 contributorCount = pool.contributorCount;
        uint256 enginePoolId = pool.enginePoolId;

        // Build in-memory arrays
        address[] memory contributors = new address[](contributorCount);
        uint256[] memory wadShares = new uint256[](contributorCount);

        uint256 wadAccumulated = 0;

        // Note: goal > 0 and contributions atomically increment contributorCount
        //       so contributorCount > 0 is guaranteed by the goal check above.
        uint256 lastIndex = contributorCount - 1;

        for (uint256 i = 0; i < contributorCount;) {
            // loop from the storage array of contributor addresses who contributed to this pool.
            address contributor = _contributorLists[_poolId][i];

            // Write to the memory array of contributors for the engine call
            contributors[i] = contributor;

            uint256 wad;
            if (i == lastIndex) {
                // Last contributor absorbs all WAD rounding dust.
                // Guarantees sum(wadShares) == TOTAL_SHARES (1e18) exactly.
                wad = TOTAL_SHARES - wadAccumulated;
            } else {
                // Compute the contributor's pro-rata WAD share (1e18 = 100%).
                // Not their Money but their share of the pool's totalRaised. The last contributor absorbs any rounding dust.
                wad = (_contributions[_poolId][contributor].amount * TOTAL_SHARES) / totalRaised;
                wadAccumulated += wad;
            }

            wadShares[i] = wad;

            // Persist the computed WAD share into the contributor record for off-chain auditability.
            _contributions[_poolId][contributor].wadShare = wad;

            unchecked {
                ++i;
            }
        }

        // Effects: mark Settled BEFORE external call (CEI)
        pool.status = PoolStatus.Settled;

        // Interactions
        // 1. Grant the complianceEngine exactly the amount it needs to pull.
        //    forceApprove is used to handle any token that requires a zero-first reset.
        //    Since cNGNToken is upgradeable, this is a defensive pattern
        //    to prevent any future token-level changes.
        cNGNToken.forceApprove(address(complianceEngine), totalRaised);

        // 2. Call processPoolDeposit - complianceEngine pulls totalRaised cNGNToken from this contract,
        //    computes the risk fee, writes poolTotalPrincipal, and mints Impact Tokens.
        complianceEngine.processPoolDeposit(enginePoolId, totalRaised, contributors, wadShares);

        // 3. Reset approval to zero. If processPoolDeposit pulled the full amount the
        //    allowance is already 0,
        //    but this explicit reset is hygiene, not security-critical logic
        cNGNToken.forceApprove(address(complianceEngine), 0);

        emit PoolSettled(_poolId, enginePoolId, totalRaised, contributorCount);
    }

    /// @inheritdoc ILAWPContributionPool
    /// @dev LAZY FAILURE TRANSITION:
    ///      If the pool is still Open but the deadline has passed and the goal was not met,
    ///      this function transitions status to Failed before processing the refund.
    ///      This avoids a separate finalize() step and keeps the contract surface minimal.
    ///
    ///      SECURITY - CEI ordering:
    ///      1. Validate pool is refundable (Checks + lazy transition)
    ///      2. Validate caller has a non-zero, un-claimed contribution (Checks)
    ///      3. Zero the record and set refundClaimed = true (Effects)
    ///      4. Transfer cNGNToken back to the caller (Interaction)
    ///      Zeroing before transfer prevents a re-entrant claimRefund() from
    ///      observing a non-zero amount and claiming twice.
    function claimRefund(uint256 _poolId) external override nonReentrant {
        // Checks
        if (_poolId >= nextPoolId) revert LAWPContributionPool__InvalidPool();

        PoolConfig storage pool = _pools[_poolId];

        // Lazily resolve Open pools that have passed their deadline without meeting the goal.
        if (pool.status == PoolStatus.Open) {
            if (block.timestamp < pool.endTime) revert LAWPContributionPool__WindowNotClosed();
            if (pool.totalRaised >= pool.goal) revert LAWPContributionPool__GoalNotMet();
            // Effects (lazy transition)
            pool.status = PoolStatus.Failed;
        }

        if (pool.status != PoolStatus.Failed) revert LAWPContributionPool__NotFailed();

        ContributionRecord storage record = _contributions[_poolId][msg.sender];
        if (record.refundClaimed) revert LAWPContributionPool__RefundAlreadyClaimed();
        if (record.amount == 0) revert LAWPContributionPool__NoContribution();

        uint256 refundAmount = record.amount;

        // Effects: zero record before transfer to prevent re-entrancy double-claim
        record.amount = 0;
        record.refundClaimed = true;

        // Interaction
        cNGNToken.safeTransfer(msg.sender, refundAmount);

        emit RefundClaimed(_poolId, msg.sender, refundAmount);
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ILAWPContributionPool
    function getPool(uint256 _poolId) external view override returns (PoolConfig memory) {
        if (_poolId == 0 || _poolId >= nextPoolId) revert LAWPContributionPool__InvalidPool();
        return _pools[_poolId];
    }

    /// @inheritdoc ILAWPContributionPool
    function getContribution(uint256 _poolId, address _contributor)
        external
        view
        override
        returns (ContributionRecord memory)
    {
        if (_poolId == 0 || _poolId >= nextPoolId) {
            revert LAWPContributionPool__InvalidPool();
        }
        return _contributions[_poolId][_contributor];
    }

    /// @inheritdoc ILAWPContributionPool
    function getContributors(uint256 _poolId) external view override returns (address[] memory) {
        if (_poolId == 0 || _poolId >= nextPoolId) revert LAWPContributionPool__InvalidPool();
        return _contributorLists[_poolId];
    }
}
