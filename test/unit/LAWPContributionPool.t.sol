// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {LAWPFixture} from "../base/LAWPFixture.t.sol";
import {LAWPContributionPool} from "../../src/core/LAWPContributionPool.sol";
import {ILAWPContributionPool} from "../../src/interfaces/ILAWPContributionPool.sol";
import {LAWPConstants} from "../utils/LAWPConstants.sol";
import {MockFOTToken} from "../mocks/MockFOTToken.sol";

contract LAWPContributionPoolTest is LAWPFixture {
    uint256 constant ENGINE_POOL_ID = 1;
    uint256 constant GOAL = 10_000 * 1e6; // 10,000 cNGN
    uint256 constant MIN_CONTRIBUTION = 100 * 1e6;

    uint256 startTime;
    uint256 endTime;

    event PoolCreated(
        uint256 indexed poolId, uint256 indexed enginePoolId, uint256 goal, uint256 startTime, uint256 endTime
    );
    event PoolCancelled(uint256 indexed poolId);
    event ContributionMade(uint256 indexed poolId, address indexed contributor, uint256 amount, uint256 totalRaised);
    event PoolSettled(
        uint256 indexed poolId, uint256 indexed enginePoolId, uint256 totalRaised, uint256 contributorCount
    );
    event RefundClaimed(uint256 indexed poolId, address indexed contributor, uint256 amount);

    function setUp() public override {
        super.setUp();

        vm.prank(governance);
        engine.grantRole(LAWPConstants.CAMPAIGN_MANAGER_ROLE, address(pool));

        startTime = block.timestamp;
        endTime = block.timestamp + 7 days;
    }

    /*//////////////////////////////////////////////////////////////
                            1. CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/
    function test_RevertIf_ConstructorZeroAddress() public {
        vm.expectRevert(LAWPContributionPool.LAWPContributionPool__ZeroAddress.selector);
        new LAWPContributionPool(address(0), address(engine));

        vm.expectRevert(LAWPContributionPool.LAWPContributionPool__ZeroAddress.selector);
        new LAWPContributionPool(address(token), address(0));
    }

    /*//////////////////////////////////////////////////////////////
                            2. POOL CREATION
    //////////////////////////////////////////////////////////////*/
    function test_CreatePool_Success() public {
        vm.prank(campaignManager);

        vm.expectEmit(true, true, false, true);
        emit PoolCreated(1, ENGINE_POOL_ID, GOAL, startTime, endTime);

        uint256 poolId = pool.createPool(ENGINE_POOL_ID, GOAL, startTime, endTime);
        assertEq(poolId, 1);

        ILAWPContributionPool.PoolConfig memory config = pool.getPool(poolId);
        assertEq(config.enginePoolId, ENGINE_POOL_ID);
        assertEq(config.goal, GOAL);
        assertEq(config.startTime, startTime);
        assertEq(config.endTime, endTime);
        assertEq(config.totalRaised, 0);
        assertEq(config.contributorCount, 0);
        assertEq(uint256(config.status), uint256(ILAWPContributionPool.PoolStatus.Open));

        assertEq(pool.nextPoolId(), 2);
    }

    function test_RevertIf_CreatePool_Unauthorized() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(LAWPContributionPool.LAWPContributionPool__UnauthorizedCaller.selector);
        pool.createPool(ENGINE_POOL_ID, GOAL, startTime, endTime);
    }

    function test_RevertIf_CreatePool_InvalidEnginePool() public {
        vm.startPrank(campaignManager);

        vm.expectRevert(LAWPContributionPool.LAWPContributionPool__EngineInvalidPool.selector);
        pool.createPool(0, GOAL, startTime, endTime);

        // Setup an active pool in the engine
        _setupValidPool(1);

        vm.expectRevert(LAWPContributionPool.LAWPContributionPool__EngineInvalidPool.selector);
        pool.createPool(1, GOAL, startTime, endTime);
        vm.stopPrank();
    }

    function test_RevertIf_CreatePool_InvalidGoal() public {
        vm.prank(campaignManager);
        vm.expectRevert(LAWPContributionPool.LAWPContributionPool__InvalidGoal.selector);
        pool.createPool(ENGINE_POOL_ID, 0, startTime, endTime);
    }

    function test_RevertIf_CreatePool_InvalidWindow() public {
        vm.startPrank(campaignManager);

        // startTime >= endTime
        vm.expectRevert(LAWPContributionPool.LAWPContributionPool__InvalidWindow.selector);
        pool.createPool(ENGINE_POOL_ID, GOAL, endTime, startTime);

        // endTime <= block.timestamp
        vm.expectRevert(LAWPContributionPool.LAWPContributionPool__InvalidWindow.selector);
        pool.createPool(ENGINE_POOL_ID, GOAL, startTime - 1, block.timestamp);

        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                            3. POOL CANCELLATION
    //////////////////////////////////////////////////////////////*/
    function test_CancelPool_Success() public {
        vm.startPrank(campaignManager);
        uint256 poolId = pool.createPool(ENGINE_POOL_ID, GOAL, startTime, endTime);

        vm.expectEmit(true, false, false, false);
        emit PoolCancelled(poolId);

        pool.cancelPool(poolId);

        ILAWPContributionPool.PoolConfig memory config = pool.getPool(poolId);
        assertEq(uint256(config.status), uint256(ILAWPContributionPool.PoolStatus.Failed));
        vm.stopPrank();
    }

    function test_RevertIf_CancelPool_Unauthorized() public {
        vm.prank(campaignManager);
        uint256 poolId = pool.createPool(ENGINE_POOL_ID, GOAL, startTime, endTime);

        vm.prank(address(0xBEEF));
        vm.expectRevert(LAWPContributionPool.LAWPContributionPool__UnauthorizedCaller.selector);
        pool.cancelPool(poolId);
    }

    function test_RevertIf_CancelPool_InvalidPool() public {
        vm.prank(campaignManager);
        vm.expectRevert(LAWPContributionPool.LAWPContributionPool__InvalidPool.selector);
        pool.cancelPool(999);
    }

    function test_RevertIf_CancelPool_NotOpen() public {
        vm.startPrank(campaignManager);
        uint256 poolId = pool.createPool(ENGINE_POOL_ID, GOAL, startTime, endTime);
        pool.cancelPool(poolId); // transitions to Failed

        vm.expectRevert(LAWPContributionPool.LAWPContributionPool__PoolNotOpen.selector);
        pool.cancelPool(poolId);
        vm.stopPrank();
    }

    function test_RevertIf_CancelPool_NotEmpty() public {
        vm.prank(campaignManager);
        uint256 poolId = pool.createPool(ENGINE_POOL_ID, GOAL, startTime, endTime);

        address user = address(0xABCD);
        token.mint(user, MIN_CONTRIBUTION);
        vm.startPrank(user);
        token.approve(address(pool), MIN_CONTRIBUTION);
        pool.contribute(poolId, MIN_CONTRIBUTION);
        vm.stopPrank();

        vm.prank(campaignManager);
        vm.expectRevert(LAWPContributionPool.LAWPContributionPool__PoolNotEmpty.selector);
        pool.cancelPool(poolId);
    }

    /*//////////////////////////////////////////////////////////////
                            4. CONTRIBUTE
    //////////////////////////////////////////////////////////////*/
    function test_Contribute_Success() public {
        vm.prank(campaignManager);
        uint256 poolId = pool.createPool(ENGINE_POOL_ID, GOAL, startTime, endTime);

        address user = address(0x111);
        uint256 amount = 500 * 1e6;
        token.mint(user, amount);

        vm.startPrank(user);
        token.approve(address(pool), amount);

        vm.expectEmit(true, true, false, true);
        emit ContributionMade(poolId, user, amount, amount);

        pool.contribute(poolId, amount);
        vm.stopPrank();

        ILAWPContributionPool.ContributionRecord memory record = pool.getContribution(poolId, user);
        assertEq(record.amount, amount);
        assertEq(record.wadShare, 0);
        assertEq(record.refundClaimed, false);

        ILAWPContributionPool.PoolConfig memory config = pool.getPool(poolId);
        assertEq(config.totalRaised, amount);
        assertEq(config.contributorCount, 1);

        address[] memory contributors = pool.getContributors(poolId);
        assertEq(contributors.length, 1);
        assertEq(contributors[0], user);
    }

    function test_Contribute_TopUp() public {
        vm.prank(campaignManager);
        uint256 poolId = pool.createPool(ENGINE_POOL_ID, GOAL, startTime, endTime);

        address user = address(0x111);
        uint256 initialAmount = 200 * 1e6;
        uint256 topUpAmount = 300 * 1e6;
        token.mint(user, initialAmount + topUpAmount);

        vm.startPrank(user);
        token.approve(address(pool), initialAmount + topUpAmount);
        pool.contribute(poolId, initialAmount);

        // top up
        pool.contribute(poolId, topUpAmount);
        vm.stopPrank();

        ILAWPContributionPool.ContributionRecord memory record = pool.getContribution(poolId, user);
        assertEq(record.amount, initialAmount + topUpAmount);

        ILAWPContributionPool.PoolConfig memory config = pool.getPool(poolId);
        assertEq(config.totalRaised, initialAmount + topUpAmount);
        assertEq(config.contributorCount, 1); // should not increment

        address[] memory contributors = pool.getContributors(poolId);
        assertEq(contributors.length, 1);
    }

    function test_RevertIf_Contribute_InvalidPool() public {
        vm.expectRevert(LAWPContributionPool.LAWPContributionPool__InvalidPool.selector);
        pool.contribute(999, MIN_CONTRIBUTION);
    }

    function test_RevertIf_Contribute_TooSmall() public {
        vm.prank(campaignManager);
        uint256 poolId = pool.createPool(ENGINE_POOL_ID, GOAL, startTime, endTime);

        vm.expectRevert(LAWPContributionPool.LAWPContributionPool__ContributionTooSmall.selector);
        pool.contribute(poolId, MIN_CONTRIBUTION - 1);
    }

    function test_RevertIf_Contribute_NotOpen() public {
        vm.startPrank(campaignManager);
        uint256 poolId = pool.createPool(ENGINE_POOL_ID, GOAL, startTime, endTime);
        pool.cancelPool(poolId);
        vm.stopPrank();

        vm.expectRevert(LAWPContributionPool.LAWPContributionPool__PoolNotOpen.selector);
        pool.contribute(poolId, MIN_CONTRIBUTION);
    }

    function test_RevertIf_Contribute_WindowNotOpen() public {
        vm.prank(campaignManager);
        uint256 poolId = pool.createPool(ENGINE_POOL_ID, GOAL, block.timestamp + 1 days, block.timestamp + 7 days);

        vm.expectRevert(LAWPContributionPool.LAWPContributionPool__WindowNotOpen.selector);
        pool.contribute(poolId, MIN_CONTRIBUTION);

        vm.warp(block.timestamp + 8 days);
        vm.expectRevert(LAWPContributionPool.LAWPContributionPool__WindowNotOpen.selector);
        pool.contribute(poolId, MIN_CONTRIBUTION);
    }

    function test_RevertIf_Contribute_PoolFull() public {
        vm.prank(campaignManager);
        uint256 poolId = pool.createPool(ENGINE_POOL_ID, GOAL, startTime, endTime);

        // Fill up to MAX_CONTRIBUTORS
        uint256 max = pool.MAX_CONTRIBUTORS();
        for (uint256 i = 1; i <= max; i++) {
            address user = address(uint160(i));
            token.mint(user, MIN_CONTRIBUTION);
            vm.startPrank(user);
            token.approve(address(pool), MIN_CONTRIBUTION);
            pool.contribute(poolId, MIN_CONTRIBUTION);
            vm.stopPrank();
        }

        // Try 21st contributor
        address user21 = address(0x21);
        token.mint(user21, MIN_CONTRIBUTION);
        vm.startPrank(user21);
        token.approve(address(pool), MIN_CONTRIBUTION);

        vm.expectRevert(LAWPContributionPool.LAWPContributionPool__PoolFull.selector);
        pool.contribute(poolId, MIN_CONTRIBUTION);
        vm.stopPrank();

        // But 1st contributor can top up
        address user1 = address(uint160(1));
        token.mint(user1, MIN_CONTRIBUTION);
        vm.startPrank(user1);
        token.approve(address(pool), MIN_CONTRIBUTION);
        pool.contribute(poolId, MIN_CONTRIBUTION); // Success
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                            5. SETTLE
    //////////////////////////////////////////////////////////////*/
    function test_Settle_Success_WAD_Absorption() public {
        vm.prank(campaignManager);
        uint256 poolId = pool.createPool(ENGINE_POOL_ID, GOAL, startTime, endTime);

        // We use irregular amounts to test WAD dust absorption
        // sum = 10,000 cNGN
        address user1 = address(0x111);
        uint256 amt1 = 3333 * 1e6;

        address user2 = address(0x222);
        uint256 amt2 = 3333 * 1e6;

        address user3 = address(0x333);
        uint256 amt3 = 3334 * 1e6;

        _fundAndContribute(poolId, user1, amt1);
        _fundAndContribute(poolId, user2, amt2);
        _fundAndContribute(poolId, user3, amt3);

        vm.warp(endTime);

        vm.prank(campaignManager);
        vm.expectEmit(true, true, false, true);
        emit PoolSettled(poolId, ENGINE_POOL_ID, GOAL, 3);
        pool.settle(poolId);

        ILAWPContributionPool.PoolConfig memory config = pool.getPool(poolId);
        assertEq(uint256(config.status), uint256(ILAWPContributionPool.PoolStatus.Settled));

        // Check WAD shares exactly sum to 1e18
        uint256 w1 = pool.getContribution(poolId, user1).wadShare;
        uint256 w2 = pool.getContribution(poolId, user2).wadShare;
        uint256 w3 = pool.getContribution(poolId, user3).wadShare;

        assertEq(w1 + w2 + w3, pool.TOTAL_SHARES());

        // Check Engine received funds
        assertTrue(engine.isPoolActive(ENGINE_POOL_ID));
        assertEq(engine.getPoolNetCapital(ENGINE_POOL_ID), GOAL - ((GOAL * engine.riskFeeBPS()) / 10000));

        // Engine allowance should be 0
        assertEq(token.allowance(address(pool), address(engine)), 0);
    }

    function test_RevertIf_Settle_Unauthorized() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(LAWPContributionPool.LAWPContributionPool__UnauthorizedCaller.selector);
        pool.settle(1);
    }

    function test_RevertIf_Settle_InvalidPool() public {
        vm.prank(campaignManager);
        vm.expectRevert(LAWPContributionPool.LAWPContributionPool__InvalidPool.selector);
        pool.settle(999);
    }

    function test_RevertIf_Settle_AlreadySettled() public {
        vm.prank(campaignManager);
        uint256 poolId = pool.createPool(ENGINE_POOL_ID, GOAL, startTime, endTime);

        _fundAndContribute(poolId, address(0x111), GOAL);

        vm.startPrank(campaignManager);
        pool.settle(poolId);

        vm.expectRevert(LAWPContributionPool.LAWPContributionPool__AlreadySettled.selector);
        pool.settle(poolId);
        vm.stopPrank();
    }

    function test_RevertIf_Settle_WindowNotClosed() public {
        vm.prank(campaignManager);
        uint256 poolId = pool.createPool(ENGINE_POOL_ID, GOAL, startTime, endTime);

        _fundAndContribute(poolId, address(0x111), GOAL - 1);

        vm.prank(campaignManager);
        vm.expectRevert(LAWPContributionPool.LAWPContributionPool__WindowNotClosed.selector);
        pool.settle(poolId);
    }

    function test_RevertIf_Settle_GoalNotMet() public {
        vm.prank(campaignManager);
        uint256 poolId = pool.createPool(ENGINE_POOL_ID, GOAL, startTime, endTime);

        _fundAndContribute(poolId, address(0x111), GOAL - 1);

        vm.warp(endTime);

        vm.prank(campaignManager);
        vm.expectRevert(LAWPContributionPool.LAWPContributionPool__GoalNotMet.selector);
        pool.settle(poolId);
    }

    function test_Settle_EarlyIfGoalMet() public {
        vm.prank(campaignManager);
        uint256 poolId = pool.createPool(ENGINE_POOL_ID, GOAL, startTime, endTime);

        _fundAndContribute(poolId, address(0x111), GOAL); // meets goal before endTime

        vm.prank(campaignManager);
        pool.settle(poolId); // Should succeed
        assertEq(uint256(pool.getPool(poolId).status), uint256(ILAWPContributionPool.PoolStatus.Settled));
    }

    /*//////////////////////////////////////////////////////////////
                            6. REFUNDS
    //////////////////////////////////////////////////////////////*/
    function test_ClaimRefund_LazyTransition_Success() public {
        vm.prank(campaignManager);
        uint256 poolId = pool.createPool(ENGINE_POOL_ID, GOAL, startTime, endTime);

        address user = address(0x111);
        uint256 amt = 500 * 1e6;
        _fundAndContribute(poolId, user, amt);

        vm.warp(endTime);

        uint256 balBefore = token.balanceOf(user);

        vm.prank(user);
        vm.expectEmit(true, true, false, true);
        emit RefundClaimed(poolId, user, amt);
        pool.claimRefund(poolId);

        // Check transition to Failed happened lazily
        assertEq(uint256(pool.getPool(poolId).status), uint256(ILAWPContributionPool.PoolStatus.Failed));

        // Check tokens returned
        assertEq(token.balanceOf(user) - balBefore, amt);

        // Check record zeroed
        ILAWPContributionPool.ContributionRecord memory record = pool.getContribution(poolId, user);
        assertEq(record.amount, 0);
        assertTrue(record.refundClaimed);
    }

    function test_ClaimRefund_CancelledPool_Success() public {
        vm.prank(campaignManager);
        uint256 poolId = pool.createPool(ENGINE_POOL_ID, GOAL, startTime, endTime);

        // Cancel while 0 raised
        vm.prank(campaignManager);
        pool.cancelPool(poolId);

        // No contribution made, but let's test if someone tries
        address user = address(0x111);
        vm.prank(user);
        vm.expectRevert(LAWPContributionPool.LAWPContributionPool__NoContribution.selector);
        pool.claimRefund(poolId);
    }

    function test_RevertIf_ClaimRefund_InvalidPool() public {
        vm.expectRevert(LAWPContributionPool.LAWPContributionPool__InvalidPool.selector);
        pool.claimRefund(999);
    }

    function test_RevertIf_ClaimRefund_WindowNotClosed() public {
        vm.prank(campaignManager);
        uint256 poolId = pool.createPool(ENGINE_POOL_ID, GOAL, startTime, endTime);

        _fundAndContribute(poolId, address(0x111), MIN_CONTRIBUTION);

        vm.expectRevert(LAWPContributionPool.LAWPContributionPool__WindowNotClosed.selector);
        pool.claimRefund(poolId);
    }

    function test_RevertIf_ClaimRefund_GoalNotMet_FailsBecauseGoalMet() public {
        vm.prank(campaignManager);
        uint256 poolId = pool.createPool(ENGINE_POOL_ID, GOAL, startTime, endTime);

        _fundAndContribute(poolId, address(0x111), GOAL);

        vm.warp(endTime);

        vm.expectRevert(LAWPContributionPool.LAWPContributionPool__GoalNotMet.selector);
        pool.claimRefund(poolId);
    }

    function test_RevertIf_ClaimRefund_NotFailed() public {
        vm.prank(campaignManager);
        uint256 poolId = pool.createPool(ENGINE_POOL_ID, GOAL, startTime, endTime);

        _fundAndContribute(poolId, address(0x111), GOAL);

        vm.prank(campaignManager);
        pool.settle(poolId); // transitions to Settled

        vm.expectRevert(LAWPContributionPool.LAWPContributionPool__NotFailed.selector);
        pool.claimRefund(poolId);
    }

    function test_RevertIf_ClaimRefund_RefundAlreadyClaimed() public {
        vm.prank(campaignManager);
        uint256 poolId = pool.createPool(ENGINE_POOL_ID, GOAL, startTime, endTime);

        address user = address(0x111);
        _fundAndContribute(poolId, user, MIN_CONTRIBUTION);

        vm.warp(endTime);

        vm.startPrank(user);
        pool.claimRefund(poolId);

        vm.expectRevert(LAWPContributionPool.LAWPContributionPool__RefundAlreadyClaimed.selector);
        pool.claimRefund(poolId);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                            7. FEE ON TRANSFER INTEGRATION
    //////////////////////////////////////////////////////////////*/
    function test_Contribute_FOT_Token_DeductsAmount() public {
        // Deploy a new pool using FOT token instead of normal token
        MockFOTToken fotToken = new MockFOTToken();
        LAWPContributionPool fotPool = new LAWPContributionPool(address(fotToken), address(engine));

        // Admin creates pool
        vm.prank(campaignManager);
        uint256 poolId = fotPool.createPool(ENGINE_POOL_ID, GOAL, startTime, endTime);

        // User contributes 1,000. FOT takes 5%, so 950 arrives.
        address user = address(0x111);
        uint256 amount = 1000 * 1e6;
        fotToken.mint(user, amount);

        vm.startPrank(user);
        fotToken.approve(address(fotPool), amount);
        fotPool.contribute(poolId, amount);
        vm.stopPrank();

        uint256 expectedReceived = amount - ((amount * fotToken.feeBPS()) / 10000);

        ILAWPContributionPool.ContributionRecord memory record = fotPool.getContribution(poolId, user);
        assertEq(record.amount, expectedReceived);

        ILAWPContributionPool.PoolConfig memory config = fotPool.getPool(poolId);
        assertEq(config.totalRaised, expectedReceived);
    }

    function test_RevertIf_Contribute_ZeroActualReceived() public {
        // Mock a token that silently fails or takes 100% fee
        MockFOTToken badToken = new MockFOTToken();
        badToken.setFeeRate(10000); // 100% fee
        LAWPContributionPool badPool = new LAWPContributionPool(address(badToken), address(engine));

        vm.prank(campaignManager);
        uint256 poolId = badPool.createPool(ENGINE_POOL_ID, GOAL, startTime, endTime);

        address user = address(0x111);
        badToken.mint(user, MIN_CONTRIBUTION);

        vm.startPrank(user);
        badToken.approve(address(badPool), MIN_CONTRIBUTION);
        vm.expectRevert(LAWPContributionPool.LAWPContributionPool__ZeroActualReceived.selector);
        badPool.contribute(poolId, MIN_CONTRIBUTION);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                            8. VIEW FUNCTIONS edge cases
    //////////////////////////////////////////////////////////////*/
    function test_RevertIf_GetPool_InvalidPool() public {
        vm.expectRevert(LAWPContributionPool.LAWPContributionPool__InvalidPool.selector);
        pool.getPool(0);

        vm.expectRevert(LAWPContributionPool.LAWPContributionPool__InvalidPool.selector);
        pool.getPool(999);
    }

    function test_RevertIf_GetContribution_InvalidPool() public {
        vm.expectRevert(LAWPContributionPool.LAWPContributionPool__InvalidPool.selector);
        pool.getContribution(0, address(0x111));
    }

    function test_RevertIf_GetContributors_InvalidPool() public {
        vm.expectRevert(LAWPContributionPool.LAWPContributionPool__InvalidPool.selector);
        pool.getContributors(0);
    }

    /*//////////////////////////////////////////////////////////////
                            HELPERS
    //////////////////////////////////////////////////////////////*/
    function _fundAndContribute(uint256 _poolId, address _user, uint256 _amount) internal {
        token.mint(_user, _amount);
        vm.startPrank(_user);
        token.approve(address(pool), _amount);
        pool.contribute(_poolId, _amount);
        vm.stopPrank();
    }

    function _setupValidPool(uint256 _enginePoolId) internal {
        // Hack: process an empty/small valid deposit into the engine directly to make the pool active
        // so we can test `isPoolActive` failures
        uint256 goal = 1000 * 1e6;
        address[] memory c = new address[](1);
        c[0] = address(0x1);
        uint256[] memory w = new uint256[](1);
        w[0] = 1e18;

        token.mint(campaignManager, goal);
        // We assume _setupValidPool is called during an active prank of campaignManager
        token.approve(address(engine), goal);
        engine.processPoolDeposit(_enginePoolId, goal, c, w);
    }
}
