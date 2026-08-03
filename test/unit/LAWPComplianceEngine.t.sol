// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {LAWPFixture} from "../base/LAWPFixture.t.sol";
import {LAWPStructs} from "../../src/libraries/LAWPStructs.sol";
import {LAWPComplianceEngine} from "../../src/core/LAWPComplianceEngine.sol";
import {LAWPOperationalVault} from "../../src/core/LAWPOperationalVault.sol";
import {LAWPYieldVault} from "../../src/core/LAWPYieldVault.sol";
import {LAWPImpactToken} from "../../src/core/LAWPImpactToken.sol";
import {MockCNGN} from "../mocks/MockCNGN.sol";
import {MockFOTToken} from "../mocks/MockFOTToken.sol";
import {MockZeroOpToken} from "../mocks/MockZeroOpToken.sol";

contract LAWPComplianceEngineTest is LAWPFixture {
    uint256 constant POOL_ID = 1;
    uint256 constant WAD = 1e18;

    function setUp() public override {
        super.setUp();
    }

    // ==========================================
    // VIEW FUNCTIONS AND EDGE CASES
    // ==========================================

    function test_ViewFunctions() public {
        test_ProcessPoolDeposit();

        assertTrue(engine.isPoolActive(POOL_ID));
        assertEq(engine.getPoolNetCapital(POOL_ID), 995e6);

        // Initial RoC status
        (uint256 netCap, uint256 routedRoc, uint256 remainingRoc, bool settled) = engine.getPoolRocStatus(POOL_ID);
        assertEq(netCap, 995e6);
        assertEq(routedRoc, 0);
        assertEq(remainingRoc, 995e6);
        assertFalse(settled);
        assertEq(engine.getRemainingRocCapacity(POOL_ID), 995e6);

        // Calculate proportional yield before any routing
        assertEq(engine.calculateProportionalYield(1), 0);

        // Route RoC
        uint256 rocAmount = 400e6;
        token.mint(operator, rocAmount);
        vm.startPrank(operator);
        token.approve(address(engine), rocAmount);
        engine.routeOperationalAllocation(POOL_ID, rocAmount, operator, LAWPStructs.FlowType.RoC);
        vm.stopPrank();

        // Check RoC capacity after
        assertEq(engine.getRemainingRocCapacity(POOL_ID), 595e6);
        (netCap, routedRoc, remainingRoc, settled) = engine.getPoolRocStatus(POOL_ID);
        assertEq(routedRoc, 400e6);
        assertEq(remainingRoc, 595e6);

        // Route Yield (System 1)
        uint256 grantAmount = 1000e6;
        token.mint(operator, grantAmount);
        vm.startPrank(operator);
        token.approve(address(engine), grantAmount);
        engine.routeOperationalAllocation(POOL_ID, grantAmount, operator, LAWPStructs.FlowType.GRANT_INITIAL);
        vm.stopPrank();

        // 300e6 to Yield Vault
        // Token 1 has 40% -> 120e6 yield
        // RoC -> Token 1 gets 40% of 400e6 -> 160e6 RoC
        // Total claimable = 120e6 + 160e6 = 280e6
        assertEq(engine.calculateProportionalYield(1), 280e6);
        assertEq(engine.calculateProportionalYield(2), 420e6); // 180e6 + 240e6
    }

    function test_ViewFunctions_RevertIfInvalidPool() public {
        vm.expectRevert(LAWPComplianceEngine.LAWPComplianceEngine_InvalidPool.selector);
        engine.getPoolNetCapital(999);

        vm.expectRevert(LAWPComplianceEngine.LAWPComplianceEngine_InvalidPool.selector);
        engine.getRemainingRocCapacity(999);

        vm.expectRevert(LAWPComplianceEngine.LAWPComplianceEngine_InvalidPool.selector);
        engine.getPoolRocStatus(999);
    }

    function test_RevertIf_ProcessPoolDepositMissingActor() public {
        LAWPComplianceEngine emptyEngine = new LAWPComplianceEngine(
            governance, address(yieldVault), address(opVault), address(impactToken), address(token), 50
        );
        vm.startPrank(governance);
        emptyEngine.grantRole(emptyEngine.CAMPAIGN_MANAGER_ROLE(), operator);
        vm.stopPrank();

        address[] memory contributors = new address[](1);
        contributors[0] = alice;
        uint256[] memory wadShares = new uint256[](1);
        wadShares[0] = 1e18;

        token.mint(operator, 1000e6);
        vm.startPrank(operator);
        token.approve(address(emptyEngine), 1000e6);

        vm.expectRevert(LAWPComplianceEngine.LAWPComplianceEngine_InvalidActor.selector);
        emptyEngine.processPoolDeposit(POOL_ID, 1000e6, contributors, wadShares);
        vm.stopPrank();
    }

    function test_RevertIf_RouteGrantInitialMissingActor() public {
        LAWPComplianceEngine emptyEngine = new LAWPComplianceEngine(
            governance, address(yieldVault), address(opVault), address(impactToken), address(token), 50
        );
        vm.startPrank(governance);
        emptyEngine.grantRole(emptyEngine.OPERATOR_ROLE(), operator);
        vm.stopPrank();

        token.mint(operator, 1000e6);
        vm.startPrank(operator);
        token.approve(address(emptyEngine), 1000e6);

        vm.expectRevert(LAWPComplianceEngine.LAWPComplianceEngine_InvalidActor.selector);
        emptyEngine.routeOperationalAllocation(POOL_ID, 1000e6, operator, LAWPStructs.FlowType.GRANT_INITIAL);
        vm.stopPrank();
    }

    function test_RevertIf_RouteGrantContinuousMissingActor() public {
        LAWPComplianceEngine emptyEngine = new LAWPComplianceEngine(
            governance, address(yieldVault), address(opVault), address(impactToken), address(token), 50
        );
        vm.startPrank(governance);
        emptyEngine.grantRole(emptyEngine.OPERATOR_ROLE(), operator);
        vm.stopPrank();

        token.mint(operator, 1000e6);
        vm.startPrank(operator);
        token.approve(address(emptyEngine), 1000e6);

        vm.expectRevert(LAWPComplianceEngine.LAWPComplianceEngine_InvalidActor.selector);
        emptyEngine.routeOperationalAllocation(POOL_ID, 1000e6, operator, LAWPStructs.FlowType.GRANT_CONTINUOUS);
        vm.stopPrank();
    }

    function test_RoCClaimClamping() public {
        // Net capital 995e6. Token 1 (40%) = 398e6. Token 2 (60%) = 597e6.
        test_ProcessPoolDeposit();

        // Route RoC exactly equal to total principal
        uint256 rocAmount = 995e6;
        token.mint(operator, rocAmount);
        vm.startPrank(operator);
        token.approve(address(engine), rocAmount);
        engine.routeOperationalAllocation(POOL_ID, rocAmount, operator, LAWPStructs.FlowType.RoC);
        vm.stopPrank();

        // Route an excessive amount of yield that simulates another RoC routing?
        // Actually, let's claim RoC first. Token 1 claims 398e6.
        vm.prank(alice);
        engine.claimYield(1);

        LAWPStructs.TokenData memory d1 = impactToken.getTokenData(1);
        assertEq(d1.rocReturned, 398e6); // Max reached

        // Let's force an artificial increase in poolRocTracker using a cheatcode to test the clamping logic
        uint256 currentTracker = engine.poolRocTracker(POOL_ID);
        bytes32 targetSlot;
        for (uint256 i = 0; i < 20; i++) {
            bytes32 slot = keccak256(abi.encode(POOL_ID, i));
            if (uint256(vm.load(address(engine), slot)) == currentTracker) {
                // Test if this is the correct slot
                vm.store(address(engine), slot, bytes32(currentTracker + 1000e6));
                if (engine.poolRocTracker(POOL_ID) == currentTracker + 1000e6) {
                    targetSlot = slot;
                    break;
                }
                // Revert change if it wasn't the right one
                vm.store(address(engine), slot, bytes32(currentTracker));
            }
        }

        // Now totalRocForToken will be huge, but it should be clamped to maxRemainingRoc (which is 0 now)
        assertEq(engine.calculateProportionalYield(1), 0);

        // Claiming again should yield nothing
        vm.startPrank(alice);
        vm.expectRevert(LAWPComplianceEngine.LAWPComplianceEngine_NothingToClaim.selector);
        engine.claimYield(1);
        vm.stopPrank();
    }

    // ==========================================
    // ROLES & CONFIGURATION
    // ==========================================

    function test_AdminCanUpdateWallets() public {
        vm.startPrank(governance);
        engine.setLA2Wallet(address(0x11));
        assertEq(engine.la2Wallet(), address(0x11));

        engine.setMVI1Wallet(address(0x12));
        assertEq(engine.mvi1Wallet(), address(0x12));

        engine.setOperationalTreasuryWallet(address(0x13));
        assertEq(engine.operationalTreasuryWallet(), address(0x13));

        engine.setDevWallet(address(0x14));
        assertEq(engine.devWallet(), address(0x14));
        vm.stopPrank();
    }

    function test_RevertIf_SetWalletsZeroAddress() public {
        vm.startPrank(governance);
        vm.expectRevert(LAWPComplianceEngine.LAWPComplianceEngine_ZeroAddress.selector);
        engine.setLA2Wallet(address(0));

        vm.expectRevert(LAWPComplianceEngine.LAWPComplianceEngine_ZeroAddress.selector);
        engine.setMVI1Wallet(address(0));

        vm.expectRevert(LAWPComplianceEngine.LAWPComplianceEngine_ZeroAddress.selector);
        engine.setDevWallet(address(0));

        vm.expectRevert(LAWPComplianceEngine.LAWPComplianceEngine_ZeroAddress.selector);
        engine.setOperationalTreasuryWallet(address(0));
        vm.stopPrank();
    }

    function test_RevertIf_NonAdminUpdatesWallets() public {
        vm.startPrank(alice);
        vm.expectRevert(
            abi.encodeWithSignature(
                "AccessControlUnauthorizedAccount(address,bytes32)", alice, engine.GOVERNANCE_ROLE()
            )
        );
        engine.setLA2Wallet(address(0x11));
        vm.stopPrank();
    }

    function test_AdminCanUpdateRiskFee() public {
        vm.prank(governance);
        engine.updateRiskFee(500); // 5%
        assertEq(engine.riskFeeBPS(), 500);
    }

    function test_RevertIf_UpdateRiskFeeAboveMax() public {
        vm.prank(governance);
        vm.expectRevert(LAWPComplianceEngine.LAWPComplianceEngine_InvalidRiskFee.selector);
        engine.updateRiskFee(1001); // 10.01%
    }

    function test_RevertIf_UpdateRiskFeeZero() public {
        vm.prank(governance);
        vm.expectRevert(LAWPComplianceEngine.LAWPComplianceEngine_InvalidRiskFee.selector);
        engine.updateRiskFee(0);
    }

    function test_EmergencyPauseAndUnpause() public {
        vm.startPrank(governance);
        engine.emergencyPause();
        assertTrue(engine.paused());

        engine.unpause();
        assertFalse(engine.paused());
        vm.stopPrank();
    }

    function test_RevertIf_NonAdminPauses() public {
        vm.startPrank(alice);
        vm.expectRevert(
            abi.encodeWithSignature(
                "AccessControlUnauthorizedAccount(address,bytes32)", alice, engine.GOVERNANCE_ROLE()
            )
        );
        engine.emergencyPause();
        vm.stopPrank();
    }

    function test_RevertIf_ConstructorZeroAddress() public {
        vm.expectRevert(LAWPComplianceEngine.LAWPComplianceEngine_ZeroAddress.selector);
        new LAWPComplianceEngine(address(0), address(0), address(0), address(0), address(0), 50);

        vm.expectRevert(LAWPComplianceEngine.LAWPComplianceEngine_ZeroAddress.selector);
        new LAWPComplianceEngine(address(1), address(0), address(1), address(1), address(1), 50);
    }

    function test_RevertIf_ConstructorInvalidRiskFee() public {
        vm.expectRevert(LAWPComplianceEngine.LAWPComplianceEngine_InvalidRiskFee.selector);
        new LAWPComplianceEngine(address(1), address(1), address(1), address(1), address(1), 0);

        vm.expectRevert(LAWPComplianceEngine.LAWPComplianceEngine_InvalidRiskFee.selector);
        new LAWPComplianceEngine(address(1), address(1), address(1), address(1), address(1), 1001);
    }

    // ==========================================
    // POOL DEPOSIT PROCESSING
    // ==========================================

    function test_ProcessPoolDeposit() public {
        uint256 grossAmount = 1000e6;

        address[] memory contributors = new address[](2);
        contributors[0] = alice;
        contributors[1] = bob;

        uint256[] memory wadShares = new uint256[](2);
        wadShares[0] = 4e17; // 40%
        wadShares[1] = 6e17; // 60%

        token.mint(campaignManager, grossAmount); // campaignManager is msg.sender for processPoolDeposit

        vm.startPrank(campaignManager);
        token.approve(address(engine), grossAmount);
        engine.processPoolDeposit(POOL_ID, grossAmount, contributors, wadShares);
        vm.stopPrank();

        assertTrue(engine.isPoolActive(POOL_ID));

        // Assert Risk Fee (50 BPS = 0.5%)
        uint256 expectedNet = 995e6;

        assertEq(engine.getPoolNetCapital(POOL_ID), expectedNet);
        assertEq(token.balanceOf(address(opVault)), grossAmount); // Both fee and net enter OpVault

        // Check impact tokens minted
        LAWPStructs.TokenData memory d1 = impactToken.getTokenData(1);
        assertEq(impactToken.ownerOf(1), alice);
        assertEq(d1.poolShareWAD, 4e17);
        assertEq(d1.netPrincipal, (expectedNet * 4e17) / WAD);

        LAWPStructs.TokenData memory d2 = impactToken.getTokenData(2);
        assertEq(impactToken.ownerOf(2), bob);
        assertEq(d2.poolShareWAD, 6e17);
        assertEq(d2.netPrincipal, (expectedNet * 6e17) / WAD);
    }

    function test_RevertIf_ProcessPoolDepositInvalidWAD() public {
        address[] memory contributors = new address[](2);
        contributors[0] = alice;
        contributors[1] = bob;

        uint256[] memory wadShares = new uint256[](2);
        wadShares[0] = 4e17; // 40%
        wadShares[1] = 5e17; // 50%, total 90%, not 100%

        token.mint(campaignManager, 1000e6);
        vm.prank(campaignManager);
        token.approve(address(engine), 1000e6);

        vm.prank(campaignManager);
        vm.expectRevert(LAWPComplianceEngine.LAWPComplianceEngine_InvalidWAD.selector);
        engine.processPoolDeposit(POOL_ID, 1000e6, contributors, wadShares);
    }

    function test_RevertIf_ProcessPoolDepositPoolExists() public {
        test_ProcessPoolDeposit();

        address[] memory contributors = new address[](1);
        contributors[0] = alice;
        uint256[] memory wadShares = new uint256[](1);
        wadShares[0] = WAD;

        vm.prank(campaignManager);
        vm.expectRevert(LAWPComplianceEngine.LAWPComplianceEngine_PoolAlreadyExists.selector);
        engine.processPoolDeposit(POOL_ID, 1000e6, contributors, wadShares);
    }

    function test_RevertIf_ProcessPoolDepositZeroAmount() public {
        address[] memory c = new address[](1);
        c[0] = alice;
        uint256[] memory w = new uint256[](1);
        w[0] = WAD;

        vm.prank(campaignManager);
        vm.expectRevert(LAWPComplianceEngine.LAWPComplianceEngine_InvalidAmount.selector);
        engine.processPoolDeposit(POOL_ID, 0, c, w);
    }

    function test_RevertIf_ProcessPoolDepositTooManyContributors() public {
        address[] memory c = new address[](51);
        uint256[] memory w = new uint256[](51);

        vm.prank(campaignManager);
        vm.expectRevert(LAWPComplianceEngine.LAWPComplianceEngine_ArrayTooLarge.selector);
        engine.processPoolDeposit(POOL_ID, 1000e6, c, w);
    }

    function test_RevertIf_ProcessPoolDepositArrayMismatch() public {
        address[] memory c = new address[](1);
        uint256[] memory w = new uint256[](0);

        vm.prank(campaignManager);
        vm.expectRevert(LAWPComplianceEngine.LAWPComplianceEngine_ArrayMismatch.selector);
        engine.processPoolDeposit(POOL_ID, 1000e6, c, w);

        address[] memory c0 = new address[](0);
        uint256[] memory w0 = new uint256[](0);

        vm.prank(campaignManager);
        vm.expectRevert(LAWPComplianceEngine.LAWPComplianceEngine_ArrayMismatch.selector);
        engine.processPoolDeposit(POOL_ID, 1000e6, c0, w0);
    }

    function test_RevertIf_ProcessPoolDepositZeroActualReceived() public {
        address[] memory c = new address[](1);
        c[0] = alice;
        uint256[] memory w = new uint256[](1);
        w[0] = WAD;

        // Use a malicious token that takes 100% fee on transfer
        MockFOTToken badToken = new MockFOTToken();
        badToken.setFeeRate(10000); // 100%
        badToken.mint(campaignManager, 1000e6);

        LAWPComplianceEngine badEngine = new LAWPComplianceEngine(
            governance,
            address(opVault),
            address(opVault), // Using opVault for both to keep simple
            address(impactToken),
            address(badToken),
            50
        );
        vm.startPrank(governance);
        badEngine.setOperationalTreasuryWallet(opTreasuryWallet);
        badEngine.grantRole(badEngine.CAMPAIGN_MANAGER_ROLE(), campaignManager);
        vm.stopPrank();

        vm.startPrank(campaignManager);
        badToken.approve(address(badEngine), 1000e6);
        vm.expectRevert(LAWPComplianceEngine.LAWPComplianceEngine_ZeroActualReceived.selector);
        badEngine.processPoolDeposit(POOL_ID, 1000e6, c, w);
        vm.stopPrank();
    }

    // ==========================================
    // FEE ON TRANSFER / DELTA MEASUREMENT
    // ==========================================

    function test_ProcessPoolDepositFeeOnTransfer() public {
        // We will deploy a new ComplianceEngine configured with the MockFOTToken to test exact accounting.
        MockFOTToken fotToken = new MockFOTToken();

        uint64 nonce = vm.getNonce(address(this));
        address computedEngine = vm.computeCreateAddress(address(this), nonce + 3);

        LAWPOperationalVault fotOpVault = new LAWPOperationalVault(address(fotToken), computedEngine);
        LAWPYieldVault fotYieldVault = new LAWPYieldVault(address(fotToken), computedEngine);
        // We can reuse the original impactToken address since the token just checks permissions,
        // wait, we need a new impact token for the new engine!
        LAWPImpactToken fotImpact = new LAWPImpactToken(computedEngine, "ipfs://");

        LAWPComplianceEngine fotEngine = new LAWPComplianceEngine(
            governance, address(fotYieldVault), address(fotOpVault), address(fotImpact), address(fotToken), 50
        );
        require(address(fotEngine) == computedEngine);

        fotToken.mint(campaignManager, 1000e6);

        vm.startPrank(campaignManager);
        fotToken.approve(address(fotEngine), 1000e6);

        address[] memory c = new address[](1);
        c[0] = alice;
        uint256[] memory w = new uint256[](1);
        w[0] = WAD;

        vm.stopPrank();

        bytes32 cmRole = fotEngine.CAMPAIGN_MANAGER_ROLE();
        vm.prank(governance);
        fotEngine.grantRole(cmRole, campaignManager);

        vm.prank(governance);
        fotEngine.setOperationalTreasuryWallet(address(0x88));

        // Expect exact delta measurement:
        // Requested: 1000.
        // 5% FOT = 50 lost in transit.
        // Vault actually receives 950.
        // Risk Fee (0.5% of 950) = 4.75 -> truncated to 4.
        // Net Capital = 950 - 4.75 = 945.25.

        vm.prank(campaignManager);
        fotEngine.processPoolDeposit(POOL_ID, 1000e6, c, w);

        assertEq(fotEngine.getPoolNetCapital(POOL_ID), 945250000);
        assertEq(fotToken.balanceOf(address(fotOpVault)), 950e6);
    }

    // ==========================================
    // ROUTE ALLOCATIONS (SYSTEM 1 & 2)
    // ==========================================

    function test_RevertIf_RouteRoCZeroActualReceived() public {
        MockFOTToken feeToken = new MockFOTToken();
        feeToken.setFeeRate(10000); // 100% fee

        LAWPComplianceEngine testEngine = new LAWPComplianceEngine(
            governance, address(yieldVault), address(opVault), address(impactToken), address(feeToken), 50
        );

        vm.startPrank(governance);
        testEngine.grantRole(testEngine.OPERATOR_ROLE(), operator);
        testEngine.setLA2Wallet(la2Wallet);
        testEngine.setMVI1Wallet(mvi1Wallet);
        testEngine.setDevWallet(devWallet);
        testEngine.setOperationalTreasuryWallet(opTreasuryWallet);
        vm.stopPrank();

        feeToken.mint(operator, 1000e6);
        vm.startPrank(operator);
        feeToken.approve(address(testEngine), 1000e6);

        vm.expectRevert(LAWPComplianceEngine.LAWPComplianceEngine_ZeroActualReceived.selector);
        testEngine.routeOperationalAllocation(POOL_ID, 1000e6, operator, LAWPStructs.FlowType.RoC);
        vm.stopPrank();
    }

    function test_RevertIf_RouteGrantInitialZeroActualReceived() public {
        MockFOTToken feeToken = new MockFOTToken();
        feeToken.setFeeRate(10000); // 100% fee

        LAWPComplianceEngine testEngine = new LAWPComplianceEngine(
            governance, address(yieldVault), address(opVault), address(impactToken), address(feeToken), 50
        );

        vm.startPrank(governance);
        testEngine.grantRole(testEngine.OPERATOR_ROLE(), operator);
        testEngine.setLA2Wallet(la2Wallet);
        testEngine.setMVI1Wallet(mvi1Wallet);
        testEngine.setDevWallet(devWallet);
        testEngine.setOperationalTreasuryWallet(opTreasuryWallet);
        vm.stopPrank();

        feeToken.mint(operator, 1000e6);
        vm.startPrank(operator);
        feeToken.approve(address(testEngine), 1000e6);

        vm.expectRevert(LAWPComplianceEngine.LAWPComplianceEngine_ZeroActualReceived.selector);
        testEngine.routeOperationalAllocation(POOL_ID, 1000e6, operator, LAWPStructs.FlowType.GRANT_INITIAL);
        vm.stopPrank();
    }

    function test_RevertIf_RouteGrantContinuousZeroActualReceived() public {
        MockFOTToken feeToken = new MockFOTToken();
        feeToken.setFeeRate(10000); // 100% fee

        LAWPComplianceEngine testEngine = new LAWPComplianceEngine(
            governance, address(yieldVault), address(opVault), address(impactToken), address(feeToken), 50
        );

        vm.startPrank(governance);
        testEngine.grantRole(testEngine.OPERATOR_ROLE(), operator);
        testEngine.setLA2Wallet(la2Wallet);
        testEngine.setMVI1Wallet(mvi1Wallet);
        testEngine.setDevWallet(devWallet);
        testEngine.setOperationalTreasuryWallet(opTreasuryWallet);
        vm.stopPrank();

        feeToken.mint(operator, 1000e6);
        vm.startPrank(operator);
        feeToken.approve(address(testEngine), 1000e6);

        vm.expectRevert(LAWPComplianceEngine.LAWPComplianceEngine_ZeroActualReceived.selector);
        testEngine.routeOperationalAllocation(POOL_ID, 1000e6, operator, LAWPStructs.FlowType.GRANT_CONTINUOUS);
        vm.stopPrank();
    }

    function test_RevertIf_RouteGrantInitialZeroOpReceived() public {
        MockZeroOpToken feeToken = new MockZeroOpToken();

        LAWPComplianceEngine testEngine = new LAWPComplianceEngine(
            governance, address(yieldVault), address(opVault), address(impactToken), address(feeToken), 50
        );

        feeToken.setOpVault(address(opVault));

        vm.startPrank(governance);
        testEngine.grantRole(testEngine.OPERATOR_ROLE(), operator);
        testEngine.setLA2Wallet(la2Wallet);
        testEngine.setMVI1Wallet(mvi1Wallet);
        testEngine.setDevWallet(devWallet);
        testEngine.setOperationalTreasuryWallet(opTreasuryWallet);
        vm.stopPrank();

        feeToken.mint(operator, 1000e6);
        vm.startPrank(operator);
        feeToken.approve(address(testEngine), 1000e6);

        vm.expectRevert(LAWPComplianceEngine.LAWPComplianceEngine_ZeroActualReceived.selector);
        testEngine.routeOperationalAllocation(POOL_ID, 1000e6, operator, LAWPStructs.FlowType.GRANT_INITIAL);
        vm.stopPrank();
    }

    function test_RevertIf_RouteGrantContinuousZeroOpReceived() public {
        MockZeroOpToken feeToken = new MockZeroOpToken();

        LAWPComplianceEngine testEngine = new LAWPComplianceEngine(
            governance, address(yieldVault), address(opVault), address(impactToken), address(feeToken), 50
        );

        feeToken.setOpVault(address(opVault));

        vm.startPrank(governance);
        testEngine.grantRole(testEngine.OPERATOR_ROLE(), operator);
        testEngine.setLA2Wallet(la2Wallet);
        testEngine.setMVI1Wallet(mvi1Wallet);
        testEngine.setDevWallet(devWallet);
        testEngine.setOperationalTreasuryWallet(opTreasuryWallet);
        vm.stopPrank();

        feeToken.mint(operator, 1000e6);
        vm.startPrank(operator);
        feeToken.approve(address(testEngine), 1000e6);

        vm.expectRevert(LAWPComplianceEngine.LAWPComplianceEngine_ZeroActualReceived.selector);
        testEngine.routeOperationalAllocation(POOL_ID, 1000e6, operator, LAWPStructs.FlowType.GRANT_CONTINUOUS);
        vm.stopPrank();
    }

    function test_RouteRoC() public {
        test_ProcessPoolDeposit(); // Contributed net capital = 995e6

        uint256 rocAmount = 400e6;
        token.mint(operator, rocAmount);

        vm.startPrank(operator);
        token.approve(address(engine), rocAmount);

        engine.routeOperationalAllocation(POOL_ID, rocAmount, operator, LAWPStructs.FlowType.RoC);
        vm.stopPrank();

        assertEq(engine.poolRocTracker(POOL_ID), rocAmount);
        assertEq(token.balanceOf(address(yieldVault)), rocAmount);
    }

    function test_RevertIf_RouteRoCExceedsCap() public {
        test_ProcessPoolDeposit(); // Contributed net capital = 995e6

        uint256 rocAmount = 1000e6; // Exceeds 995e6
        token.mint(operator, rocAmount);

        vm.startPrank(operator);
        token.approve(address(engine), rocAmount);

        vm.expectRevert(LAWPComplianceEngine.LAWPComplianceEngine_ExceedsPrincipalCap.selector);
        engine.routeOperationalAllocation(POOL_ID, rocAmount, operator, LAWPStructs.FlowType.RoC);
        vm.stopPrank();
    }

    function test_RouteGrantInitial() public {
        test_ProcessPoolDeposit();

        uint256 amount = 1000e6;
        token.mint(operator, amount);

        vm.startPrank(operator);
        token.approve(address(engine), amount);
        engine.routeOperationalAllocation(POOL_ID, amount, operator, LAWPStructs.FlowType.GRANT_INITIAL);
        vm.stopPrank();

        // System 1 Math (WP 4.1):
        // 30% Yield Vault -> 300
        // 50% LA2, 20% MVI1 -> Op Vault (700)
        assertEq(token.balanceOf(address(yieldVault)), 300e6);
        assertEq(token.balanceOf(address(opVault)), 1000e6 + 700e6); // 1000 initial + 700

        assertEq(engine.poolYieldTracker(POOL_ID), 300e6);
        assertEq(engine.operationalBalances(la2Wallet), 500e6);
        assertEq(engine.operationalBalances(mvi1Wallet), 200e6);
    }

    function test_RevertIf_RouteOperationalAllocationInvalidAmount() public {
        vm.prank(operator);
        vm.expectRevert(LAWPComplianceEngine.LAWPComplianceEngine_InvalidAmount.selector);
        engine.routeOperationalAllocation(POOL_ID, 0, operator, LAWPStructs.FlowType.RoC);
    }

    function test_RouteGrantContinuous() public {
        test_ProcessPoolDeposit();

        uint256 amount = 1000e6;
        token.mint(operator, amount);

        vm.startPrank(operator);
        token.approve(address(engine), amount);
        engine.routeOperationalAllocation(POOL_ID, amount, operator, LAWPStructs.FlowType.GRANT_CONTINUOUS);
        vm.stopPrank();

        // System 2 (GRANT_CONTINUOUS) Math (WP 4.2 / Protocol Clarification):
        // Total Continuous Grant = 100%
        // 10% Yield Vault (Human Node / Contributor) -> 100
        // 90% Op Vault -> 900
        //   - 55% LA2 (55% of original total = 550)
        //   - 25% MVI1 (25% of original total = 250)
        //   - 10% Dev (10% of original total = 100)

        assertEq(token.balanceOf(address(yieldVault)), 100e6);
        assertEq(token.balanceOf(address(opVault)), 1000e6 + 900e6);

        assertEq(engine.poolYieldTracker(POOL_ID), 100e6);
        assertEq(engine.operationalBalances(la2Wallet), 550e6);
        assertEq(engine.operationalBalances(mvi1Wallet), 250e6);
        assertEq(engine.operationalBalances(devWallet), 100e6);
        assertEq(engine.operationalBalances(opTreasuryWallet), 1000e6); // 1000e6 from pool deposit + 0 from continuous grant
    }

    // ==========================================
    // CLAIM LOGIC
    // ==========================================

    function test_ClaimYieldAndRoc() public {
        test_ProcessPoolDeposit();
        // Token 1: 40%, Token 2: 60%
        // Net Capital = 995e6

        // Route RoC: 100e6
        // Token 1 RoC share = 40e6
        uint256 rocAmount = 100e6;
        token.mint(operator, rocAmount);
        vm.startPrank(operator);
        token.approve(address(engine), rocAmount);
        engine.routeOperationalAllocation(POOL_ID, rocAmount, operator, LAWPStructs.FlowType.RoC);
        vm.stopPrank();

        // Route Continuous Grant: 1000e6 (yield gets 100e6)
        // Token 1 yield share = 40e6
        uint256 grantAmount = 1000e6;
        token.mint(operator, grantAmount);
        vm.startPrank(operator);
        token.approve(address(engine), grantAmount);
        engine.routeOperationalAllocation(POOL_ID, grantAmount, operator, LAWPStructs.FlowType.GRANT_CONTINUOUS);
        vm.stopPrank();

        // claim yield directly
        vm.prank(alice);
        engine.claimYield(1);

        assertEq(token.balanceOf(alice), 80e6); // 40 RoC + 40 Yield

        LAWPStructs.TokenData memory d1 = impactToken.getTokenData(1);
        assertEq(d1.rocReturned, 40e6);
        assertEq(engine.yieldClaimed(1), 40e6);
    }

    function test_RevertIf_ClaimYieldNothingToClaim() public {
        test_ProcessPoolDeposit();

        vm.prank(alice);
        vm.expectRevert(LAWPComplianceEngine.LAWPComplianceEngine_NothingToClaim.selector);
        engine.claimYield(1);
    }

    function test_RevertIf_ClaimYieldNotOwner() public {
        test_ProcessPoolDeposit();

        vm.prank(bob); // Token 1 is owned by alice
        vm.expectRevert(abi.encodeWithSelector(LAWPComplianceEngine.LAWPComplianceEngine_NotTokenOwner.selector, 1));
        engine.claimYield(1);
    }

    function test_ClaimYield_HookSilentReturnIfZero() public {
        test_ProcessPoolDeposit(); // Token 1 exists, but 0 yield.

        vm.prank(address(impactToken)); // Hook path
        engine.claimYield(1); // Should return silently, not revert

        // Yield is still 0
        assertEq(engine.yieldClaimed(1), 0);
    }

    function test_ClaimYieldBatch() public {
        test_ProcessPoolDeposit();
        // Alice has token 1 (40%), Bob has token 2 (60%)

        // Alice transfers her token to Bob so Bob has both (BEFORE yield is routed)
        vm.prank(alice);
        impactToken.transferFrom(alice, bob, 1);

        uint256 grantAmount = 1000e6;
        token.mint(operator, grantAmount);
        vm.startPrank(operator);
        token.approve(address(engine), grantAmount);
        engine.routeOperationalAllocation(POOL_ID, grantAmount, operator, LAWPStructs.FlowType.GRANT_CONTINUOUS);
        vm.stopPrank();

        // Yield Vault got 100e6
        // Net capital was 995e6 (Token 1: 40%, Token 2: 60%)
        // So Alice gets 40e6, Bob gets 60e6 (but Bob owns both, so Bob gets all 100e6)

        uint256 bobBalBefore = token.balanceOf(bob);

        uint256[] memory tokens = new uint256[](2);
        tokens[0] = 1;
        tokens[1] = 2;

        vm.prank(bob);
        engine.claimYieldBatch(tokens);

        assertEq(token.balanceOf(bob) - bobBalBefore, 100e6);
        assertEq(engine.yieldClaimed(1), 40e6);
        assertEq(engine.yieldClaimed(2), 60e6);
    }

    function test_RevertIf_ClaimYieldBatchTooLarge() public {
        uint256[] memory tokens = new uint256[](51);

        vm.prank(bob);
        vm.expectRevert(LAWPComplianceEngine.LAWPComplianceEngine_BatchTooLarge.selector);
        engine.claimYieldBatch(tokens);
    }

    function test_RevertIf_ClaimYieldBatchNotOwner() public {
        test_ProcessPoolDeposit();
        uint256[] memory tokens = new uint256[](1);
        tokens[0] = 1; // Alice owns 1

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(LAWPComplianceEngine.LAWPComplianceEngine_NotTokenOwner.selector, 1));
        engine.claimYieldBatch(tokens);
    }

    function test_RevertIf_ClaimYieldBatchNothingToClaim() public {
        test_ProcessPoolDeposit();
        uint256[] memory tokens = new uint256[](1);
        tokens[0] = 1;

        vm.prank(alice);
        vm.expectRevert(LAWPComplianceEngine.LAWPComplianceEngine_NothingToClaim.selector);
        engine.claimYieldBatch(tokens);
    }

    function test_ClaimOperationalFunds() public {
        test_RouteGrantContinuous(); // Fills la2Wallet, etc.

        uint256 bal = engine.operationalBalances(la2Wallet);

        vm.prank(la2Wallet);
        engine.claimOperationalFunds();

        assertEq(engine.operationalBalances(la2Wallet), 0);
        assertEq(token.balanceOf(la2Wallet), bal);
    }

    function test_RevertIf_ClaimOperationalFundsZero() public {
        vm.prank(bob); // Bob has nothing
        vm.expectRevert(LAWPComplianceEngine.LAWPComplianceEngine_NoOperationalFunds.selector);
        engine.claimOperationalFunds();
    }

    function test_MigrateOperationalBalance() public {
        test_RouteGrantContinuous();

        uint256 la2Bal = engine.operationalBalances(la2Wallet);
        assertTrue(la2Bal > 0);

        vm.prank(governance);
        engine.migrateOperationalBalance(la2Wallet, bob);

        assertEq(engine.operationalBalances(la2Wallet), 0);
        assertEq(engine.operationalBalances(bob), la2Bal);
    }

    function test_RevertIf_MigrateOperationalBalanceZeroAddress() public {
        vm.startPrank(governance);
        vm.expectRevert(LAWPComplianceEngine.LAWPComplianceEngine_ZeroAddress.selector);
        engine.migrateOperationalBalance(address(0), bob);

        vm.expectRevert(LAWPComplianceEngine.LAWPComplianceEngine_ZeroAddress.selector);
        engine.migrateOperationalBalance(la2Wallet, address(0));
        vm.stopPrank();
    }
}
