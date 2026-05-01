// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { LAWPComplianceEngine } from "../../src/core/LAWPComplianceEngine.sol";
import { LAWPTreasury } from "../../src/core/LAWPTreasury.sol";
import { LAWPImpactToken } from "../../src/core/LAWPImpactToken.sol";
import { LAWPActorRegistry } from "../../src/core/LAWPActorRegistry.sol";
import { MockCngn3, MockAdminOperations } from "../mocks/MockCngn3.sol";
import { LAWPStructs } from "../../src/libraries/LAWPStructs.sol";
import { LAWPErrors } from "../../src/libraries/LAWPErrors.sol";

contract LAWPComplianceEngineTest is Test, LAWPErrors {
    LAWPComplianceEngine public engine;
    LAWPTreasury public treasury;
    LAWPImpactToken public impactToken;
    LAWPActorRegistry public registry;
    MockCngn3 public cngn;
    MockAdminOperations public adminOps;

    address public admin = address(1);
    address public multiSig = address(2);
    address public la2Wallet = address(3);
    address public mvi1Wallet = address(4);
    address public riskPoolWallet = address(5);
    address public devWallet = address(6);
    address public coordinator = address(7);

    address public userA = address(10);
    address public userB = address(11);
    address public userC = address(12);

    function setUp() public {
        // 1. Deploy Mocks & Dependencies
        adminOps = new MockAdminOperations();
        cngn = new MockCngn3(address(adminOps));

        registry = new LAWPActorRegistry(admin);
        treasury = new LAWPTreasury(address(cngn), admin);
        impactToken = new LAWPImpactToken(admin, "ipfs://base/");

        // 2. Configure Registry
        vm.startPrank(admin);
        registry.setLA2Wallet(la2Wallet);
        registry.setMVI1Wallet(mvi1Wallet);
        registry.setRiskPoolWallet(riskPoolWallet);
        registry.setDevWallet(devWallet);
        vm.stopPrank();

        // 3. Deploy Engine (10% Risk Fee = 1000 BPS)
        engine = new LAWPComplianceEngine(
            admin,
            address(treasury),
            address(impactToken),
            address(registry),
            address(cngn),
            1000
        );

        // 4. Link Systems
        vm.startPrank(admin);
        engine.setMultiSigController(multiSig);
        treasury.setComplianceEngine(address(engine));
        treasury.setRiskPoolWallet(riskPoolWallet);
        impactToken.setComplianceEngine(address(engine));
        vm.stopPrank();

        // 5. Seed Test Users
        cngn.mintTest(coordinator, 1_000_000e6);
        cngn.mintTest(multiSig, 1_000_000e6);
        cngn.mintTest(address(treasury), 1_000_000e6); // Seed vault for revenue tests

        // The engine pulls funds using safeTransferFrom on deposit, so msg.sender (coordinator) must approve the engine.
        vm.prank(coordinator);
        cngn.approve(address(engine), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                           CONSTRUCTOR TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Constructor_RevertIf_ZeroAddresses() public {
        vm.expectRevert(LAWPComplianceEngine_ZeroAddress.selector);
        new LAWPComplianceEngine(admin, address(0), address(impactToken), address(registry), address(cngn), 1000);

        vm.expectRevert(LAWPComplianceEngine_ZeroAddress.selector);
        new LAWPComplianceEngine(admin, address(treasury), address(0), address(registry), address(cngn), 1000);

        vm.expectRevert(LAWPComplianceEngine_ZeroAddress.selector);
        new LAWPComplianceEngine(admin, address(treasury), address(impactToken), address(0), address(cngn), 1000);

        vm.expectRevert(LAWPComplianceEngine_ZeroAddress.selector);
        new LAWPComplianceEngine(admin, address(treasury), address(impactToken), address(registry), address(0), 1000);
    }

    function test_Constructor_RevertIf_InvalidRiskFee() public {
        vm.expectRevert(LAWPComplianceEngine_InvalidRiskFee.selector);
        new LAWPComplianceEngine(admin, address(treasury), address(impactToken), address(registry), address(cngn), 0);

        vm.expectRevert(LAWPComplianceEngine_InvalidRiskFee.selector);
        new LAWPComplianceEngine(admin, address(treasury), address(impactToken), address(registry), address(cngn), 1001);
    }

    /*//////////////////////////////////////////////////////////////
                         ADMIN & CONFIG TESTS
    //////////////////////////////////////////////////////////////*/

    function test_RenounceOwnership_Reverts() public {
        vm.prank(admin);
        vm.expectRevert("LAWPComplianceEngine: renounceOwnership is disabled");
        engine.renounceOwnership();
    }

    function test_SetMultiSigController() public {
        vm.prank(admin);
        engine.setMultiSigController(address(99));
        assertEq(engine.multiSigController(), address(99));
    }

    function test_SetMultiSigController_RevertIf_ZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(LAWPComplianceEngine_ZeroAddress.selector);
        engine.setMultiSigController(address(0));
    }

    function test_UpdateRiskFee() public {
        vm.prank(admin);
        engine.updateRiskFee(500);
        assertEq(engine.riskFeeBPS(), 500);
    }

    function test_UpdateRiskFee_RevertIf_Invalid() public {
        vm.startPrank(admin);
        vm.expectRevert(LAWPComplianceEngine_InvalidRiskFee.selector);
        engine.updateRiskFee(0);

        vm.expectRevert(LAWPComplianceEngine_InvalidRiskFee.selector);
        engine.updateRiskFee(1001);
        vm.stopPrank();
    }

    function test_PauseUnpause() public {
        vm.prank(multiSig);
        engine.emergencyPause();
        assertTrue(engine.paused());

        vm.prank(userA);
        vm.expectRevert();
        engine.emergencyPause(); 

        vm.prank(admin);
        engine.unpause();
        assertFalse(engine.paused());
    }

    /*//////////////////////////////////////////////////////////////
                      PROCESS POOL DEPOSIT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_ProcessPoolDeposit_RevertIf_Paused() public {
        vm.prank(multiSig);
        engine.emergencyPause();

        address[] memory users = new address[](1); users[0] = userA;
        uint256[] memory bps = new uint256[](1); bps[0] = 10000;

        vm.prank(coordinator);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        engine.processPoolDeposit(1, 100_000e6, users, bps);
    }

    function test_ProcessPoolDeposit_RevertIf_PoolExists() public {
        address[] memory users = new address[](1); users[0] = userA;
        uint256[] memory bps = new uint256[](1); bps[0] = 10000;

        vm.startPrank(coordinator);
        engine.processPoolDeposit(1, 100_000e6, users, bps);
        
        vm.expectRevert(LAWPComplianceEngine_PoolAlreadyExists.selector);
        engine.processPoolDeposit(1, 100_000e6, users, bps);
        vm.stopPrank();
    }

    function test_ProcessPoolDeposit_RevertIf_InvalidAmount() public {
        address[] memory users = new address[](1); users[0] = userA;
        uint256[] memory bps = new uint256[](1); bps[0] = 10000;

        vm.prank(coordinator);
        vm.expectRevert(LAWPComplianceEngine_InvalidAmount.selector);
        engine.processPoolDeposit(1, 0, users, bps);
    }

    function test_ProcessPoolDeposit_RevertIf_ArrayMismatchOrTooLarge() public {
        address[] memory users = new address[](2); users[0] = userA; users[1] = userB;
        uint256[] memory bps = new uint256[](1); bps[0] = 10000;

        vm.startPrank(coordinator);
        
        vm.expectRevert(LAWPComplianceEngine_ArrayMismatch.selector);
        engine.processPoolDeposit(1, 100_000e6, users, bps);

        address[] memory emptyUsers = new address[](0);
        uint256[] memory emptyBps = new uint256[](0);
        vm.expectRevert(LAWPComplianceEngine_ArrayMismatch.selector);
        engine.processPoolDeposit(1, 100_000e6, emptyUsers, emptyBps);

        address[] memory hugeUsers = new address[](21);
        uint256[] memory hugeBps = new uint256[](21);
        vm.expectRevert(LAWPComplianceEngine_ArrayTooLarge.selector);
        engine.processPoolDeposit(1, 100_000e6, hugeUsers, hugeBps);

        vm.stopPrank();
    }

    function test_ProcessPoolDeposit_RevertIf_InvalidBPS() public {
        address[] memory users = new address[](2); users[0] = userA; users[1] = userB;
        uint256[] memory bps = new uint256[](2); bps[0] = 5000; bps[1] = 4999;

        vm.prank(coordinator);
        vm.expectRevert(LAWPComplianceEngine_InvalidBPS.selector);
        engine.processPoolDeposit(1, 100_000e6, users, bps);
    }

    function test_ProcessPoolDeposit_Success_WithDust() public {
        uint256 depositAmt = 100_000e6;
        
        address[] memory users = new address[](3);
        users[0] = userA; users[1] = userB; users[2] = userC;
        
        uint256[] memory bps = new uint256[](3);
        bps[0] = 3333; bps[1] = 3333; bps[2] = 3334;

        uint256 vaultBalBefore = treasury.getVaultBalance();

        vm.prank(coordinator);
        engine.processPoolDeposit(1, depositAmt, users, bps);

        // Risk fee = 10,000. Net Capital = 90,000
        assertEq(cngn.balanceOf(riskPoolWallet), 10_000e6);
        assertEq(treasury.getVaultBalance(), vaultBalBefore + 90_000e6);

        // Check Dust Distribution
        // User A & B: (90,000 * 3333) / 10000 = 29997
        LAWPStructs.TokenData memory dataA = impactToken.getTokenData(1);
        assertEq(dataA.netPrincipal, 29997e6);

        LAWPStructs.TokenData memory dataB = impactToken.getTokenData(2);
        assertEq(dataB.netPrincipal, 29997e6);

        // User C gets the remainder: 90000 - 29997 - 29997 = 30006
        LAWPStructs.TokenData memory dataC = impactToken.getTokenData(3);
        assertEq(dataC.netPrincipal, 30006e6);
    }

    /*//////////////////////////////////////////////////////////////
                        VALIDATE AND ROUTE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_ValidateAndRoute_RevertIf_InvalidAmount() public {
        vm.prank(multiSig);
        vm.expectRevert(LAWPComplianceEngine_InvalidAmount.selector);
        engine.validateAndRoute(1, 0, LAWPStructs.FlowType.RoC);
    }

    function test_ValidateAndRoute_RevertIf_InvalidFlowType() public {
        vm.prank(multiSig);
        (bool success, ) = address(engine).call(
            abi.encodeWithSelector(engine.validateAndRoute.selector, 1, 10_000e6, 99)
        );
        assertFalse(success, "Call should have reverted due to invalid enum");
    }

    function test_ValidateAndRoute_RevertIf_InvalidActor() public {
        // Mock the registry to return address(0) to simulate misconfiguration
        vm.mockCall(address(registry), abi.encodeWithSelector(registry.la2Wallet.selector), abi.encode(address(0)));
        
        vm.startPrank(multiSig);
        vm.expectRevert(LAWPComplianceEngine_InvalidActor.selector);
        engine.validateAndRoute(1, 10_000e6, LAWPStructs.FlowType.GRANT_INITIAL);

        vm.expectRevert(LAWPComplianceEngine_InvalidActor.selector);
        engine.validateAndRoute(1, 10_000e6, LAWPStructs.FlowType.GRANT_CONTINUOUS);
        vm.stopPrank();

        // Clear mock and mock devWallet for continuous
        vm.clearMockedCalls();
        vm.mockCall(address(registry), abi.encodeWithSelector(registry.devWallet.selector), abi.encode(address(0)));
        vm.prank(multiSig);
        vm.expectRevert(LAWPComplianceEngine_InvalidActor.selector);
        engine.validateAndRoute(1, 10_000e6, LAWPStructs.FlowType.GRANT_CONTINUOUS);
    }

    function test_ValidateAndRoute_Success() public {
        vm.startPrank(multiSig);
        
        // RoC
        engine.validateAndRoute(1, 10_000e6, LAWPStructs.FlowType.RoC);
        assertEq(engine.poolRocTracker(1), 10_000e6);

        // Grant Initial (30/50/20)
        uint256 la2Bal = cngn.balanceOf(la2Wallet);
        uint256 mvi1Bal = cngn.balanceOf(mvi1Wallet);
        
        engine.validateAndRoute(1, 10_000e6, LAWPStructs.FlowType.GRANT_INITIAL);
        assertEq(engine.poolYieldTracker(1), 3_000e6); // 30%
        assertEq(cngn.balanceOf(la2Wallet), la2Bal + 5_000e6); // 50%
        assertEq(cngn.balanceOf(mvi1Wallet), mvi1Bal + 2_000e6); // 20%

        // Grant Continuous (10/55/25/10)
        la2Bal = cngn.balanceOf(la2Wallet);
        mvi1Bal = cngn.balanceOf(mvi1Wallet);
        uint256 devBal = cngn.balanceOf(devWallet);

        engine.validateAndRoute(1, 10_000e6, LAWPStructs.FlowType.GRANT_CONTINUOUS);
        assertEq(engine.poolYieldTracker(1), 3_000e6 + 1_000e6); // +10%
        assertEq(cngn.balanceOf(la2Wallet), la2Bal + 5_500e6); // 55%
        assertEq(cngn.balanceOf(mvi1Wallet), mvi1Bal + 2_500e6); // 25%
        assertEq(cngn.balanceOf(devWallet), devBal + 1_000e6); // 10%
        
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                           CLAIM YIELD TESTS
    //////////////////////////////////////////////////////////////*/

    function _setupStandardDeposit() internal {
        address[] memory users = new address[](2); users[0] = userA; users[1] = userB;
        uint256[] memory bps = new uint256[](2); bps[0] = 6000; bps[1] = 4000;
        vm.prank(coordinator);
        engine.processPoolDeposit(1, 100_000e6, users, bps); // Net Capital = 90k
    }

    function test_ClaimYield_Success() public {
        _setupStandardDeposit();
        
        vm.prank(multiSig);
        engine.validateAndRoute(1, 10_000e6, LAWPStructs.FlowType.RoC);
        
        vm.prank(multiSig);
        engine.validateAndRoute(1, 10_000e6, LAWPStructs.FlowType.GRANT_INITIAL); // 3k yield to pool

        // Calculate expected for Token 1 (60%): 6,000 RoC + 1,800 Yield = 7,800
        assertEq(engine.calculateProportionalYield(1), 7_800e6);

        uint256 balanceBefore = cngn.balanceOf(userA);
        vm.prank(userA);
        engine.claimYield(1);

        assertEq(cngn.balanceOf(userA), balanceBefore + 7_800e6);
        assertEq(engine.yieldClaimed(1), 1_800e6);
        assertEq(impactToken.getTokenData(1).rocReturned, 6_000e6);
    }

    function test_ClaimYield_RevertIf_NothingToClaim() public {
        _setupStandardDeposit();
        vm.prank(userA);
        vm.expectRevert(LAWPComplianceEngine_NothingToClaim.selector);
        engine.claimYield(1); // Fails because no revenue has been routed yet
    }

    function test_ClaimYield_CappedRoc() public {
        _setupStandardDeposit(); // User A net principal = 54k

        vm.prank(multiSig);
        engine.validateAndRoute(1, 200_000e6, LAWPStructs.FlowType.RoC); // Overfund pool RoC

        // Calculate for Token 1 (60%): 120,000 Uncapped RoC. Should cap at 54,000.
        assertEq(engine.calculateProportionalYield(1), 54_000e6);

        vm.prank(userA);
        engine.claimYield(1);

        // Fully capped out. Next claim should yield 0.
        assertEq(impactToken.getTokenData(1).rocReturned, 54_000e6);
        vm.prank(userA);
        vm.expectRevert(LAWPComplianceEngine_NothingToClaim.selector);
        engine.claimYield(1);
    }

    /*//////////////////////////////////////////////////////////////
                        CLAIM YIELD BATCH TESTS
    //////////////////////////////////////////////////////////////*/

    function test_ClaimYieldBatch_Success_AndSkipsZeros() public {
        _setupStandardDeposit();
        
        // Give UserA a second token in pool 2
        address[] memory users = new address[](1); users[0] = userA;
        uint256[] memory bps = new uint256[](1); bps[0] = 10000;
        vm.prank(coordinator);
        engine.processPoolDeposit(2, 50_000e6, users, bps);

        // Tokens owned by UserA: ID 1 (Pool 1), ID 3 (Pool 2)
        // Route revenue ONLY to Pool 1
        vm.prank(multiSig);
        engine.validateAndRoute(1, 10_000e6, LAWPStructs.FlowType.RoC);

        uint256[] memory batch = new uint256[](2);
        batch[0] = 1; batch[1] = 3;

        uint256 balanceBefore = cngn.balanceOf(userA);
        vm.prank(userA);
        engine.claimYieldBatch(batch);

        // Should successfully claim 6,000 from Token 1, and elegantly skip Token 3 (0 claimable)
        assertEq(cngn.balanceOf(userA), balanceBefore + 6_000e6);
    }

    function test_ClaimYieldBatch_RevertIf_BatchTooLarge() public {
        uint256[] memory hugeBatch = new uint256[](21);
        vm.expectRevert(LAWPComplianceEngine_BatchTooLarge.selector);
        engine.claimYieldBatch(hugeBatch);
    }

    function test_ClaimYieldBatch_RevertIf_NotTokenOwner() public {
        _setupStandardDeposit();
        uint256[] memory batch = new uint256[](1);
        batch[0] = 1; // Owned by userA

        vm.prank(userB); // Malicious actor
        vm.expectRevert(abi.encodeWithSelector(LAWPComplianceEngine_NotTokenOwner.selector, 1));
        engine.claimYieldBatch(batch);
    }

    function test_ClaimYieldBatch_RevertIf_NothingToClaim() public {
        _setupStandardDeposit();
        uint256[] memory batch = new uint256[](1);
        batch[0] = 1;
        
        vm.prank(userA);
        vm.expectRevert(LAWPComplianceEngine_NothingToClaim.selector);
        engine.claimYieldBatch(batch);
    }
}