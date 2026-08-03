// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title  ILAWPContributionPool
/// @author Obinna Franklin Duru (BinnaDev)
/// @notice Public interface for the LAWP Permissionless Contribution Pool.
/// @dev    The LAWPContributionPool contract is a permissionless escrow that accepts
///         cNGN contributions for the LAWPComplianceEngine.
///         The admin can create contribution pools, and any user may contribute cNGN.
///         After the contribution period ends, the admin can settle the pool if the
///         funding goal is achieved; otherwise, contributors may claim refunds.
///         This interface defines the expected functions and data types for interacting
///         with the contribution pool.
interface ILAWPContributionPool {
    /*//////////////////////////////////////////////////////////////
                                  EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when the admin opens a new contribution pool slot.
    event PoolCreated(
        uint256 indexed poolId, uint256 indexed enginePoolId, uint256 goal, uint256 startTime, uint256 endTime
    );

    /// @notice Emitted when a contributor successfully deposits cNGNToken into a pool.
    event ContributionMade(uint256 indexed poolId, address indexed contributor, uint256 amount, uint256 newTotalRaised);

    /// @notice Emitted when settle() successfully routes funds into the ComplianceEngine.
    event PoolSettled(
        uint256 indexed poolId, uint256 indexed enginePoolId, uint256 totalRaised, uint256 contributorCount
    );

    /// @notice Emitted when a contributor reclaims their contribution from a failed pool.
    event RefundClaimed(uint256 indexed poolId, address indexed contributor, uint256 amount);

    /// @notice Emitted when the admin cancels an empty open pool.
    event PoolCancelled(uint256 indexed poolId);

    /*//////////////////////////////////////////////////////////////
                                  TYPES
    //////////////////////////////////////////////////////////////*/

    /// @notice Lifecycle state of a single contribution pool.
    /// @dev Transitions:
    ///      Open --- (deadline + goal met + settle()) ---> Settled
    ///      Open --- (deadline + goal NOT met, lazy) ---> Failed
    ///      Open --- (cancelPool(), totalRaised == 0) ---> Failed
    enum PoolStatus {
        Open, // Accepting contributions within the configured window
        Settled, // processPoolDeposit executed; Impact Tokens minted
        Failed // Goal not met or admin-cancelled; full refunds available
    }

    /// @notice All configuration and runtime state for a single pool.
    struct PoolConfig {
        uint256 enginePoolId; // poolId forwarded to LAWPComplianceEngine.processPoolDeposit
        uint256 goal; // Minimum gross cNGN required for settlement
        uint256 startTime; // Unix timestamp when contributions open
        uint256 endTime; // Unix timestamp when contributions close
        uint256 totalRaised; // Cumulative gross cNGN contributed
        uint256 contributorCount; // Number of unique contributor slots used
        PoolStatus status;
    }

    /// @notice Per-contributor record within a specific pool.
    struct ContributionRecord {
        uint256 amount; // Gross cNGN contributed to this pool
        uint256 wadShare; // Pro-rata WAD share (1e18 = 100%); computed and stored during settle()
        bool refundClaimed; // True after a successful claimRefund() call
    }

    /*//////////////////////////////////////////////////////////////
                           ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Opens a new contribution pool slot.
    /// @dev Only callable by the Campaign Manager Role.
    ///      Increments the internal nextPoolId counter and stores per-pool config.
    ///      `_maxContributors` must be ≤ 20 to satisfy the ComplianceEngine hard cap.
    /// @param _enginePoolId The poolId that will be passed to processPoolDeposit at settlement.
    ///                      Must not collide with an existing engine pool - enforced by the
    ///                      engine's PoolAlreadyExists guard at settlement time.
    /// @param _goal         Minimum gross cNGN required for the pool to settle successfully.
    /// @param _startTime    Unix timestamp when contributions become accepted.
    /// @param _endTime      Unix timestamp when the contribution window closes.
    /// @return poolId       The internal index of the newly created pool (starts at 1).
    function createPool(uint256 _enginePoolId, uint256 _goal, uint256 _startTime, uint256 _endTime)
        external
        returns (uint256 poolId);

    /// @notice Cancels an open pool that has received no contributions.
    /// @dev Sets status to Failed so no future contributions are possible.
    ///      There is nothing to refund because totalRaised must be 0.
    ///      Reverts if the pool has any contributions or is not in Open state.
    /// @param _poolId The internal pool index to cancel.
    function cancelPool(uint256 _poolId) external;

    /*//////////////////////////////////////////////////////////////
                         PERMISSIONLESS FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Deposits cNGN into the escrow for a specific pool.
    /// @dev Pulls cNGN from msg.sender via safeTransferFrom.
    ///      If the caller is a new contributor, they consume one slot from maxContributors.
    ///      If the caller has contributed before, their amount is aggregated (no new slot used).
    ///      Reverts if:
    ///        - _amount is below MIN_CONTRIBUTION (100 cNGN), which closes the WAD
    ///          zero-rounding DoS vector at the gate.
    ///        - The contribution window is not open.
    ///        - The pool is full (for new contributors).
    ///        - The pool is not in Open status.
    /// @param _poolId The internal pool index to contribute to.
    /// @param _amount Gross cNGN amount to deposit. Must be >= MIN_CONTRIBUTION.
    function contribute(uint256 _poolId, uint256 _amount) external;

    /// @notice Finalises a successful pool by routing funds to the ComplianceEngine.
    /// @dev Callable by the Campaign Manager Role after the deadline has passed and totalRaised >= goal.
    ///      Computes each contributor's pro-rata WAD share (last contributor absorbs dust
    ///      to guarantee the array sums to exactly 1e18).
    ///      Approves the engine for totalRaised, calls processPoolDeposit, then resets
    ///      the approval to 0. Sets pool status to Settled before the external call (CEI).
    /// @param _poolId The internal pool index to settle.
    function settle(uint256 _poolId) external;

    /// @notice Returns a contributor's full cNGN deposit from a failed pool.
    /// @dev If the pool is still Open but the deadline has passed and the goal was not met,
    ///      the status is lazily transitioned to Failed on the first call to this function.
    ///      Zeroes the contribution record before the transfer to prevent double-claiming.
    /// @param _poolId The internal pool index to claim a refund from.
    function claimRefund(uint256 _poolId) external;

    /*//////////////////////////////////////////////////////////////
                              VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the full configuration and runtime state for a pool.
    /// @param _poolId The internal pool index.
    function getPool(uint256 _poolId) external view returns (PoolConfig memory);

    /// @notice Returns a contributor's deposit record for a specific pool.
    /// @param _poolId      The internal pool index.
    /// @param _contributor The contributor address to query.
    function getContribution(uint256 _poolId, address _contributor) external view returns (ContributionRecord memory);

    /// @notice Returns the ordered list of contributor addresses for a pool.
    /// @dev Order matches the order contributions were first received.
    ///      Used internally by settle() to build the arrays for processPoolDeposit.
    /// @param _poolId The internal pool index.
    function getContributors(uint256 _poolId) external view returns (address[] memory);

    /// @notice Total number of pools ever created (including settled and failed).
    function nextPoolId() external view returns (uint256);
}
