// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { LAWPTestBase } from "../base/LAWPTestBase.sol";
import { LAWPStructs } from "../../src/libraries/LAWPStructs.sol";
import { ILAWPContributionPool } from "../../src/interfaces/ILAWPContributionPool.sol";

/// @title LAWPFlowTest
/// @notice End-to-end integration tests covering the full LAWP Protocol lifecycle.
/// @dev Tests:
///      1. Direct-coordinator deposit -> revenue routing -> NFT transfer -> secondary claims.
///      2. ContributionPool deposit -> engine registration -> yield distribution.
///      3. Multi-pool yield isolation.
///      4. Batch yield claims.
///      5. Operational actor claims.
///      6. Pause blocks all flows.
contract LAWPFlowTest is LAWPTestBase {
    /*//////////////////////////////////////////////////////////////
                       DIRECT COORDINATOR FLOW
    //////////////////////////////////////////////////////////////*/

    /// @notice SCENARIO (DEMO: Full Lifecycle Flow):
    ///   ACT 1: Coordinator deposits 100_000e6 for 10 users (10% each).
    ///   ACT 2: GRANT_INITIAL: 50_000e6 routed - 30% (15_000e6) -> yieldVault, 70% -> opVault.
    ///   ACT 3: User[0] transfers token to buyer - hook flushes pending yield to User[0].
    ///   ACT 4: GRANT_CONTINUOUS: 20_000e6 routed. RoC: 10_000e6 routed.
    ///   ACT 5: Buyer claims yield + RoC on the transferred token. LA2 claims operational funds.
    function test_FullLifecycleFlow() public {
        // =========================================================================
        // ACT 1: The Setup & Deposit
        // =========================================================================
        address[] memory users = new address[](10);
        uint256 poolId =
            _createContribPool(1, 100_000e6, block.timestamp, block.timestamp + 1 hours);
        for (uint160 i = 0; i < 10; i++) {
            users[i] = address(100 + i);
            cngn.mintTest(users[i], 10_000e6);
            _contribute(users[i], poolId, 10_000e6);
        }

        // Visualize the user and their contribuition
        // [addr1, addr2, addr3, addr4, addr5, addr6, addr7, addr8, addr9, addr10]
        // [10_000e6, 10_000e6, 10_000e6, 10_000e6, 10_000e6, 10_000e6, 10_000e6, 10_000e6, 10_000e6, 10_000e6] = 100_000e6

        uint256 grossDeposit = 100_000e6;
        uint256 perUserNet = 9_000e6; // 90% of netCapital of user contribution after riskfee has been taken

        // After riskFee deduction, the engine receives 90_000e6 net capital for the pool.
        // [addr1, addr2, addr3, addr4, addr5, addr6, addr7, addr8, addr9, addr10]
        // [9_000e6, 9_000e6, 9_000e6, 9_000e6, 9_000e6, 9_000e6, 9_000e6, 9_000e6, 9_000e6, 9_000e6] = 90_000e6
        // riskFee = 10_000e6 (10% of grossDeposit)

        vm.warp(block.timestamp + 1 hours + 1);
        _settlePool(poolId);

        // Verify Vault Balances: 100% of raw capital hits the Operational Vault immediately.
        // The Yield Vault remains completely empty (funded only by subsequent revenue).
        assertEq(cngn.balanceOf(address(operationalVault)), grossDeposit);
        assertEq(cngn.balanceOf(address(yieldVault)), 0);
        assertEq(cngn.balanceOf(address(engine)), 0);
        assertEq(cngn.balanceOf(address(mockMultiSig)), 0);

        // Verify NFT Minting: Each user automatically receives a fractional equity ERC721.
        for (uint256 i = 0; i < 10; i++) {
            assertEq(impactToken.ownerOf(i + 1), users[i]);
            assertEq(impactToken.getTokenData(i + 1).netPrincipal, perUserNet);
        }

        // =========================================================================
        // ACT 2: Revenue Routing (GRANT_INITIAL)
        // =========================================================================
        // Splitting 50,000e6:
        // -> 30% collective (15_000e6) routed to the Yield Vault for investors.
        // -> 50% LA2 (25_000e6) + 20% MVI1 (10_000e6) hits the Operational Ledger.
        uint256 grantAmount = 50_000e6;
        uint256 colSplit = 15_000e6;
        uint256 la2Split = 25_000e6;
        uint256 mviSplit = 10_000e6;

        _routeRevenue(1, grantAmount, LAWPStructs.FlowType.GRANT_INITIAL);

        assertEq(engine.poolYieldTracker(1), colSplit);
        assertEq(engine.operationalBalances(la2Wallet), la2Split);
        assertEq(engine.operationalBalances(mvi1Wallet), mviSplit);
        assertEq(cngn.balanceOf(address(engine)), 0);
        assertEq(cngn.balanceOf(address(mockMultiSig)), 0);

        // =========================================================================
        // ACT 3: The "Yield Sniper" Prevention Hook
        // =========================================================================
        // User[0] transfers Token 1 to a Buyer.
        // Expected pending yield for Token 1 (10% of 15_000e6 collective) = 1_500e6
        address user0 = users[0];
        address buyer = address(999);
        uint256 expectedYield = 1_500e6;

        uint256 user0BalBefore = cngn.balanceOf(user0);

        vm.prank(user0);
        impactToken.transferFrom(user0, buyer, 1);

        // The ERC721 hook automatically intercepts the transfer and flushes the yield to User[0].
        assertEq(cngn.balanceOf(user0), user0BalBefore + expectedYield);

        // The Buyer receives the token, but their claimable yield is reset to zero.
        assertEq(engine.calculateProportionalYield(1), 0);
        assertEq(impactToken.ownerOf(1), buyer);

        // =========================================================================
        // ACT 4: Continuous Yield & Return of Capital (RoC)
        // =========================================================================
        // Route a continuous grant and a Return of Capital.
        // Buyer is entitled to 10% of this NEW yield since they now hold the token.
        _routeRevenue(1, 20_000e6, LAWPStructs.FlowType.GRANT_CONTINUOUS);
        _routeRevenue(1, 10_000e6, LAWPStructs.FlowType.RoC);

        // =========================================================================
        // ACT 5: Secondary Claims
        // =========================================================================
        // Buyer claims their newly generated yield (10% of 2_000) and RoC (10% of 10_000).
        uint256 buyerBalBefore = cngn.balanceOf(buyer);
        vm.prank(buyer);
        engine.claimYield(1);

        assertEq(cngn.balanceOf(buyer), buyerBalBefore + 200e6 + 1_000e6);
        assertEq(engine.calculateProportionalYield(1), 0);

        // LA2 Operational Wallet pulls its accumulated revenue from the vault.
        uint256 la2BalBefore = cngn.balanceOf(la2Wallet);
        vm.prank(la2Wallet);
        engine.claimOperationalFunds();

        // 25,000 from Initial Grant + 11,000 from Continuous Grant.
        assertEq(cngn.balanceOf(la2Wallet), la2BalBefore + la2Split + 11_000e6);
        assertEq(engine.operationalBalances(la2Wallet), 0);

        // Final architecture integrity check: Core orchestrators must never hold funds.
        assertEq(cngn.balanceOf(address(engine)), 0);
        assertEq(cngn.balanceOf(address(mockMultiSig)), 0);
    }

    /*//////////////////////////////////////////////////////////////
              CONTRIBUTION POOL -> ENGINE FULL FLOW
    //////////////////////////////////////////////////////////////*/

    /// @notice SCENARIO: Admin opens a contribution pool, users contribute,
    ///         admin settles, then revenue is routed and yield claimed.
    ///         Confirms that the ContributionPool correctly registers the pool
    ///         with the engine and that yield flows to the correct token owners.
    function test_ContributionPool_FullFlow() public {
        uint256 startTime = block.timestamp;
        uint256 endTime = block.timestamp + 7 days;

        // 1. Create a pool targeting enginePoolId = 100
        uint256 poolId = _createContribPool(100, 100_000e6, startTime, endTime);

        // 2. userA (60%) and userB (40%) contribute
        _contribute(userA, poolId, 60_000e6);
        _contribute(userB, poolId, 40_000e6);

        // Pool holds the gross
        assertEq(cngn.balanceOf(address(contributionPool)), 100_000e6);

        // 3. Advance past deadline and settle (admin only)
        vm.warp(endTime + 1);
        _settlePool(poolId);

        // ContributionPool fully drained
        assertEq(cngn.balanceOf(address(contributionPool)), 0);
        // Engine registered the pool
        assertTrue(engine.isPoolActive(100));

        // Impact tokens minted: token 1 -> userA (60% WAD), token 2 -> userB (40% WAD)
        assertEq(impactToken.ownerOf(1), userA);
        assertEq(impactToken.ownerOf(2), userB);
        assertEq(impactToken.getTokenData(1).poolShareWAD, 6e17);
        assertEq(impactToken.getTokenData(2).poolShareWAD, 4e17);

        // 4. Route GRANT_INITIAL 50_000e6 -> collective = 15_000e6
        _routeRevenue(100, 50_000e6, LAWPStructs.FlowType.GRANT_INITIAL);

        // 5. Claim yield
        // userA: 60% of 15_000e6 = 9_000e6
        uint256 balABefore = cngn.balanceOf(userA);
        vm.prank(userA);
        engine.claimYield(1);
        assertEq(cngn.balanceOf(userA), balABefore + 9_000e6);

        // userB: 40% of 15_000e6 = 6_000e6
        uint256 balBBefore = cngn.balanceOf(userB);
        vm.prank(userB);
        engine.claimYield(2);
        assertEq(cngn.balanceOf(userB), balBBefore + 6_000e6);

        // Zero pending after claims
        assertEq(engine.calculateProportionalYield(1), 0);
        assertEq(engine.calculateProportionalYield(2), 0);
    }

    /// @notice Verifies that a failed pool (goal not met) correctly refunds all contributors.
    function test_ContributionPool_FailedPool_Refunds() public {
        uint256 startTime = block.timestamp;
        uint256 endTime = block.timestamp + 3 days;

        uint256 poolId = _createContribPool(101, 100_000e6, startTime, endTime);

        // Only 60% of goal contributed
        _contribute(userA, poolId, 60_000e6);

        vm.warp(endTime + 1);

        // Pool status: still Open until first claimRefund or explicit transition
        assertEq(
            uint8(contributionPool.getPool(poolId).status),
            uint8(ILAWPContributionPool.PoolStatus.Open)
        );

        uint256 balBefore = cngn.balanceOf(userA);
        vm.prank(userA);
        contributionPool.claimRefund(poolId);

        // Full refund received
        assertEq(cngn.balanceOf(userA), balBefore + 60_000e6);
        // Pool transitioned to Failed
        assertEq(
            uint8(contributionPool.getPool(poolId).status),
            uint8(ILAWPContributionPool.PoolStatus.Failed)
        );
        // Pool contract holds zero
        assertEq(cngn.balanceOf(address(contributionPool)), 0);
    }

    /// @notice Sequential pools on the same contract - engine pool ids must not collide.
    function test_ContributionPool_SequentialPools_EngineIsolation() public {
        uint256 startTime = block.timestamp;
        uint256 endTime = block.timestamp + 7 days;

        // Pool 1 - enginePoolId 200
        uint256 p1 = _createContribPool(200, 50_000e6, startTime, endTime);
        _contribute(userA, p1, 50_000e6);

        // Pool 2 - enginePoolId 201
        uint256 p2 = _createContribPool(201, 50_000e6, startTime, endTime);
        _contribute(userB, p2, 50_000e6);

        vm.warp(endTime + 1);
        _settlePool(p1);
        _settlePool(p2);

        assertTrue(engine.isPoolActive(200));
        assertTrue(engine.isPoolActive(201));

        // Route yield to pool 200 only - pool 201 remains unaffected
        _routeRevenue(200, 10_000e6, LAWPStructs.FlowType.GRANT_INITIAL);
        assertGt(engine.poolYieldTracker(200), 0);
        assertEq(engine.poolYieldTracker(201), 0);
    }

    /// @notice Verify settle is onlyOwner - non-admin cannot trigger settlement.
    function test_ContributionPool_Settle_OnlyOwner() public {
        uint256 startTime = block.timestamp;
        uint256 endTime = block.timestamp + 7 days;

        uint256 poolId = _createContribPool(202, 60_000e6, startTime, endTime);
        _contribute(userA, poolId, 60_000e6);
        vm.warp(endTime + 1);

        vm.prank(attacker);
        vm.expectRevert();
        contributionPool.settle(poolId);

        // Admin CAN settle
        _settlePool(poolId);
        assertTrue(engine.isPoolActive(202));
    }

    /*//////////////////////////////////////////////////////////////
                 MULTI-POOL YIELD ISOLATION TEST
    //////////////////////////////////////////////////////////////*/

    function test_MultiPool_YieldIsolation() public {
        // Pool A: coordinator deposits for userA
        uint256 p1 = _createContribPool(1, 100_000e6, block.timestamp, block.timestamp + 1 hours);
        _contribute(userA, p1, 100_000e6);

        // Pool B: coordinator deposits for userB
        uint256 p2 = _createContribPool(2, 200_000e6, block.timestamp, block.timestamp + 1 hours);
        _contribute(userB, p2, 200_000e6);

        vm.warp(block.timestamp + 1 hours + 1);
        _settlePool(p1);
        _settlePool(p2);

        // Route yield only to Pool A
        _routeRevenue(1, 10_000e6, LAWPStructs.FlowType.GRANT_INITIAL);

        // Pool A has 3_000e6 collective yield; Pool B has none
        assertEq(engine.poolYieldTracker(1), 3_000e6);
        assertEq(engine.poolYieldTracker(2), 0);

        // Token 1 (userA, pool A) has claimable yield; Token 2 (userB, pool B) has none
        assertGt(engine.calculateProportionalYield(1), 0);
        assertEq(engine.calculateProportionalYield(2), 0);
    }

    /*//////////////////////////////////////////////////////////////
               BATCH YIELD CLAIM INTEGRATION TEST
    //////////////////////////////////////////////////////////////*/

    function test_BatchClaim_MultipleTokens() public {
        // Deposit 3 tokens to userA (pools 1, 2, 3)
        uint256 p1 = _createContribPool(1, 100_000e6, block.timestamp, block.timestamp + 1 hours);
        _contribute(userA, p1, 100_000e6);

        uint256 p2 = _createContribPool(2, 50_000e6, block.timestamp, block.timestamp + 1 hours);
        _contribute(userA, p2, 50_000e6);

        uint256 p3 = _createContribPool(3, 75_000e6, block.timestamp, block.timestamp + 1 hours);
        _contribute(userA, p3, 75_000e6);

        vm.warp(block.timestamp + 1 hours + 1);
        _settlePool(p1);
        _settlePool(p2);
        _settlePool(p3);

        // Route yield to all 3 pools
        _routeRevenue(1, 10_000e6, LAWPStructs.FlowType.GRANT_INITIAL); // 3_000 col
        _routeRevenue(2, 20_000e6, LAWPStructs.FlowType.GRANT_CONTINUOUS); // 2_000 col
        _routeRevenue(3, 15_000e6, LAWPStructs.FlowType.GRANT_INITIAL); // 4_500 col

        // UserA owns all 3 tokens (ids 1, 2, 3)
        uint256[] memory tokenIds = new uint256[](3);
        tokenIds[0] = 1;
        tokenIds[1] = 2;
        tokenIds[2] = 3;

        uint256 balBefore = cngn.balanceOf(userA);
        vm.prank(userA);
        engine.claimYieldBatch(tokenIds);

        // Total expected: 3_000 + 2_000 + 4_500 = 9_500e6
        assertEq(cngn.balanceOf(userA), balBefore + 9_500e6);
        assertEq(engine.calculateProportionalYield(1), 0);
        assertEq(engine.calculateProportionalYield(2), 0);
        assertEq(engine.calculateProportionalYield(3), 0);
    }

    /*//////////////////////////////////////////////////////////////
              OPERATIONAL CLAIMS INTEGRATION TEST
    //////////////////////////////////////////////////////////////*/

    function test_AllOperationalActorsClaim() public {
        // GRANT_CONTINUOUS: la2=55%, mvi=25%, col=10%, dev=10%
        // On 10_000e6: la2=5_500, mvi=2_500, col=1_000, dev=1_000
        _routeRevenue(1, 10_000e6, LAWPStructs.FlowType.GRANT_CONTINUOUS);

        // All operational wallets claim their allocations
        uint256 la2Bal = cngn.balanceOf(la2Wallet);
        uint256 mviBal = cngn.balanceOf(mvi1Wallet);
        uint256 devBal = cngn.balanceOf(devWallet);

        vm.prank(la2Wallet);
        engine.claimOperationalFunds();
        vm.prank(mvi1Wallet);
        engine.claimOperationalFunds();
        vm.prank(devWallet);
        engine.claimOperationalFunds();

        assertEq(cngn.balanceOf(la2Wallet), la2Bal + 5_500e6);
        assertEq(cngn.balanceOf(mvi1Wallet), mviBal + 2_500e6);
        assertEq(cngn.balanceOf(devWallet), devBal + 1_000e6);

        // All operational balances zeroed
        assertEq(engine.operationalBalances(la2Wallet), 0);
        assertEq(engine.operationalBalances(mvi1Wallet), 0);
        assertEq(engine.operationalBalances(devWallet), 0);

        // Engine and MockMultiSig still hold zero
        assertEq(cngn.balanceOf(address(engine)), 0);
        assertEq(cngn.balanceOf(address(mockMultiSig)), 0);
    }

    /*//////////////////////////////////////////////////////////////
             ADVERSARIAL: PAUSE BLOCKS ALL FLOWS
    //////////////////////////////////////////////////////////////*/

    function test_Pause_BlocksAllFlows() public {
        vm.prank(admin);
        engine.emergencyPause();

        // Direct deposit blocked
        uint256 p1 = _createContribPool(1, 100_000e6, block.timestamp, block.timestamp + 1 hours);
        _contribute(userA, p1, 100_000e6);
        vm.warp(block.timestamp + 1 hours + 1);

        vm.expectRevert(bytes4(keccak256("EnforcedPause()")));
        _settlePool(p1);

        // Revenue routing blocked
        vm.prank(coordinator);
        vm.expectRevert(bytes4(keccak256("EnforcedPause()")));
        mockMultiSig.execute(1, 10_000e6, LAWPStructs.FlowType.RoC);

        // Resume
        vm.prank(admin);
        engine.unpause();

        // Now works
        _settlePool(p1);
    }

    /// @notice Pause does NOT affect contributionPool.contribute() (pool is an independent
    ///         escrow). Only settle() touches the engine, so a paused engine blocks settlement.
    function test_Pause_BlocksPoolSettlement_NotContribute() public {
        uint256 startTime = block.timestamp;
        uint256 endTime = block.timestamp + 7 days;

        uint256 poolId = _createContribPool(300, 60_000e6, startTime, endTime);

        // Contributions are pure escrow - engine pause must NOT affect them
        vm.prank(admin);
        engine.emergencyPause();

        _contribute(userA, poolId, 60_000e6); // must succeed
        assertEq(cngn.balanceOf(address(contributionPool)), 60_000e6);

        vm.warp(endTime + 1);

        // settle() calls engine.processPoolDeposit - blocked by pause
        vm.prank(admin);
        vm.expectRevert();
        contributionPool.settle(poolId);

        // Unpause and settle succeeds
        vm.prank(admin);
        engine.unpause();
        _settlePool(poolId);
        assertTrue(engine.isPoolActive(300));
    }
}
