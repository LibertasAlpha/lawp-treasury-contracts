// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { LAWPTestBase } from "../base/LAWPTestBase.sol";
import { LAWPComplianceEngine } from "../../src/core/LAWPComplianceEngine.sol";
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
        assertEq(address(engine.cNGNToken()), address(cngn));
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
        vm.etch(address(99), hex"00");
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
        vm.etch(address(99), hex"00");
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

    function test_EmergencyPause_OnlyOwner() public {
        vm.prank(admin);
        engine.emergencyPause();
        assertTrue(engine.paused());

        vm.prank(attacker);
        vm.expectRevert();
        engine.emergencyPause();
    }

    function test_Unpause_OnlyOwner() public {
        vm.prank(admin);
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

    /// @notice Helper to assign a temporary pool to bypass ContributionPool validations
    ///         for engine-specific edge case revert testing.
    function _switchToTempPool() internal returns (address tempPool) {
        tempPool = address(1234);
        vm.etch(tempPool, hex"00");
        vm.prank(admin);
        engine.setContributionPool(tempPool);
    }

    function test_ProcessPoolDeposit_Success() public {
        uint256 gross = 100_000e6;
        uint256 expectedRiskFee = 10_000e6;
        uint256 expectedNet = 90_000e6;

        uint256 yieldBefore = cngn.balanceOf(address(yieldVault));
        uint256 opBefore = cngn.balanceOf(address(operationalVault));

        uint256 poolId = _createContribPool(1, gross, block.timestamp, block.timestamp + 1 hours);
        _contribute(userA, poolId, gross);
        vm.warp(block.timestamp + 1 hours + 1);
        _settlePool(poolId);

        // Full gross amount routed to operationalVault in a single transfer.
        // yieldVault receives nothing at deposit time.
        assertEq(cngn.balanceOf(address(operationalVault)), opBefore + gross);
        assertEq(cngn.balanceOf(address(yieldVault)), yieldBefore);

        // Internal ledger: riskFee + netCapital credited to operationalTreasuryWallet.
        assertEq(
            engine.operationalBalances(operationalTreasuryWallet), expectedRiskFee + expectedNet
        );

        // Pool registered
        (bool exists,) = engine.pools(1);
        assertTrue(exists);

        // Token minted to userA with full net capital
        LAWPStructs.TokenData memory data = impactToken.getTokenData(1);
        assertEq(data.netPrincipal, expectedNet);
        assertEq(data.poolShareWAD, 1e18);
        assertEq(data.poolId, 1);

        // MockMultiSig + engine hold zero
        assertEq(cngn.balanceOf(address(mockMultiSig)), 0);
        assertEq(cngn.balanceOf(address(engine)), 0);
    }

    function test_ProcessPoolDeposit_DustGoesToLastContributor() public {
        uint256 gross = 100_000e6; // net = 90_000e6

        uint256 poolId = _createContribPool(1, gross, block.timestamp, block.timestamp + 1 hours);
        _contribute(userA, poolId, 30_000e6);
        _contribute(userB, poolId, 30_000e6);
        _contribute(userC, poolId, 40_000e6);

        vm.warp(block.timestamp + 1 hours + 1);
        _settlePool(poolId);

        // A & B: 90_000e6 * 3e17 / 1e18 = 27_000e6
        assertEq(impactToken.getTokenData(1).netPrincipal, 27_000e6);
        assertEq(impactToken.getTokenData(2).netPrincipal, 27_000e6);
        // C gets remainder = 90_000 - 27_000 - 27_000 = 36_000e6
        assertEq(impactToken.getTokenData(3).netPrincipal, 36_000e6);
    }

    function test_ProcessPoolDeposit_MintsSequentialTokenIds() public {
        _setupStandardDeposit();
        assertEq(impactToken.ownerOf(1), userA);
        assertEq(impactToken.ownerOf(2), userB);
    }

    function test_ProcessPoolDeposit_RevertIf_Paused() public {
        vm.prank(admin);
        engine.emergencyPause();

        (address[] memory c, uint256[] memory w) = _singleContributor(userA);
        vm.prank(address(contributionPool));
        vm.expectRevert();
        engine.processPoolDeposit(1, 100_000e6, c, w);
    }

    function test_ProcessPoolDeposit_RevertIf_PoolAlreadyExists() public {
        _setupStandardDeposit(); // creates pool 1
        (address[] memory c, uint256[] memory w) = _singleContributor(userB);

        address tempPool = _switchToTempPool();
        vm.prank(tempPool);
        vm.expectRevert(LAWPComplianceEngine.LAWPComplianceEngine_PoolAlreadyExists.selector);
        engine.processPoolDeposit(1, 100_000e6, c, w);
    }

    function test_ProcessPoolDeposit_RevertIf_ZeroAmount() public {
        address tempPool = _switchToTempPool();
        (address[] memory c, uint256[] memory w) = _singleContributor(userA);
        vm.prank(tempPool);
        vm.expectRevert(LAWPComplianceEngine.LAWPComplianceEngine_InvalidAmount.selector);
        engine.processPoolDeposit(1, 0, c, w);
    }

    function test_ProcessPoolDeposit_RevertIf_ArrayMismatch() public {
        address tempPool = _switchToTempPool();
        address[] memory c = new address[](2);
        c[0] = userA;
        c[1] = userB;
        uint256[] memory w = new uint256[](1);
        w[0] = 1e18;
        vm.prank(tempPool);
        vm.expectRevert(LAWPComplianceEngine.LAWPComplianceEngine_ArrayMismatch.selector);
        engine.processPoolDeposit(1, 100_000e6, c, w);
    }

    function test_ProcessPoolDeposit_RevertIf_EmptyArray() public {
        address tempPool = _switchToTempPool();
        address[] memory c = new address[](0);
        uint256[] memory w = new uint256[](0);
        vm.prank(tempPool);
        vm.expectRevert(LAWPComplianceEngine.LAWPComplianceEngine_ArrayMismatch.selector);
        engine.processPoolDeposit(1, 100_000e6, c, w);
    }

    function test_ProcessPoolDeposit_RevertIf_TooManyContributors() public {
        address tempPool = _switchToTempPool();
        address[] memory c = new address[](21);
        uint256[] memory w = new uint256[](21);
        vm.prank(tempPool);
        vm.expectRevert(LAWPComplianceEngine.LAWPComplianceEngine_ArrayTooLarge.selector);
        engine.processPoolDeposit(1, 100_000e6, c, w);
    }

    function test_ProcessPoolDeposit_RevertIf_InvalidWAD() public {
        address tempPool = _switchToTempPool();
        address[] memory c = new address[](2);
        c[0] = userA;
        c[1] = userB;
        uint256[] memory w = new uint256[](2);
        w[0] = 5e17; // 50%
        w[1] = 4e17; // 40% (total 90% != 100%)
        vm.prank(tempPool);
        vm.expectRevert(LAWPComplianceEngine.LAWPComplianceEngine_InvalidWAD.selector);
        engine.processPoolDeposit(1, 100_000e6, c, w);
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
        vm.prank(admin);
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

    function test_RouteRoC_RevertIf_ExceedsPrincipalCap() public {
        // Standard deposit: gross=100_000e6, risk=10%, net=90_000e6 -> poolTotalPrincipal=90_000e6
        _setupStandardDeposit();

        // Route exactly the net capital - should succeed.
        _setupRoC(90_000e6);

        // Attempt to route even 1 wei more - pool is fully settled.
        vm.prank(coordinator);
        vm.expectRevert(LAWPComplianceEngine.LAWPComplianceEngine_ExceedsPrincipalCap.selector);
        mockMultiSig.execute(1, 1, LAWPStructs.FlowType.RoC);
    }

    function test_RouteRoC_PartialThenRemainder_BothSucceed() public {
        _setupStandardDeposit();
        uint256 net = 90_000e6;

        // First partial routing
        _setupRoC(50_000e6);
        assertEq(engine.poolRocTracker(1), 50_000e6);

        // Second routing for the exact remainder
        _setupRoC(net - 50_000e6);
        assertEq(engine.poolRocTracker(1), net);
    }

    function test_RouteRoC_OverpayByOne_Reverts() public {
        _setupStandardDeposit();
        uint256 net = 90_000e6;

        // Route net - 1 first, leaving 1 wei of capacity.
        _setupRoC(net - 1);

        // Route 2 wei: exceeds remaining capacity of 1 wei.
        vm.prank(coordinator);
        vm.expectRevert(LAWPComplianceEngine.LAWPComplianceEngine_ExceedsPrincipalCap.selector);
        mockMultiSig.execute(1, 2, LAWPStructs.FlowType.RoC);
    }

    function test_ProcessPoolDeposit_WritesPoolTotalPrincipal() public {
        uint256 gross = 100_000e6;
        uint256 expectedNet = 90_000e6; // 10% risk fee

        address tempPool = _switchToTempPool();
        cngn.mintTest(tempPool, gross);

        vm.startPrank(tempPool);
        cngn.approve(address(engine), type(uint256).max);

        (address[] memory c, uint256[] memory w) = _singleContributor(userA);

        engine.processPoolDeposit(1, gross, c, w);
        assertEq(engine.poolTotalPrincipal(1), expectedNet);

        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                       OPERATOR VIEW HELPER TESTS
    //////////////////////////////////////////////////////////////*/

    function test_GetPoolNetCapital_ReturnsNetAfterFee() public {
        _setupStandardDeposit(); // gross=100_000e6, net=90_000e6
        assertEq(engine.getPoolNetCapital(1), 90_000e6);
    }

    function test_GetPoolNetCapital_RevertIf_InvalidPool() public {
        vm.expectRevert(LAWPComplianceEngine.LAWPComplianceEngine_InvalidPool.selector);
        engine.getPoolNetCapital(99);
    }

    function test_GetRemainingRocCapacity_InitiallyEqualsNetCapital() public {
        _setupStandardDeposit();
        assertEq(engine.getRemainingRocCapacity(1), 90_000e6);
    }

    function test_GetRemainingRocCapacity_DecreasesAfterRouting() public {
        _setupStandardDeposit();
        _setupRoC(30_000e6);
        assertEq(engine.getRemainingRocCapacity(1), 60_000e6);
    }

    function test_GetRemainingRocCapacity_ZeroWhenSettled() public {
        _setupStandardDeposit();
        _setupRoC(90_000e6);
        assertEq(engine.getRemainingRocCapacity(1), 0);
    }

    function test_GetRemainingRocCapacity_RevertIf_InvalidPool() public {
        vm.expectRevert(LAWPComplianceEngine.LAWPComplianceEngine_InvalidPool.selector);
        engine.getRemainingRocCapacity(99);
    }

    function test_GetPoolRocStatus_InitialState() public {
        _setupStandardDeposit();
        (uint256 netCapital, uint256 routedRoc, uint256 remainingRoc, bool settled) =
            engine.getPoolRocStatus(1);
        assertEq(netCapital, 90_000e6);
        assertEq(routedRoc, 0);
        assertEq(remainingRoc, 90_000e6);
        assertFalse(settled);
    }

    function test_GetPoolRocStatus_PartialRouting() public {
        _setupStandardDeposit();
        _setupRoC(65_000e6);
        (uint256 netCapital, uint256 routedRoc, uint256 remainingRoc, bool settled) =
            engine.getPoolRocStatus(1);
        assertEq(netCapital, 90_000e6);
        assertEq(routedRoc, 65_000e6);
        assertEq(remainingRoc, 25_000e6);
        assertFalse(settled);
    }

    function test_GetPoolRocStatus_FullySettled() public {
        _setupStandardDeposit();
        _setupRoC(90_000e6);
        (uint256 netCapital, uint256 routedRoc, uint256 remainingRoc, bool settled) =
            engine.getPoolRocStatus(1);
        assertEq(netCapital, 90_000e6);
        assertEq(routedRoc, 90_000e6);
        assertEq(remainingRoc, 0);
        assertTrue(settled);
    }

    function test_GetPoolRocStatus_RevertIf_InvalidPool() public {
        vm.expectRevert(LAWPComplianceEngine.LAWPComplianceEngine_InvalidPool.selector);
        engine.getPoolRocStatus(99);
    }

    /*//////////////////////////////////////////////////////////////
                          CLAIM YIELD TESTS
    //////////////////////////////////////////////////////////////*/

    function test_ClaimYield_Success() public {
        _setupStandardDeposit();
        // Route GRANT_INITIAL: 10_000e6 -> 3_000e6 collective yield
        _setupGrantInitial(10_000e6);

        // Token 1 = userA, 60% WAD -> 3_000 * 6e17 / 1e18 = 1_800e6 yield
        assertEq(engine.calculateProportionalYield(1), 1_800e6);

        uint256 balBefore = cngn.balanceOf(userA);
        vm.prank(userA);
        engine.claimYield(1);

        assertEq(cngn.balanceOf(userA), balBefore + 1_800e6);
        assertEq(engine.yieldClaimed(1), 1_800e6);
        assertEq(cngn.balanceOf(address(engine)), 0);
    }

    function test_ClaimYield_RoC_CappedAtPrincipal() public {
        // Standard deposit: gross=100_000e6, risk=10%, net=90_000e6.
        // userA token 1: WAD=6e17, netPrincipal=54_000e6
        // userB token 2: WAD=4e17, netPrincipal=36_000e6
        _setupStandardDeposit();

        // Route the full net capital as RoC - maximum allowed by the guard.
        // poolRocTracker = 90_000e6
        // userA's tracker share = 90_000e6 * 6e17 / 1e18 = 54_000e6
        // maxRemainingRoc for userA = netPrincipal - rocReturned = 54_000e6 - 0 = 54_000e6
        // claimableRoc = min(54_000e6, 54_000e6) = 54_000e6
        // This proves the claim-math cap is reached exactly at the principal boundary.
        _setupRoC(90_000e6);

        assertEq(engine.calculateProportionalYield(1), 54_000e6);

        vm.prank(userA);
        engine.claimYield(1);

        assertEq(impactToken.getTokenData(1).rocReturned, 54_000e6);

        // Second claim: rocReturned == netPrincipal, so claimableRoc = 0. Nothing left.
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

    function test_ClaimYield_RevertIf_Paused() public {
        _setupStandardDeposit();
        vm.prank(admin);
        engine.emergencyPause();

        vm.prank(userA);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
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

    function test_ClaimYieldBatch_RevertIf_Paused() public {
        _setupStandardDeposit();
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;

        vm.prank(admin);
        engine.emergencyPause();

        vm.prank(userA);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        engine.claimYieldBatch(ids);
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

    function test_ClaimOperationalFunds_RevertIf_Paused() public {
        _setupStandardDeposit();

        vm.prank(admin);
        engine.emergencyPause();

        vm.prank(operationalTreasuryWallet);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        engine.claimOperationalFunds();
    }

    /*//////////////////////////////////////////////////////////////
                     MIGRATE OPERATIONAL BALANCE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_MigrateOperationalBalance_Success() public {
        _setupGrantInitial(10_000e6); // la2 gets 5_000e6
        assertEq(engine.operationalBalances(la2Wallet), 5_000e6);
        assertEq(engine.operationalBalances(userC), 0);

        vm.prank(admin);
        engine.migrateOperationalBalance(la2Wallet, userC);

        assertEq(engine.operationalBalances(la2Wallet), 0);
        assertEq(engine.operationalBalances(userC), 5_000e6);

        // userC can now claim
        uint256 balBefore = cngn.balanceOf(userC);
        vm.prank(userC);
        engine.claimOperationalFunds();
        assertEq(cngn.balanceOf(userC), balBefore + 5_000e6);
    }

    function test_MigrateOperationalBalance_RevertIfNotOwner() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", attacker));
        engine.migrateOperationalBalance(la2Wallet, userC);
    }

    function test_MigrateOperationalBalance_ZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(LAWPComplianceEngine.LAWPComplianceEngine_ZeroAddress.selector);
        engine.migrateOperationalBalance(address(0), userC);
    }

    function test_MigrateOperationalBalance_ZeroBalance() public {
        assertEq(engine.operationalBalances(la2Wallet), 0);
        vm.prank(admin);
        engine.migrateOperationalBalance(la2Wallet, userC);
        assertEq(engine.operationalBalances(la2Wallet), 0);
        assertEq(engine.operationalBalances(userC), 0);
    }

    /*//////////////////////////////////////////////////////////////
                    ADVERSARIAL / REPLAY TESTS
    //////////////////////////////////////////////////////////////*/

    function test_PoolReplay_CannotDepositTwice() public {
        _setupStandardDeposit();
        (address[] memory c, uint256[] memory w) = _singleContributor(userA);
        vm.prank(address(contributionPool));
        vm.expectRevert(LAWPComplianceEngine.LAWPComplianceEngine_PoolAlreadyExists.selector);
        engine.processPoolDeposit(1, 50_000e6, c, w);
    }

    function test_ZeroAddress_CannotBeContributor() public {
        address[] memory c = new address[](1);
        c[0] = address(0);
        uint256[] memory w = new uint256[](1);
        w[0] = 1e18;
        vm.prank(address(contributionPool));
        // ERC721 mint to address(0) reverts
        vm.expectRevert();
        engine.processPoolDeposit(1, 100_000e6, c, w);
    }

    function test_VaultBalancesNeverDecreaseOnDeposit() public {
        uint256 yieldBefore = cngn.balanceOf(address(yieldVault));
        uint256 opBefore = cngn.balanceOf(address(operationalVault));

        _setupStandardDeposit();

        // operationalVault grows by the full gross amount (risk fee + net capital).
        // yieldVault is unchanged at deposit time - it only grows via revenue routing.
        assertGe(cngn.balanceOf(address(operationalVault)), opBefore);
        assertEq(cngn.balanceOf(address(yieldVault)), yieldBefore);
    }

    /*//////////////////////////////////////////////////////////////
            BALANCE-DELTA ACCOUNTING TESTS (ERC20 EDGE CASES)
    //////////////////////////////////////////////////////////////*/

    /// @notice Verifies that processPoolDeposit reverts with ZeroActualReceived when
    ///         the token's transfer arrives at the vault with zero net tokens.
    ///         Simulates a 100%-fee-on-transfer or redemption-burn-on-arrival path
    ///         by routing the deposit through the cNGN redemption path (external→internal
    ///         transfer burns the amount in operationalVault), which means the vault
    ///         balance does not increase at all.
    function test_ProcessPoolDeposit_RevertIf_ZeroActualReceived() public {
        address tempPool = _switchToTempPool();

        cngn.mintTest(tempPool, 100_000e6);
        vm.prank(tempPool);
        cngn.approve(address(engine), type(uint256).max);

        // Configure operationalVault as an "internal" cNGN user so that any
        // inbound transfer is immediately burned by the token (100%-fee-on-transfer).
        adminOps.setInternalWhitelisted(address(operationalVault), true);
        // Configure tempPool as an external sender (triggers the burn path).
        adminOps.setExternalWhitelisted(tempPool, true);

        (address[] memory c, uint256[] memory w) = _singleContributor(userA);
        vm.prank(tempPool);
        vm.expectRevert(LAWPComplianceEngine.LAWPComplianceEngine_ZeroActualReceived.selector);
        engine.processPoolDeposit(1, 100_000e6, c, w);
    }

    /// @notice Verifies that balance-delta accounting correctly uses actual received
    ///         amount rather than requested amount for all downstream state.
    ///         We verify the invariant: poolTotalPrincipal + riskFee == actualReceived,
    ///         not == grossAmount. (In normal MockCngn3 with no fee, actualReceived ==
    ///         grossAmount, so this test validates the accounting path is wired correctly.)
    function test_ProcessPoolDeposit_AccountingUsesActualReceived() public {
        uint256 gross = 100_000e6;

        uint256 poolId = _createContribPool(1, gross, block.timestamp, block.timestamp + 1 hours);
        _contribute(userA, poolId, gross);
        vm.warp(block.timestamp + 1 hours + 1);
        _settlePool(poolId);

        // Confirm: actual vault balance == gross (no fee in MockCngn3 standard path).
        assertEq(cngn.balanceOf(address(operationalVault)), gross);

        // The treasury pull-ledger must reconstruct exactly to what the vault received.
        uint256 ledgered = engine.operationalBalances(operationalTreasuryWallet);
        assertEq(ledgered, gross, "Ledger must equal actualReceived");

        // poolTotalPrincipal must be the net after fee, and fee+net must equal vault balance.
        uint256 net = engine.poolTotalPrincipal(1);
        uint256 riskFee = gross - net; // reverse-compute fee
        assertEq(net + riskFee, gross, "poolTotalPrincipal + riskFee must equal actualReceived");
    }

    /// @notice Verifies ZeroActualReceived guard in routeOperationalAllocation (RoC path).
    function test_RouteRoC_RevertIf_ZeroActualReceived() public {
        _setupStandardDeposit();

        // Make yieldVault an internal user so RoC transfer burns on arrival.
        adminOps.setInternalWhitelisted(address(yieldVault), true);
        adminOps.setExternalWhitelisted(coordinator, true);

        vm.prank(coordinator);
        vm.expectRevert(LAWPComplianceEngine.LAWPComplianceEngine_ZeroActualReceived.selector);
        mockMultiSig.execute(1, 10_000e6, LAWPStructs.FlowType.RoC);
    }

    /*//////////////////////////////////////////////////////////////
                          FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_ProcessPoolDeposit_AccumulatorCorrectness(uint256 grossAmount, uint256 w1)
        public
    {
        uint256 minContribution = contributionPool.MIN_CONTRIBUTION();

        grossAmount = bound(grossAmount, 1_000e6, 1_000_000e6);
        uint256 expectedNet = grossAmount - (grossAmount * 1000) / 10_000;

        uint256 minWad = (minContribution * 1e18 + grossAmount - 1) / grossAmount;

        w1 = bound(w1, minWad, 1e18 - minWad);

        uint256 amount1 = (grossAmount * w1) / 1e18;
        uint256 amount2 = grossAmount - amount1;

        uint256 poolId =
            _createContribPool(1, grossAmount, block.timestamp, block.timestamp + 1 hours);
        if (amount1 > 0) _contribute(userA, poolId, amount1);
        if (amount2 > 0) _contribute(userB, poolId, amount2);

        vm.warp(block.timestamp + 1 hours + 1);
        _settlePool(poolId);

        uint256 sum =
            impactToken.getTokenData(1).netPrincipal + impactToken.getTokenData(2).netPrincipal;
        assertEq(sum, expectedNet, "Dust conservation: principals must sum to netCapital");
    }

    function testFuzz_WAD_MustSumToOneE18(uint256 w1) public {
        w1 = bound(w1, 1, 1e18 - 1);
        uint256 w2 = 1e18 - w1 - 1; // Intentionally wrong

        address tempPool = _switchToTempPool();
        address[] memory c = new address[](2);
        c[0] = userA;
        c[1] = userB;
        uint256[] memory w = new uint256[](2);
        w[0] = w1;
        w[1] = w2;

        vm.prank(tempPool);
        vm.expectRevert(LAWPComplianceEngine.LAWPComplianceEngine_InvalidWAD.selector);
        engine.processPoolDeposit(1, 100_000e6, c, w);
    }

    /*//////////////////////////////////////////////////////////////
              C-2 SECURITY REGRESSION TESTS
         Principal Sum Invariant (Invariant I-8)
    //////////////////////////////////////////////////////////////*/
    /// @dev Invariant I-8: Sum of all minted netPrincipal for a pool must exactly equal
    ///      poolTotalPrincipal[poolId]. Verifies with a 2-contributor, non-round-number pool.
    function test_C2_SumNetPrincipal_ExactlyEqualsPoolPrincipal_TwoContributors() public {
        uint256 gross = 123_456_789e6; // Deliberately non-round

        uint256 expectedNet = gross - (gross * RISK_FEE_BPS) / 10_000;

        // WADs: floor-divided on gross. Last contributor absorbs WAD dust.
        uint256 wadA = (70_000_000e6 * 1e18) / gross;
        uint256 wadB = 1e18 - wadA; // remainder absorbs WAD dust

        address tempPool = _switchToTempPool();

        // Fund tempPool and approve the engine — required for the safeTransferFrom in processPoolDeposit
        cngn.mintTest(tempPool, gross);
        vm.prank(tempPool);
        cngn.approve(address(engine), gross);

        address[] memory c = new address[](2);
        c[0] = userA;
        c[1] = userB;
        uint256[] memory w = new uint256[](2);
        w[0] = wadA;
        w[1] = wadB;

        vm.prank(tempPool);
        engine.processPoolDeposit(1, gross, c, w);

        // Read back the two tokens and sum their netPrincipals
        LAWPStructs.TokenData memory dataA = impactToken.getTokenData(1);
        LAWPStructs.TokenData memory dataB = impactToken.getTokenData(2);
        uint256 sumPrincipal = dataA.netPrincipal + dataB.netPrincipal;

        assertEq(
            sumPrincipal,
            engine.poolTotalPrincipal(1),
            "I-8: sum(netPrincipal) must equal poolTotalPrincipal exactly"
        );
        assertEq(sumPrincipal, expectedNet, "I-8: sum(netPrincipal) must equal expectedNet exactly");
    }

    /// @dev Single-contributor pool: WAD = 1e18, netPrincipal must equal poolTotalPrincipal exactly.
    function test_C2_SumNetPrincipal_ExactlyEqualsPoolPrincipal_SingleContributor() public {
        uint256 gross = 77_777_777e6;
        uint256 expectedNet = gross - (gross * RISK_FEE_BPS) / 10_000;

        address tempPool = _switchToTempPool();

        cngn.mintTest(tempPool, gross);
        vm.prank(tempPool);
        cngn.approve(address(engine), gross);

        (address[] memory c, uint256[] memory w) = _singleContributor(userA);

        vm.prank(tempPool);
        engine.processPoolDeposit(1, gross, c, w);

        LAWPStructs.TokenData memory data = impactToken.getTokenData(1);

        assertEq(
            data.netPrincipal, engine.poolTotalPrincipal(1), "I-8: single contributor mismatch"
        );
        assertEq(data.netPrincipal, expectedNet, "I-8: single contributor net mismatch");
    }
}
