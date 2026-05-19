// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { LAWPTestBase } from "../base/LAWPTestBase.sol";
import { LAWPComplianceEngine } from "../../src/core/LAWPComplianceEngine.sol";
import { LAWPYieldVault } from "../../src/core/LAWPYieldVault.sol";
import { LAWPOperationalVault } from "../../src/core/LAWPOperationalVault.sol";
import { LAWPStructs } from "../../src/libraries/LAWPStructs.sol";

/// @title LAWPComplianceEngineTest
/// @notice Unit tests for LAWPComplianceEngine - the core protocol logic contract.
/// @dev Tests: constructor immutables and guards, admin functions 
///     (multi-sig controller, risk fee, pause), processPoolDeposit (success, edge cases, reverts),
///     routeOperationalAllocation (success, reverts), claimYield (success, edge cases, reverts),
///     claimOperationalFunds (success, edge cases, reverts), and adversarial/replay scenarios.
contract LAWPComplianceEngineTest is LAWPTestBase {
    /*//////////////////////////////////////////////////////////////
                         CONSTRUCTOR TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Constructor_SetsImmutables() public view {
        assertEq(address(engine.yieldVault()), address(yieldVault));
        assertEq(address(engine.operationalVault()), address(operationalVault));
        assertEq(address(engine.impactToken()), address(impactToken));
        assertEq(address(engine.registry()), address(registry));
        assertEq(address(engine.cngnToken()), address(cngn));
        assertEq(engine.riskFeeBPS(), RISK_FEE_BPS);
        assertEq(engine.owner(), admin);
    }

    function test_Constructor_RevertIf_ZeroVault() public {
        vm.expectRevert(LAWPComplianceEngine.LAWPComplianceEngine_ZeroAddress.selector);
        new LAWPComplianceEngine(
            admin,
            address(0),
            address(operationalVault),
            address(impactToken),
            address(registry),
            address(cngn),
            1000
        );
    }

    function test_Constructor_RevertIf_ZeroOpVault() public {
        vm.expectRevert(LAWPComplianceEngine.LAWPComplianceEngine_ZeroAddress.selector);
        new LAWPComplianceEngine(
            admin,
            address(yieldVault),
            address(0),
            address(impactToken),
            address(registry),
            address(cngn),
            1000
        );
    }

    function test_Constructor_RevertIf_ZeroToken() public {
        vm.expectRevert(LAWPComplianceEngine.LAWPComplianceEngine_ZeroAddress.selector);
        new LAWPComplianceEngine(
            admin,
            address(yieldVault),
            address(operationalVault),
            address(0),
            address(registry),
            address(cngn),
            1000
        );
    }

    function test_Constructor_RevertIf_ZeroRegistry() public {
        vm.expectRevert(LAWPComplianceEngine.LAWPComplianceEngine_ZeroAddress.selector);
        new LAWPComplianceEngine(
            admin,
            address(yieldVault),
            address(operationalVault),
            address(impactToken),
            address(0),
            address(cngn),
            1000
        );
    }

    function test_Constructor_RevertIf_ZeroCngn() public {
        vm.expectRevert(LAWPComplianceEngine.LAWPComplianceEngine_ZeroAddress.selector);
        new LAWPComplianceEngine(
            admin,
            address(yieldVault),
            address(operationalVault),
            address(impactToken),
            address(registry),
            address(0),
            1000
        );
    }

    function test_Constructor_RevertIf_ZeroRiskFee() public {
        vm.expectRevert(LAWPComplianceEngine.LAWPComplianceEngine_InvalidRiskFee.selector);
        new LAWPComplianceEngine(
            admin,
            address(yieldVault),
            address(operationalVault),
            address(impactToken),
            address(registry),
            address(cngn),
            0
        );
    }

    function test_Constructor_RevertIf_RiskFeeExceedsMax() public {
        vm.expectRevert(LAWPComplianceEngine.LAWPComplianceEngine_InvalidRiskFee.selector);
        new LAWPComplianceEngine(
            admin,
            address(yieldVault),
            address(operationalVault),
            address(impactToken),
            address(registry),
            address(cngn),
            1001
        );
    }

    /*//////////////////////////////////////////////////////////////
                           ADMIN TESTS
    //////////////////////////////////////////////////////////////*/

    function test_RenounceOwnership_IsDisabled() public {
        vm.prank(admin);
        vm.expectRevert("LAWPComplianceEngine: renounceOwnership is disabled");
        engine.renounceOwnership();
    }

    function test_SetMultiSigController_Success() public {
        vm.prank(admin);
        engine.setMultiSigController(address(99));
        assertEq(engine.multiSigController(), address(99));
    }

    function test_SetMultiSigController_RevertIf_ZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(LAWPComplianceEngine.LAWPComplianceEngine_ZeroAddress.selector);
        engine.setMultiSigController(address(0));
    }

    function test_SetMultiSigController_RevertIf_NotOwner() public {
        vm.prank(attacker);
        vm.expectRevert();
        engine.setMultiSigController(address(99));
    }

    function test_UpdateRiskFee_Success() public {
        vm.prank(admin);
        engine.updateRiskFee(500);
        assertEq(engine.riskFeeBPS(), 500);
    }

    function test_UpdateRiskFee_RevertIf_ZeroOrExceedsMax() public {
        vm.startPrank(admin);
        vm.expectRevert(LAWPComplianceEngine.LAWPComplianceEngine_InvalidRiskFee.selector);
        engine.updateRiskFee(0);
        vm.expectRevert(LAWPComplianceEngine.LAWPComplianceEngine_InvalidRiskFee.selector);
        engine.updateRiskFee(1001);
        vm.stopPrank();
    }

    function test_EmergencyPause_OnlyMultiSig() public {
        vm.prank(address(mockMultiSig));
        engine.emergencyPause();
        assertTrue(engine.paused());

        vm.prank(attacker);
        vm.expectRevert(LAWPComplianceEngine.LAWPComplianceEngine_UnauthorizedCaller.selector);
        engine.emergencyPause();
    }

    function test_Unpause_OnlyOwner() public {
        vm.prank(address(mockMultiSig));
        engine.emergencyPause();

        vm.prank(admin);
        engine.unpause();
        assertFalse(engine.paused());

        vm.prank(attacker);
        vm.expectRevert();
        engine.unpause();
    }

    /*//////////////////////////////////////////////////////////////
                      PROCESS POOL DEPOSIT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_ProcessPoolDeposit_Success() public {
        uint256 gross = 100_000e6;
        uint256 expectedRiskFee = 10_000e6;
        uint256 expectedNet = 90_000e6;

        uint256 yieldBefore = cngn.balanceOf(address(yieldVault));
        uint256 opBefore = cngn.balanceOf(address(operationalVault));

        (address[] memory c, uint256[] memory b) = _singleContributor(userA);
        vm.prank(coordinator);
        engine.processPoolDeposit(1, gross, c, b);

        // Fee split
        assertEq(cngn.balanceOf(address(operationalVault)), opBefore + expectedRiskFee);
        assertEq(cngn.balanceOf(address(yieldVault)), yieldBefore + gross);

        // Pool registered
        (bool exists,) = engine.pools(1);
        assertTrue(exists);

        // Token minted to userA with full net capital
        LAWPStructs.TokenData memory data = impactToken.getTokenData(1);
        assertEq(data.netPrincipal, expectedNet);
        assertEq(data.poolShareBPS, 10_000);
        assertEq(data.poolId, 1);

        // MockMultiSig + engine hold zero
        assertEq(cngn.balanceOf(address(mockMultiSig)), 0);
        assertEq(cngn.balanceOf(address(engine)), 0);
    }

    function test_ProcessPoolDeposit_DustGoesToLastContributor() public {
        uint256 gross = 100_000e6; // net = 90_000e6
        address[] memory c = new address[](3);
        c[0] = userA;
        c[1] = userB;
        c[2] = userC;
        uint256[] memory b = new uint256[](3);
        b[0] = 3333;
        b[1] = 3333;
        b[2] = 3334;

        vm.prank(coordinator);
        engine.processPoolDeposit(1, gross, c, b);

        // A & B: 90_000 * 3333 / 10_000 = 29_997e6
        assertEq(impactToken.getTokenData(1).netPrincipal, 29_997e6);
        assertEq(impactToken.getTokenData(2).netPrincipal, 29_997e6);
        // C gets remainder = 90_000 - 29_997 - 29_997 = 30_006e6
        assertEq(impactToken.getTokenData(3).netPrincipal, 30_006e6);
    }

    function test_ProcessPoolDeposit_MintsSequentialTokenIds() public {
        _setupStandardDeposit();
        assertEq(impactToken.ownerOf(1), userA);
        assertEq(impactToken.ownerOf(2), userB);
    }

    function test_ProcessPoolDeposit_RevertIf_Paused() public {
        vm.prank(address(mockMultiSig));
        engine.emergencyPause();

        (address[] memory c, uint256[] memory b) = _singleContributor(userA);
        vm.prank(coordinator);
        vm.expectRevert();
        engine.processPoolDeposit(1, 100_000e6, c, b);
    }

    function test_ProcessPoolDeposit_RevertIf_PoolAlreadyExists() public {
        _setupStandardDeposit();
        (address[] memory c, uint256[] memory b) = _singleContributor(userA);
        vm.prank(coordinator);
        vm.expectRevert(LAWPComplianceEngine.LAWPComplianceEngine_PoolAlreadyExists.selector);
        engine.processPoolDeposit(1, 100_000e6, c, b);
    }

    function test_ProcessPoolDeposit_RevertIf_ZeroAmount() public {
        (address[] memory c, uint256[] memory b) = _singleContributor(userA);
        vm.prank(coordinator);
        vm.expectRevert(LAWPComplianceEngine.LAWPComplianceEngine_InvalidAmount.selector);
        engine.processPoolDeposit(1, 0, c, b);
    }

    function test_ProcessPoolDeposit_RevertIf_ArrayMismatch() public {
        address[] memory c = new address[](2);
        c[0] = userA;
        c[1] = userB;
        uint256[] memory b = new uint256[](1);
        b[0] = 10_000;
        vm.prank(coordinator);
        vm.expectRevert(LAWPComplianceEngine.LAWPComplianceEngine_ArrayMismatch.selector);
        engine.processPoolDeposit(1, 100_000e6, c, b);
    }

    function test_ProcessPoolDeposit_RevertIf_EmptyArray() public {
        address[] memory c = new address[](0);
        uint256[] memory b = new uint256[](0);
        vm.prank(coordinator);
        vm.expectRevert(LAWPComplianceEngine.LAWPComplianceEngine_ArrayMismatch.selector);
        engine.processPoolDeposit(1, 100_000e6, c, b);
    }

    function test_ProcessPoolDeposit_RevertIf_TooManyContributors() public {
        address[] memory c = new address[](21);
        uint256[] memory b = new uint256[](21);
        vm.prank(coordinator);
        vm.expectRevert(LAWPComplianceEngine.LAWPComplianceEngine_ArrayTooLarge.selector);
        engine.processPoolDeposit(1, 100_000e6, c, b);
    }

    function test_ProcessPoolDeposit_RevertIf_InvalidBPS() public {
        address[] memory c = new address[](2);
        c[0] = userA;
        c[1] = userB;
        uint256[] memory b = new uint256[](2);
        b[0] = 5000; // Sums to 9999, not 10000
        b[1] = 4999;
        vm.prank(coordinator);
        vm.expectRevert(LAWPComplianceEngine.LAWPComplianceEngine_InvalidBPS.selector);
        engine.processPoolDeposit(1, 100_000e6, c, b);
    }

    /*//////////////////////////////////////////////////////////////
                    ROUTE OPERATIONAL ALLOCATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_RouteRoC_Success() public {
        _setupStandardDeposit();
        uint256 amount = 10_000e6;
        uint256 yieldBefore = cngn.balanceOf(address(yieldVault));

        _setupRoC(amount);

        assertEq(engine.poolRocTracker(1), amount);
        assertEq(cngn.balanceOf(address(yieldVault)), yieldBefore + amount);
        assertEq(cngn.balanceOf(address(mockMultiSig)), 0);
        assertEq(cngn.balanceOf(address(engine)), 0);
    }

    function test_RouteGrantInitial_Success() public {
        uint256 amount = 10_000e6;
        // 30% collective, 50% la2, 20% mvi1
        uint256 colSplit = 3_000e6;
        uint256 la2Split = 5_000e6;
        uint256 mviSplit = 2_000e6;

        uint256 yieldBefore = cngn.balanceOf(address(yieldVault));
        uint256 opBefore = cngn.balanceOf(address(operationalVault));

        _setupGrantInitial(amount);

        assertEq(engine.poolYieldTracker(1), colSplit);
        assertEq(engine.operationalBalances(la2Wallet), la2Split);
        assertEq(engine.operationalBalances(mvi1Wallet), mviSplit);
        assertEq(cngn.balanceOf(address(yieldVault)), yieldBefore + colSplit);
        assertEq(cngn.balanceOf(address(operationalVault)), opBefore + la2Split + mviSplit);
        assertEq(cngn.balanceOf(address(mockMultiSig)), 0);
        assertEq(cngn.balanceOf(address(engine)), 0);
    }

    function test_RouteGrantContinuous_Success() public {
        uint256 amount = 10_000e6;
        // 10% collective, 55% la2, 25% mvi1, 10% dev
        uint256 la2Split = 5_500e6;
        uint256 mviSplit = 2_500e6;
        uint256 colSplit = 1_000e6;
        uint256 devSplit = 10_000e6 - la2Split - mviSplit - colSplit; // 1_000e6

        _setupGrantContinuous(amount);

        assertEq(engine.poolYieldTracker(1), colSplit);
        assertEq(engine.operationalBalances(la2Wallet), la2Split);
        assertEq(engine.operationalBalances(mvi1Wallet), mviSplit);
        assertEq(engine.operationalBalances(devWallet), devSplit);
        assertEq(cngn.balanceOf(address(mockMultiSig)), 0);
    }

    function test_RouteRevenue_RevertIf_NotMultiSig() public {
        vm.prank(attacker);
        vm.expectRevert(LAWPComplianceEngine.LAWPComplianceEngine_UnauthorizedCaller.selector);
        engine.routeOperationalAllocation(1, 1000e6, attacker, LAWPStructs.FlowType.RoC);
    }

    function test_RouteRevenue_RevertIf_ZeroAmount() public {
        // Call directly as the authorized controller (mockMultiSig address)
        vm.prank(address(mockMultiSig));
        vm.expectRevert(LAWPComplianceEngine.LAWPComplianceEngine_InvalidAmount.selector);
        engine.routeOperationalAllocation(1, 0, coordinator, LAWPStructs.FlowType.RoC);
    }

    function test_RouteRevenue_RevertIf_Paused() public {
        vm.prank(address(mockMultiSig));
        engine.emergencyPause();

        vm.prank(coordinator);
        vm.expectRevert();
        mockMultiSig.execute(1, 1000e6, LAWPStructs.FlowType.RoC);
    }

    function test_RouteRevenue_RevertIf_InvalidActor() public {
        // Mock la2Wallet to return zero
        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(registry.la2Wallet.selector),
            abi.encode(address(0))
        );
        vm.prank(coordinator);
        vm.expectRevert(LAWPComplianceEngine.LAWPComplianceEngine_InvalidActor.selector);
        mockMultiSig.execute(1, 1000e6, LAWPStructs.FlowType.GRANT_INITIAL);
        vm.clearMockedCalls();
    }

    /*//////////////////////////////////////////////////////////////
                         CLAIM YIELD TESTS
    //////////////////////////////////////////////////////////////*/

    function test_ClaimYield_Success() public {
        _setupStandardDeposit();
        // Route GRANT_INITIAL: 10_000e6 -> 3_000e6 collective yield
        _setupGrantInitial(10_000e6);

        // Token 1 = userA, 60% BPS -> 3_000 * 6000 / 10_000 = 1_800e6 yield
        assertEq(engine.calculateProportionalYield(1), 1_800e6);

        uint256 balBefore = cngn.balanceOf(userA);
        vm.prank(userA);
        engine.claimYield(1);

        assertEq(cngn.balanceOf(userA), balBefore + 1_800e6);
        assertEq(engine.yieldClaimed(1), 1_800e6);
        assertEq(cngn.balanceOf(address(engine)), 0);
    }

    function test_ClaimYield_RoC_CappedAtPrincipal() public {
        _setupStandardDeposit(); // userA token 1: principal = 54_000e6
        // Route 200_000e6 RoC -> userA's 60% share = 120_000e6, capped at 54_000e6
        _setupRoC(200_000e6);

        assertEq(engine.calculateProportionalYield(1), 54_000e6);

        vm.prank(userA);
        engine.claimYield(1);

        assertEq(impactToken.getTokenData(1).rocReturned, 54_000e6);
        // Second claim must return nothing
        vm.prank(userA);
        vm.expectRevert(LAWPComplianceEngine.LAWPComplianceEngine_NothingToClaim.selector);
        engine.claimYield(1);
    }

    function test_ClaimYield_RevertIf_NothingToClaim() public {
        _setupStandardDeposit();
        vm.prank(userA);
        vm.expectRevert(LAWPComplianceEngine.LAWPComplianceEngine_NothingToClaim.selector);
        engine.claimYield(1);
    }

    function test_ClaimYield_CEI_StateBeforeTransfer() public {
        _setupStandardDeposit();
        _setupGrantInitial(10_000e6);

        uint256 claimable = engine.calculateProportionalYield(1);
        assertGt(claimable, 0);

        vm.prank(userA);
        engine.claimYield(1);

        // State must be updated (yieldClaimed set) - no double-claim possible
        assertEq(engine.calculateProportionalYield(1), 0);
        vm.prank(userA);
        vm.expectRevert(LAWPComplianceEngine.LAWPComplianceEngine_NothingToClaim.selector);
        engine.claimYield(1);
    }

    /*//////////////////////////////////////////////////////////////
                       CLAIM YIELD BATCH TESTS
    //////////////////////////////////////////////////////////////*/

    function test_ClaimYieldBatch_Success() public {
        _setupStandardDeposit();
        _setupGrantInitial(10_000e6);

        uint256[] memory tokens = new uint256[](2);
        tokens[0] = 1; // userA, 1_800e6 yield
        tokens[1] = 2; // userB, 1_200e6 yield

        uint256 balABefore = cngn.balanceOf(userA);

        // userA owns token 1 only, batch must revert for token 2
        vm.prank(userA);
        vm.expectRevert(
            abi.encodeWithSelector(
                LAWPComplianceEngine.LAWPComplianceEngine_NotTokenOwner.selector, 2
            )
        );
        engine.claimYieldBatch(tokens);

        // Correct: userA claims only token 1
        uint256[] memory ownedTokens = new uint256[](1);
        ownedTokens[0] = 1;
        vm.prank(userA);
        engine.claimYieldBatch(ownedTokens);
        assertEq(cngn.balanceOf(userA), balABefore + 1_800e6);
    }

    function test_ClaimYieldBatch_RevertIf_TooLarge() public {
        uint256[] memory tokens = new uint256[](21);
        vm.expectRevert(LAWPComplianceEngine.LAWPComplianceEngine_BatchTooLarge.selector);
        engine.claimYieldBatch(tokens);
    }

    function test_ClaimYieldBatch_RevertIf_NothingToClaim() public {
        _setupStandardDeposit();
        uint256[] memory tokens = new uint256[](1);
        tokens[0] = 1;
        vm.prank(userA);
        vm.expectRevert(LAWPComplianceEngine.LAWPComplianceEngine_NothingToClaim.selector);
        engine.claimYieldBatch(tokens);
    }

    /*//////////////////////////////////////////////////////////////
                    CLAIM OPERATIONAL FUNDS TESTS
    //////////////////////////////////////////////////////////////*/

    function test_ClaimOperationalFunds_Success() public {
        _setupGrantInitial(10_000e6); // la2 gets 5_000e6
        assertEq(engine.operationalBalances(la2Wallet), 5_000e6);

        uint256 balBefore = cngn.balanceOf(la2Wallet);
        vm.prank(la2Wallet);
        engine.claimOperationalFunds();

        assertEq(cngn.balanceOf(la2Wallet), balBefore + 5_000e6);
        assertEq(engine.operationalBalances(la2Wallet), 0);
        assertEq(cngn.balanceOf(address(engine)), 0);
    }

    function test_ClaimOperationalFunds_CEI_ZeroBeforeTransfer() public {
        _setupGrantInitial(10_000e6);
        vm.prank(la2Wallet);
        engine.claimOperationalFunds();

        // Second claim must fail - balance zeroed before transfer
        vm.prank(la2Wallet);
        vm.expectRevert(LAWPComplianceEngine.LAWPComplianceEngine_NoOperationalFunds.selector);
        engine.claimOperationalFunds();
    }

    function test_ClaimOperationalFunds_RevertIf_NothingToClaim() public {
        vm.prank(attacker);
        vm.expectRevert(LAWPComplianceEngine.LAWPComplianceEngine_NoOperationalFunds.selector);
        engine.claimOperationalFunds();
    }

    /*//////////////////////////////////////////////////////////////
                    ADVERSARIAL / REPLAY TESTS
    //////////////////////////////////////////////////////////////*/

    function test_PoolReplay_CannotDepositTwice() public {
        _setupStandardDeposit();
        (address[] memory c, uint256[] memory b) = _singleContributor(userA);
        vm.prank(coordinator);
        vm.expectRevert(LAWPComplianceEngine.LAWPComplianceEngine_PoolAlreadyExists.selector);
        engine.processPoolDeposit(1, 50_000e6, c, b);
    }

    function test_ZeroAddress_CannotBeContributor() public {
        address[] memory c = new address[](1);
        c[0] = address(0);
        uint256[] memory b = new uint256[](1);
        b[0] = 10_000;
        vm.prank(coordinator);
        // ERC721 mint to address(0) reverts
        vm.expectRevert();
        engine.processPoolDeposit(1, 100_000e6, c, b);
    }

    function test_VaultBalancesNeverDecreaseOnDeposit() public {
        uint256 yieldBefore = cngn.balanceOf(address(yieldVault));
        uint256 opBefore = cngn.balanceOf(address(operationalVault));

        _setupStandardDeposit();

        assertGe(cngn.balanceOf(address(yieldVault)), yieldBefore);
        assertGe(cngn.balanceOf(address(operationalVault)), opBefore);
    }

    /*//////////////////////////////////////////////////////////////
                          FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_ProcessPoolDeposit_AccumulatorCorrectness(uint256 grossAmount, uint256 bps1)
        public
    {
        grossAmount = bound(grossAmount, 1e6, 1_000_000e6);
        bps1 = bound(bps1, 1, 9999);
        uint256 bps2 = 10_000 - bps1;

        address[] memory c = new address[](2);
        c[0] = userA;
        c[1] = userB;
        uint256[] memory b = new uint256[](2);
        b[0] = bps1;
        b[1] = bps2;

        uint256 expectedNet = grossAmount - (grossAmount * 1000) / 10_000;

        vm.prank(coordinator);
        engine.processPoolDeposit(1, grossAmount, c, b);

        uint256 sum =
            impactToken.getTokenData(1).netPrincipal + impactToken.getTokenData(2).netPrincipal;
        assertEq(sum, expectedNet, "Dust conservation: principals must sum to netCapital");
    }

    function testFuzz_BPS_MustSumToTenThousand(uint256 bps1) public {
        bps1 = bound(bps1, 1, 9999);
        uint256 bps2 = 10_000 - bps1 - 1; // Intentionally wrong

        address[] memory c = new address[](2);
        c[0] = userA;
        c[1] = userB;
        uint256[] memory b = new uint256[](2);
        b[0] = bps1;
        b[1] = bps2;

        vm.prank(coordinator);
        vm.expectRevert(LAWPComplianceEngine.LAWPComplianceEngine_InvalidBPS.selector);
        engine.processPoolDeposit(1, 100_000e6, c, b);
    }
}
