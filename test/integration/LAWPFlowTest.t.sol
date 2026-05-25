// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { LAWPTestBase } from "../base/LAWPTestBase.sol";
import { LAWPStructs } from "../../src/libraries/LAWPStructs.sol";
import { console2 } from "forge-std/Script.sol";

/// @title LAWPFlowTest
/// @notice End-to-end integration test covering the full LAWP Protocol lifecycle.
/// @dev Validates: deposit -> revenue routing -> NFT transfer hook -> secondary claims.
///      Enforces vault isolation, zero-custody engine/controller invariants, and
///      confirms the relayer is the sole ERC20 fund provider throughout.
contract LAWPFlowTest is LAWPTestBase {
    /*//////////////////////////////////////////////////////////////
                      FULL LIFECYCLE FLOW TEST
    //////////////////////////////////////////////////////////////*/

    /// @notice SCENARIO:
    ///   1. Coordinator deposits 100_000e6 for 10 users (10% each).
    ///   2. GRANT_INITIAL: 50_000e6 routed - 30% (15_000e6) -> yieldVault, 70% -> operationalVault.
    ///   3. User[0] transfers token to a buyer - hook flushes pending yield to user[0].
    ///   4. GRANT_CONTINUOUS: 20_000e6 routed. RoC: 10_000e6 routed.
    ///   5. Buyer claims yield + RoC on the transferred token.
    ///   6. LA2 claims operational funds.
    function test_FullLifecycleFlow() public {
        // -- STEP 1: 10-user pool deposit -------------------------------------
        address[] memory users = new address[](10);
        uint256[] memory bps = new uint256[](10);
        for (uint160 i = 0; i < 10; i++) {
            users[i] = address(100 + i);
            bps[i] = 1000; // 10% each
        }

        uint256 grossDeposit = 100_000e6;
        uint256 riskFee = 10_000e6; // 10%
        // uint256 netCapital = 90_000e6;
        uint256 perUserNet = 9_000e6; // 10% of netCapital

        _seedAndApprove();

        vm.prank(coordinator);
        engine.processPoolDeposit(1, grossDeposit, users, bps);

        // Verify vault balances
        assertEq(cngn.balanceOf(address(yieldVault)), grossDeposit); // gross in yieldVault
        assertEq(cngn.balanceOf(address(operationalVault)), riskFee);
        // Engine and MockMultiSig hold zero
        assertEq(cngn.balanceOf(address(engine)), 0);
        assertEq(cngn.balanceOf(address(mockMultiSig)), 0);

        // Each user has a token with 9_000e6 principal
        for (uint256 i = 0; i < 10; i++) {
            assertEq(impactToken.ownerOf(i + 1), users[i]);
            assertEq(impactToken.getTokenData(i + 1).netPrincipal, perUserNet);
        }

        // -- STEP 2: GRANT_INITIAL - 50_000e6 ----------------------------------
        // 30% collective (15_000e6) -> yieldVault
        // 50% LA2 (25_000e6) + 20% MVI1 (10_000e6) -> operationalVault
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

        // -- STEP 3: User[0] transfers Token 1 to a buyer ----------------------
        // Expected yield for Token 1 (10% of 15_000e6 collective) = 1_500e6
        address user0 = users[0];
        address buyer = address(999);
        uint256 expectedYield = 1_500e6;

        uint256 user0BalBefore = cngn.balanceOf(user0);

        vm.prank(user0);
        impactToken.transferFrom(user0, buyer, 1);

        // Hook must flush pending yield to user0
        assertEq(cngn.balanceOf(user0), user0BalBefore + expectedYield);
        // Buyer inherits zero pending yield
        assertEq(engine.calculateProportionalYield(1), 0);
        assertEq(impactToken.ownerOf(1), buyer);

        // -- STEP 4: More revenue -----------------------------------------------
        // GRANT_CONTINUOUS for buyer: 20_000e6 -> 10% collective = 2_000e6
        // RoC for Buyer: 10_000e6 -> buyer's 10% = 1_000e6 (capped at principal 9_000e6)

        // GRANT_CONTINUOUS for la2Wallet: 20_000e6 -> 55% of operational = 11_000e6
        _routeRevenue(1, 20_000e6, LAWPStructs.FlowType.GRANT_CONTINUOUS);
        _routeRevenue(1, 10_000e6, LAWPStructs.FlowType.RoC);

        // -- STEP 5: Buyer claims yield + RoC ----------------------------------
        // Buyer's yield: 2_000e6 * 10% = 200e6
        // Buyer's RoC:   10_000e6 * 10% = 1_000e6
        uint256 buyerBalBefore = cngn.balanceOf(buyer);
        vm.prank(buyer);
        engine.claimYield(1);

        assertEq(cngn.balanceOf(buyer), buyerBalBefore + 200e6 + 1_000e6);
        assertEq(engine.calculateProportionalYield(1), 0);

        // -- STEP 6: LA2 claims operational funds ------------------------------
        uint256 la2BalBefore = cngn.balanceOf(la2Wallet);
        vm.prank(la2Wallet);
        engine.claimOperationalFunds(la2Wallet);

        assertEq(cngn.balanceOf(la2Wallet), la2BalBefore + la2Split + 11_000e6);
        assertEq(engine.operationalBalances(la2Wallet), 0);

        // Final vault integrity check
        assertEq(cngn.balanceOf(address(engine)), 0);
        assertEq(cngn.balanceOf(address(mockMultiSig)), 0);
    }

    /*//////////////////////////////////////////////////////////////
                     MULTI-POOL ISOLATION TEST
    //////////////////////////////////////////////////////////////*/

    function test_MultiPool_YieldIsolation() public {
        // Pool A: coordinator deposits for userA
        (address[] memory cA, uint256[] memory bA) = _singleContributor(userA);
        vm.prank(coordinator);
        engine.processPoolDeposit(1, 100_000e6, cA, bA);

        // Pool B: coordinator deposits for userB
        (address[] memory cB, uint256[] memory bB) = _singleContributor(userB);
        vm.prank(coordinator);
        engine.processPoolDeposit(2, 200_000e6, cB, bB);

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
        (address[] memory c, uint256[] memory b) = _singleContributor(userA);

        vm.startPrank(coordinator);
        engine.processPoolDeposit(1, 100_000e6, c, b);
        engine.processPoolDeposit(2, 50_000e6, c, b);
        engine.processPoolDeposit(3, 75_000e6, c, b);
        vm.stopPrank();

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
        engine.claimOperationalFunds(la2Wallet);
        vm.prank(mvi1Wallet);
        engine.claimOperationalFunds(mvi1Wallet);
        vm.prank(devWallet);
        engine.claimOperationalFunds(devWallet);

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
        vm.prank(address(mockMultiSig));
        engine.emergencyPause();

        // Deposit blocked
        (address[] memory c, uint256[] memory b) = _singleContributor(userA);
        vm.prank(coordinator);
        vm.expectRevert();
        engine.processPoolDeposit(1, 100_000e6, c, b);

        // Revenue routing blocked
        vm.prank(coordinator);
        vm.expectRevert();
        mockMultiSig.execute(1, 10_000e6, LAWPStructs.FlowType.RoC);

        // Resume
        vm.prank(admin);
        engine.unpause();

        // Now works
        vm.prank(coordinator);
        engine.processPoolDeposit(1, 100_000e6, c, b);
    }
}
