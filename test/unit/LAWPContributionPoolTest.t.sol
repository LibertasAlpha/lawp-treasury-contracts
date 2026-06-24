// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { LAWPTestBase } from "../base/LAWPTestBase.sol";
import { LAWPContributionPool } from "../../src/core/LAWPContributionPool.sol";
import { ILAWPContributionPool } from "../../src/interfaces/ILAWPContributionPool.sol";
import { LAWPStructs } from "../../src/libraries/LAWPStructs.sol";

/// @title LAWPContributionPoolTest
/// @notice Comprehensive unit test suite for LAWPContributionPool.
/// @dev Inherits LAWPTestBase - all protocol contracts (engine, vaults, impact token,
///      registry, cNGN, contributionPool) are deployed and wired via setUp().
///      The test uses `contributionPool` from the base (not a separate local instance)
///      so the engine linkage is already correct.
///
///      KEY BEHAVIOURAL DIFFERENCES vs. the original draft:
///        1. poolCount starts at 1 - first pool created returns id = 1.
///        2. createPool() has NO maxContributors param - capacity is always MAX_CONTRIBUTORS (20).
///        3. settle() is onlyOwner, not permissionless.
///        4. Events are defined on the contract, not the interface - emit using
///           LAWPContributionPool.EventName.
///        5. The immutable is `cNGNToken`, not `cNGN`.
///        6. Constructor only checks engine/cNGN for zero - not admin.
contract LAWPContributionPoolTest is LAWPTestBase {
    /*//////////////////////////////////////////////////////////////
                            TEST CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 constant ENGINE_POOL_ID = 42; // engine-level poolId forwarded at settlement
    uint256 constant GOAL = 100_000e6; // 100,000 cNGN
    uint256 constant CONTRIBUTION_A = 60_000e6; // userA: 60 %
    uint256 constant CONTRIBUTION_B = 40_000e6; // userB: 40 %

    uint256 public startTime;
    uint256 public endTime;

    /*//////////////////////////////////////////////////////////////
                                SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() public override {
        super.setUp();
        // Window: open immediately, close in 7 days.
        startTime = block.timestamp;
        endTime = block.timestamp + 7 days;
    }

    /*//////////////////////////////////////////////////////////////
                         HELPER UTILITIES
    //////////////////////////////////////////////////////////////*/

    /// @dev Creates a standard pool and returns its id.
    function _createStandardPool() internal returns (uint256 poolId) {
        poolId = _createContribPool(ENGINE_POOL_ID, GOAL, startTime, endTime);
    }

    /// @dev Creates a standard pool, contributes CONTRIBUTION_A from userA and
    ///      CONTRIBUTION_B from userB, returning the poolId.
    function _createAndFundPool() internal returns (uint256 poolId) {
        poolId = _createStandardPool();
        _contribute(userA, poolId, CONTRIBUTION_A);
        _contribute(userB, poolId, CONTRIBUTION_B);
    }

    /// @dev Fast-forwards past the pool endTime.
    function _warpPastDeadline() internal {
        vm.warp(endTime + 1);
    }

    /*//////////////////////////////////////////////////////////////
                         CONSTRUCTOR TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Constructor_SetsImmutables() public view {
        assertEq(address(contributionPool.complianceEngine()), address(engine));
        assertEq(address(contributionPool.cNGNToken()), address(cngn));
        assertEq(contributionPool.owner(), admin);
        // poolCount initialised to 1 by constructor
        assertEq(contributionPool.poolCount(), 1);
    }

    function test_Constructor_RevertIf_ZeroCngn() public {
        vm.expectRevert(LAWPContributionPool.LAWPContributionPool__ZeroAddress.selector);
        new LAWPContributionPool(address(0), admin);
    }

    function test_RenounceOwnership_AlwaysReverts() public {
        vm.prank(admin);
        vm.expectRevert("LAWPContributionPool: renounceOwnership is disabled");
        contributionPool.renounceOwnership();
    }

    function test_SetComplianceEngine_Success() public {
        address newEngine = address(77);
        vm.prank(admin);
        vm.expectEmit(true, true, false, false);
        emit ILAWPContributionPool.ComplianceEngineUpdated(address(cngn), newEngine);
        contributionPool.setComplianceEngine(newEngine);
        assertEq(contributionPool.complianceEngine(), newEngine);
    }

    function test_SetComplianceEngine_RevertIf_ZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(LAWPContributionPool.LAWPContributionPool__ZeroAddress.selector);
        contributionPool.setComplianceEngine(address(0));
    }

    function test_SetComplianceEngine_RevertIf_NotOwner() public {
        vm.prank(address(12222222));
        vm.expectRevert();
        contributionPool.setComplianceEngine(address(77));
    }

    /*//////////////////////////////////////////////////////////////
                         createPool TESTS
    //////////////////////////////////////////////////////////////*/

    function test_CreatePool_Success_FirstPoolIdIsOne() public {
        vm.expectEmit(true, true, false, true);
        emit ILAWPContributionPool.PoolCreated(1, ENGINE_POOL_ID, GOAL, startTime, endTime);

        vm.prank(admin);
        uint256 poolId = contributionPool.createPool(ENGINE_POOL_ID, GOAL, startTime, endTime);

        assertEq(poolId, 1);
        assertEq(contributionPool.poolCount(), 2);

        ILAWPContributionPool.PoolConfig memory cfg = contributionPool.getPool(1);
        assertEq(cfg.enginePoolId, ENGINE_POOL_ID);
        assertEq(cfg.goal, GOAL);
        assertEq(cfg.startTime, startTime);
        assertEq(cfg.endTime, endTime);
        assertEq(cfg.totalRaised, 0);
        assertEq(cfg.contributorCount, 0);
        assertEq(uint8(cfg.status), uint8(ILAWPContributionPool.PoolStatus.Open));
    }

    function test_CreatePool_IncrementsPoolCount() public {
        vm.startPrank(admin);
        assertEq(contributionPool.createPool(1, GOAL, startTime, endTime), 1);
        assertEq(contributionPool.createPool(2, GOAL, startTime, endTime), 2);
        assertEq(contributionPool.createPool(3, GOAL, startTime, endTime), 3);
        vm.stopPrank();
        assertEq(contributionPool.poolCount(), 4);
    }

    function test_CreatePool_RevertIf_NotOwner() public {
        vm.prank(attacker);
        vm.expectRevert();
        contributionPool.createPool(ENGINE_POOL_ID, GOAL, startTime, endTime);
    }

    function test_CreatePool_RevertIf_EnginePoolIdZero() public {
        vm.prank(admin);
        vm.expectRevert(LAWPContributionPool.LAWPContributionPool__EnginePoolIdZero.selector);
        contributionPool.createPool(0, GOAL, startTime, endTime);
    }

    function test_CreatePool_RevertIf_ZeroGoal() public {
        vm.prank(admin);
        vm.expectRevert(LAWPContributionPool.LAWPContributionPool__InvalidGoal.selector);
        contributionPool.createPool(ENGINE_POOL_ID, 0, startTime, endTime);
    }

    function test_CreatePool_RevertIf_StartTimeEqualsEndTime() public {
        vm.prank(admin);
        vm.expectRevert(LAWPContributionPool.LAWPContributionPool__InvalidWindow.selector);
        contributionPool.createPool(ENGINE_POOL_ID, GOAL, startTime, startTime);
    }

    function test_CreatePool_RevertIf_EndTimeInPast() public {
        vm.prank(admin);
        vm.expectRevert(LAWPContributionPool.LAWPContributionPool__InvalidWindow.selector);
        contributionPool.createPool(ENGINE_POOL_ID, GOAL, block.timestamp - 2, block.timestamp - 1);
    }

    /*//////////////////////////////////////////////////////////////
                         cancelPool TESTS
    //////////////////////////////////////////////////////////////*/

    function test_CancelPool_Success_WhenEmpty() public {
        uint256 poolId = _createStandardPool();

        vm.expectEmit(true, false, false, false);
        emit ILAWPContributionPool.PoolCancelled(poolId);

        vm.prank(admin);
        contributionPool.cancelPool(poolId);

        assertEq(
            uint8(contributionPool.getPool(poolId).status),
            uint8(ILAWPContributionPool.PoolStatus.Failed)
        );
    }

    function test_CancelPool_RevertIf_NotOwner() public {
        uint256 poolId = _createStandardPool();
        vm.prank(attacker);
        vm.expectRevert();
        contributionPool.cancelPool(poolId);
    }

    function test_CancelPool_RevertIf_InvalidPool() public {
        vm.prank(admin);
        vm.expectRevert(LAWPContributionPool.LAWPContributionPool__InvalidPool.selector);
        contributionPool.cancelPool(999);
    }

    function test_CancelPool_RevertIf_HasContributions() public {
        uint256 poolId = _createStandardPool();
        _contribute(userA, poolId, 1e6);

        vm.prank(admin);
        vm.expectRevert(LAWPContributionPool.LAWPContributionPool__PoolNotEmpty.selector);
        contributionPool.cancelPool(poolId);
    }

    function test_CancelPool_RevertIf_AlreadySettled() public {
        uint256 poolId = _createAndFundPool();
        _warpPastDeadline();
        _settlePool(poolId);

        vm.prank(admin);
        vm.expectRevert(LAWPContributionPool.LAWPContributionPool__PoolNotOpen.selector);
        contributionPool.cancelPool(poolId);
    }

    /*//////////////////////////////////////////////////////////////
                         contribute TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Contribute_Success_NewContributor() public {
        uint256 poolId = _createStandardPool();
        uint256 balBefore = cngn.balanceOf(address(contributionPool));

        vm.prank(userA);
        cngn.approve(address(contributionPool), CONTRIBUTION_A);

        vm.expectEmit(true, true, false, true);
        emit ILAWPContributionPool.ContributionMade(poolId, userA, CONTRIBUTION_A, CONTRIBUTION_A);

        vm.prank(userA);
        contributionPool.contribute(poolId, CONTRIBUTION_A);

        // Pool holds the tokens
        assertEq(cngn.balanceOf(address(contributionPool)), balBefore + CONTRIBUTION_A);

        // State updated
        ILAWPContributionPool.PoolConfig memory cfg = contributionPool.getPool(poolId);
        assertEq(cfg.totalRaised, CONTRIBUTION_A);
        assertEq(cfg.contributorCount, 1);

        // Record persisted
        ILAWPContributionPool.ContributionRecord memory rec =
            contributionPool.getContribution(poolId, userA);
        assertEq(rec.amount, CONTRIBUTION_A);
        assertEq(rec.bpsShare, 0); // not computed until settle()
        assertFalse(rec.refundClaimed);
    }

    function test_Contribute_Success_TopUpExistingContributor() public {
        uint256 poolId = _createStandardPool();

        vm.startPrank(userA);
        cngn.approve(address(contributionPool), CONTRIBUTION_A * 2);
        contributionPool.contribute(poolId, CONTRIBUTION_A);
        contributionPool.contribute(poolId, CONTRIBUTION_A); // top-up
        vm.stopPrank();

        ILAWPContributionPool.PoolConfig memory cfg = contributionPool.getPool(poolId);
        assertEq(cfg.totalRaised, CONTRIBUTION_A * 2);
        assertEq(cfg.contributorCount, 1); // still only one slot

        assertEq(contributionPool.getContribution(poolId, userA).amount, CONTRIBUTION_A * 2);
        assertEq(contributionPool.getContributors(poolId).length, 1);
    }

    function test_Contribute_RegistersContributorsInOrder() public {
        uint256 poolId = _createStandardPool();
        _contribute(userA, poolId, CONTRIBUTION_A);
        _contribute(userB, poolId, CONTRIBUTION_B);

        address[] memory contribs = contributionPool.getContributors(poolId);
        assertEq(contribs.length, 2);
        assertEq(contribs[0], userA);
        assertEq(contribs[1], userB);
    }

    function test_Contribute_RevertIf_InvalidPool() public {
        vm.prank(userA);
        vm.expectRevert(LAWPContributionPool.LAWPContributionPool__InvalidPool.selector);
        contributionPool.contribute(999, 1e6);
    }

    function test_Contribute_RevertIf_ZeroAmount() public {
        uint256 poolId = _createStandardPool();
        vm.prank(userA);
        // Zero is below MIN_CONTRIBUTION so ContributionTooSmall fires first
        vm.expectRevert(LAWPContributionPool.LAWPContributionPool__ContributionTooSmall.selector);
        contributionPool.contribute(poolId, 0);
    }

    function test_Contribute_RevertIf_BelowMinContribution() public {
        uint256 poolId = _createStandardPool();
        uint256 dustAmount = contributionPool.MIN_CONTRIBUTION() - 1;
        cngn.mintTest(userA, dustAmount);
        vm.prank(userA);
        cngn.approve(address(contributionPool), dustAmount);
        vm.prank(userA);
        vm.expectRevert(LAWPContributionPool.LAWPContributionPool__ContributionTooSmall.selector);
        contributionPool.contribute(poolId, dustAmount);
    }

    function test_Contribute_RevertIf_BeforeWindowOpen() public {
        vm.prank(admin);
        uint256 poolId = contributionPool.createPool(
            ENGINE_POOL_ID, GOAL, block.timestamp + 1 days, block.timestamp + 8 days
        );

        uint256 minAmount = contributionPool.MIN_CONTRIBUTION();
        vm.prank(userA);
        cngn.approve(address(contributionPool), minAmount);
        vm.prank(userA);
        vm.expectRevert(LAWPContributionPool.LAWPContributionPool__WindowNotOpen.selector);
        contributionPool.contribute(poolId, minAmount);
    }

    function test_Contribute_RevertIf_AfterWindowClose() public {
        uint256 poolId = _createStandardPool();
        _warpPastDeadline();

        uint256 minAmount = contributionPool.MIN_CONTRIBUTION();
        vm.prank(userA);
        cngn.approve(address(contributionPool), minAmount);
        vm.prank(userA);
        vm.expectRevert(LAWPContributionPool.LAWPContributionPool__WindowNotOpen.selector);
        contributionPool.contribute(poolId, minAmount);
    }

    function test_Contribute_RevertIf_PoolFull() public {
        // Max contributors is the contract-level constant (20).
        // Seed 20 unique contributors to fill the pool, then verify a 21st reverts.
        uint256 poolId = _createStandardPool();
        // Each slot must be >= MIN_CONTRIBUTION (100e6 = 100 cNGN)
        uint256 slotAmount = contributionPool.MIN_CONTRIBUTION();

        // Fill all 20 slots
        for (uint160 i = 200; i < 220; i++) {
            address u = address(i);
            cngn.mintTest(u, slotAmount);
            vm.prank(u);
            cngn.approve(address(contributionPool), slotAmount);
            vm.prank(u);
            contributionPool.contribute(poolId, slotAmount);
        }

        // 21st unique address should fail
        address extra = address(300);
        cngn.mintTest(extra, slotAmount);
        vm.prank(extra);
        cngn.approve(address(contributionPool), slotAmount);
        vm.prank(extra);
        vm.expectRevert(LAWPContributionPool.LAWPContributionPool__PoolFull.selector);
        contributionPool.contribute(poolId, slotAmount);
    }

    function test_Contribute_ExistingContributor_CanTopUp_WhenPoolFull() public {
        uint256 poolId = _createStandardPool();
        // Each slot must be >= MIN_CONTRIBUTION
        uint256 slotAmount = contributionPool.MIN_CONTRIBUTION();

        // Fill all 20 slots
        for (uint160 i = 200; i < 220; i++) {
            address u = address(i);
            cngn.mintTest(u, slotAmount * 2);
            vm.prank(u);
            cngn.approve(address(contributionPool), slotAmount * 2);
            vm.prank(u);
            contributionPool.contribute(poolId, slotAmount);
        }

        // address(200) is an existing contributor - top-up must succeed even though pool is full
        vm.prank(address(200));
        contributionPool.contribute(poolId, slotAmount);
        assertEq(contributionPool.getContribution(poolId, address(200)).amount, slotAmount * 2);
    }

    function test_Contribute_RevertIf_PoolNotOpen() public {
        uint256 poolId = _createStandardPool();
        vm.prank(admin);
        contributionPool.cancelPool(poolId); // transitions to Failed

        uint256 minAmount = contributionPool.MIN_CONTRIBUTION();
        vm.prank(userA);
        cngn.approve(address(contributionPool), minAmount);
        vm.prank(userA);
        vm.expectRevert(LAWPContributionPool.LAWPContributionPool__PoolNotOpen.selector);
        contributionPool.contribute(poolId, minAmount);
    }

    /*//////////////////////////////////////////////////////////////
                           settle TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Settle_Success_HappyPath() public {
        uint256 poolId = _createAndFundPool();
        _warpPastDeadline();

        // ContributionPool holds full gross before settlement
        assertEq(cngn.balanceOf(address(contributionPool)), GOAL);

        uint256 opVaultBefore = cngn.balanceOf(address(operationalVault));

        vm.expectEmit(true, true, false, true);
        emit ILAWPContributionPool.PoolSettled(poolId, ENGINE_POOL_ID, GOAL, 2);

        _settlePool(poolId);

        // Pool drained to zero
        assertEq(cngn.balanceOf(address(contributionPool)), 0);
        // Engine routed the full gross into the operational vault
        assertEq(cngn.balanceOf(address(operationalVault)), opVaultBefore + GOAL);
        // Pool status flipped to Settled
        assertEq(
            uint8(contributionPool.getPool(poolId).status),
            uint8(ILAWPContributionPool.PoolStatus.Settled)
        );
        // Engine now recognises this enginePoolId as active
        assertTrue(engine.isPoolActive(ENGINE_POOL_ID));
    }

    function test_Settle_WadSharesStoredOnContributors() public {
        uint256 poolId = _createAndFundPool();
        _warpPastDeadline();
        _settlePool(poolId);

        // userA: 60_000 / 100_000 = 60% -> 6e17 WAD
        // userB: 40_000 / 100_000 = 40% -> 4e17 WAD
        assertEq(contributionPool.getContribution(poolId, userA).wadShare, 6e17);
        assertEq(contributionPool.getContribution(poolId, userB).wadShare, 4e17);
    }

    function test_Settle_WadAlwaysSumsTo1e18() public {
        uint256 poolId = _createAndFundPool();
        _warpPastDeadline();
        _settlePool(poolId);

        uint256 wadA = contributionPool.getContribution(poolId, userA).wadShare;
        uint256 wadB = contributionPool.getContribution(poolId, userB).wadShare;
        assertEq(wadA + wadB, 1e18);
    }

    function test_Settle_ApprovalResetAfterCall() public {
        uint256 poolId = _createAndFundPool();
        _warpPastDeadline();
        _settlePool(poolId);

        // Engine allowance on the pool must be 0 - approval hygiene invariant
        assertEq(cngn.allowance(address(contributionPool), address(engine)), 0);
    }

    function test_Settle_SingleContributor_Gets1e18WAD() public {
        vm.prank(admin);
        uint256 poolId = contributionPool.createPool(ENGINE_POOL_ID, GOAL, startTime, endTime);

        _contribute(userA, poolId, GOAL);
        _warpPastDeadline();
        _settlePool(poolId);

        // Sole contributor absorbs all WAD dust - must equal exactly 1e18
        assertEq(contributionPool.getContribution(poolId, userA).wadShare, 1e18);
    }

    function test_Settle_OnlyOwner_NotByAttacker() public {
        uint256 poolId = _createAndFundPool();
        _warpPastDeadline();

        // attacker cannot settle - settle is onlyOwner
        vm.prank(attacker);
        vm.expectRevert();
        contributionPool.settle(poolId);

        // admin CAN settle
        _settlePool(poolId);
    }

    function test_Settle_RevertIf_InvalidPool() public {
        vm.prank(admin);
        vm.expectRevert(LAWPContributionPool.LAWPContributionPool__InvalidPool.selector);
        contributionPool.settle(999);
    }

    function test_Settle_RevertIf_WindowNotClosed() public {
        uint256 poolId = _createAndFundPool();
        // Window still open
        vm.prank(admin);
        vm.expectRevert(LAWPContributionPool.LAWPContributionPool__WindowNotClosed.selector);
        contributionPool.settle(poolId);
    }

    function test_Settle_RevertIf_GoalNotMet() public {
        uint256 poolId = _createStandardPool();
        _contribute(userA, poolId, GOAL / 2); // half the goal
        _warpPastDeadline();

        vm.prank(admin);
        vm.expectRevert(LAWPContributionPool.LAWPContributionPool__GoalNotMet.selector);
        contributionPool.settle(poolId);
    }

    function test_Settle_RevertIf_AlreadySettled() public {
        uint256 poolId = _createAndFundPool();
        _warpPastDeadline();
        _settlePool(poolId);

        vm.prank(admin);
        vm.expectRevert(LAWPContributionPool.LAWPContributionPool__AlreadySettled.selector);
        contributionPool.settle(poolId);
    }

    function test_Settle_RevertIf_PoolCancelled() public {
        uint256 poolId = _createStandardPool();
        vm.prank(admin);
        contributionPool.cancelPool(poolId); // Failed status
        _warpPastDeadline();

        vm.prank(admin);
        vm.expectRevert(LAWPContributionPool.LAWPContributionPool__AlreadySettled.selector);
        contributionPool.settle(poolId);
    }

    /*//////////////////////////////////////////////////////////////
                        claimRefund TESTS
    //////////////////////////////////////////////////////////////*/

    function test_ClaimRefund_Success_FailedPool() public {
        uint256 poolId = _createStandardPool();
        _contribute(userA, poolId, CONTRIBUTION_A); // 60k of 100k goal - goal NOT met
        _warpPastDeadline();

        uint256 balBefore = cngn.balanceOf(userA);

        vm.expectEmit(true, true, false, true);
        emit ILAWPContributionPool.RefundClaimed(poolId, userA, CONTRIBUTION_A);

        vm.prank(userA);
        contributionPool.claimRefund(poolId);

        assertEq(cngn.balanceOf(userA), balBefore + CONTRIBUTION_A);
        assertEq(contributionPool.getContribution(poolId, userA).amount, 0);
        assertTrue(contributionPool.getContribution(poolId, userA).refundClaimed);
        assertEq(
            uint8(contributionPool.getPool(poolId).status),
            uint8(ILAWPContributionPool.PoolStatus.Failed)
        );
    }

    function test_ClaimRefund_LazilyTransitionsToFailed() public {
        uint256 poolId = _createStandardPool();
        _contribute(userA, poolId, CONTRIBUTION_A);
        _warpPastDeadline();

        // Before first claimRefund - still Open
        assertEq(
            uint8(contributionPool.getPool(poolId).status),
            uint8(ILAWPContributionPool.PoolStatus.Open)
        );

        vm.prank(userA);
        contributionPool.claimRefund(poolId);

        // Now Failed
        assertEq(
            uint8(contributionPool.getPool(poolId).status),
            uint8(ILAWPContributionPool.PoolStatus.Failed)
        );
    }

    function test_ClaimRefund_MultipleContributors_AllRefunded() public {
        uint256 poolId = _createStandardPool();
        _contribute(userA, poolId, CONTRIBUTION_A / 2);
        _contribute(userB, poolId, CONTRIBUTION_B / 2);
        _warpPastDeadline();

        uint256 balABefore = cngn.balanceOf(userA);
        uint256 balBBefore = cngn.balanceOf(userB);

        vm.prank(userA);
        contributionPool.claimRefund(poolId);
        vm.prank(userB);
        contributionPool.claimRefund(poolId);

        assertEq(cngn.balanceOf(userA), balABefore + CONTRIBUTION_A / 2);
        assertEq(cngn.balanceOf(userB), balBBefore + CONTRIBUTION_B / 2);
        // Contract fully drained
        assertEq(cngn.balanceOf(address(contributionPool)), 0);
    }

    function test_ClaimRefund_RevertIf_InvalidPool() public {
        vm.expectRevert(LAWPContributionPool.LAWPContributionPool__InvalidPool.selector);
        contributionPool.claimRefund(999);
    }

    function test_ClaimRefund_RevertIf_WindowNotClosed() public {
        uint256 poolId = _createStandardPool();
        vm.prank(userA);
        vm.expectRevert(LAWPContributionPool.LAWPContributionPool__WindowNotClosed.selector);
        contributionPool.claimRefund(poolId);
    }

    function test_ClaimRefund_RevertIf_GoalWasMet() public {
        uint256 poolId = _createAndFundPool();
        _warpPastDeadline();
        // goal met - should not refund
        vm.prank(userA);
        vm.expectRevert(LAWPContributionPool.LAWPContributionPool__GoalNotMet.selector);
        contributionPool.claimRefund(poolId);
    }

    function test_ClaimRefund_RevertIf_PoolSettled() public {
        uint256 poolId = _createAndFundPool();
        _warpPastDeadline();
        _settlePool(poolId);

        vm.prank(userA);
        vm.expectRevert(LAWPContributionPool.LAWPContributionPool__NotFailed.selector);
        contributionPool.claimRefund(poolId);
    }

    function test_ClaimRefund_RevertIf_NoContribution() public {
        uint256 poolId = _createStandardPool();
        _contribute(userA, poolId, CONTRIBUTION_A);
        _warpPastDeadline();

        // userC never contributed
        vm.prank(userC);
        vm.expectRevert(LAWPContributionPool.LAWPContributionPool__NoContribution.selector);
        contributionPool.claimRefund(poolId);
    }

    function test_ClaimRefund_RevertIf_AlreadyClaimed() public {
        uint256 poolId = _createStandardPool();
        _contribute(userA, poolId, CONTRIBUTION_A);
        _warpPastDeadline();

        vm.prank(userA);
        contributionPool.claimRefund(poolId);

        // Second attempt
        vm.prank(userA);
        vm.expectRevert(LAWPContributionPool.LAWPContributionPool__RefundAlreadyClaimed.selector);
        contributionPool.claimRefund(poolId);
    }

    /*//////////////////////////////////////////////////////////////
                      MULTI-POOL ISOLATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_MultiPool_TwoPoolsAreIndependent() public {
        vm.prank(admin);
        uint256 pool0 = contributionPool.createPool(ENGINE_POOL_ID, GOAL, startTime, endTime);
        vm.prank(admin);
        uint256 pool1 = contributionPool.createPool(ENGINE_POOL_ID + 1, GOAL, startTime, endTime);

        // Fund pool0 to goal
        _contribute(userA, pool0, GOAL);
        // Fund pool1 below goal
        _contribute(userB, pool1, GOAL / 2);

        _warpPastDeadline();

        // Settle pool0
        _settlePool(pool0);
        assertEq(
            uint8(contributionPool.getPool(pool0).status),
            uint8(ILAWPContributionPool.PoolStatus.Settled)
        );

        // Refund pool1
        vm.prank(userB);
        contributionPool.claimRefund(pool1);
        assertEq(
            uint8(contributionPool.getPool(pool1).status),
            uint8(ILAWPContributionPool.PoolStatus.Failed)
        );

        // Pool0 state untouched by pool1 operations
        assertEq(contributionPool.getPool(pool0).totalRaised, GOAL);
        assertEq(contributionPool.getContribution(pool0, userA).amount, GOAL);
    }

    function test_MultiPool_SameContributorCanParticipateInBothPools() public {
        vm.prank(admin);
        uint256 pool0 = contributionPool.createPool(ENGINE_POOL_ID, GOAL, startTime, endTime);
        vm.prank(admin);
        uint256 pool1 = contributionPool.createPool(ENGINE_POOL_ID + 1, GOAL, startTime, endTime);

        vm.prank(userA);
        cngn.approve(address(contributionPool), GOAL * 2);
        vm.prank(userA);
        contributionPool.contribute(pool0, GOAL);
        vm.prank(userA);
        contributionPool.contribute(pool1, GOAL);

        assertEq(contributionPool.getContribution(pool0, userA).amount, GOAL);
        assertEq(contributionPool.getContribution(pool1, userA).amount, GOAL);
    }

    function test_MultiPool_SequentialEnginePoolIds_NeverCollide() public {
        // Settle pool A with enginePoolId X, then settle pool B with enginePoolId Y ≠ X.
        // Each must register a distinct, independent pool in the engine.
        vm.prank(admin);
        uint256 p1 = contributionPool.createPool(ENGINE_POOL_ID, GOAL, startTime, endTime);
        vm.prank(admin);
        uint256 p2 = contributionPool.createPool(ENGINE_POOL_ID + 1, GOAL, startTime, endTime);

        _contribute(userA, p1, GOAL);
        _contribute(userB, p2, GOAL);

        _warpPastDeadline();
        _settlePool(p1);
        _settlePool(p2);

        assertTrue(engine.isPoolActive(ENGINE_POOL_ID));
        assertTrue(engine.isPoolActive(ENGINE_POOL_ID + 1));
    }

    /*//////////////////////////////////////////////////////////////
                      FULL E2E: POOL -> ENGINE -> YIELD
    //////////////////////////////////////////////////////////////*/

    /// @notice End-to-end test: contribute -> settle -> receive yield via engine.
    ///         Verifies the full lifecycle: escrow -> engine deposit -> impact token mint
    ///         -> revenue routing -> yield claim.
    function test_E2E_ContributeSettleYieldClaim() public {
        uint256 poolId = _createAndFundPool();
        _warpPastDeadline();
        _settlePool(poolId);

        // Impact tokens should now exist: userA (token 1, 60% WAD), userB (token 2, 40% WAD)
        assertEq(impactToken.ownerOf(1), userA);
        assertEq(impactToken.ownerOf(2), userB);
        assertEq(impactToken.getTokenData(1).poolShareWAD, 6e17); // 60%
        assertEq(impactToken.getTokenData(2).poolShareWAD, 4e17); // 40%

        // Route 10_000e6 GRANT_INITIAL -> 30% = 3_000e6 collective yield
        _routeRevenue(ENGINE_POOL_ID, 10_000e6, LAWPStructs.FlowType.GRANT_INITIAL);

        // userA: 60% of 3_000e6 = 1_800e6 yield
        uint256 balABefore = cngn.balanceOf(userA);
        vm.prank(userA);
        engine.claimYield(1);
        assertEq(cngn.balanceOf(userA), balABefore + 1_800e6);

        // userB: 40% of 3_000e6 = 1_200e6 yield
        uint256 balBBefore = cngn.balanceOf(userB);
        vm.prank(userB);
        engine.claimYield(2);
        assertEq(cngn.balanceOf(userB), balBBefore + 1_200e6);
    }

    /*//////////////////////////////////////////////////////////////
                         FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice WAD invariant: sum(wadShares) == 1e18 for any valid 2-contributor split.
    /// @dev Both amounts are bounded to [MIN_CONTRIBUTION, SEED_AMOUNT/2] so:
    ///       1. Neither contributor is below the DoS floor.
    ///       2. The total never overflows uint64.
    ///       3. The WAD share for each is guaranteed > 0 (since amount * 1e18 > totalRaised
    ///          is impossible when MIN_CONTRIBUTION enforces a 1e26 lower bound on totalRaised).
    function testFuzz_WadAlwaysSumsTo1e18_TwoContributors(uint64 amountA, uint64 amountB) public {
        uint256 minContrib = contributionPool.MIN_CONTRIBUTION();
        vm.assume(amountA >= minContrib && amountB >= minContrib);
        vm.assume(uint256(amountA) + uint256(amountB) <= SEED_AMOUNT);

        uint256 goal = uint256(amountA) + uint256(amountB);

        vm.prank(admin);
        uint256 poolId = contributionPool.createPool(ENGINE_POOL_ID, goal, startTime, endTime);

        _contribute(userA, poolId, amountA);
        _contribute(userB, poolId, amountB);

        _warpPastDeadline();
        _settlePool(poolId);

        uint256 wadA = contributionPool.getContribution(poolId, userA).wadShare;
        uint256 wadB = contributionPool.getContribution(poolId, userB).wadShare;
        assertEq(wadA + wadB, 1e18, "WAD shares must always sum to 1e18");
    }

    /// @notice Single contributor always gets exactly 1e18 WAD (100%).
    function testFuzz_SingleContributor_AlwaysGets1e18WAD(uint64 amount) public {
        uint256 minContrib = contributionPool.MIN_CONTRIBUTION();
        vm.assume(amount >= minContrib && amount <= SEED_AMOUNT);

        vm.prank(admin);
        uint256 poolId = contributionPool.createPool(ENGINE_POOL_ID, amount, startTime, endTime);

        _contribute(userA, poolId, amount);
        _warpPastDeadline();
        _settlePool(poolId);

        assertEq(contributionPool.getContribution(poolId, userA).wadShare, 1e18);
    }

    /// @notice Pool contract must hold zero cNGN after a successful settlement.
    function testFuzz_PoolHoldsZeroAfterSettle(uint64 amountA, uint64 amountB) public {
        uint256 minContrib = contributionPool.MIN_CONTRIBUTION();
        vm.assume(amountA >= minContrib && amountB >= minContrib);
        vm.assume(uint256(amountA) + uint256(amountB) <= SEED_AMOUNT);

        uint256 goal = uint256(amountA) + uint256(amountB);

        vm.prank(admin);
        uint256 poolId = contributionPool.createPool(ENGINE_POOL_ID, goal, startTime, endTime);

        _contribute(userA, poolId, amountA);
        _contribute(userB, poolId, amountB);

        _warpPastDeadline();
        _settlePool(poolId);

        assertEq(
            cngn.balanceOf(address(contributionPool)),
            0,
            "Pool must hold zero cNGN after settlement"
        );
    }

    /*//////////////////////////////////////////////////////////////
                         VIEW FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_GetPool_RevertIf_InvalidId() public view {
        // poolCount = 1 at deploy; id 0 is below the starting counter.
        bool reverted;
        try contributionPool.getPool(0) returns (ILAWPContributionPool.PoolConfig memory) {
            reverted = false;
        } catch {
            reverted = true;
        }
        assertTrue(reverted, "getPool(0) should revert before first pool is created");
    }

    function test_GetContributionReturnsZeroForNonContributor() public {
        uint256 poolId = _createStandardPool();
        ILAWPContributionPool.ContributionRecord memory rec =
            contributionPool.getContribution(poolId, attacker);
        assertEq(rec.amount, 0);
        assertEq(rec.wadShare, 0);
        assertFalse(rec.refundClaimed);
    }

    function test_GetContributors_ReturnsEmptyArrayForNewPool() public {
        uint256 poolId = _createStandardPool();
        assertEq(contributionPool.getContributors(poolId).length, 0);
    }
}
