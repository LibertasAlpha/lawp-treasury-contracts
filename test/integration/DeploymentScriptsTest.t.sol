// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test, console2 } from "forge-std/Test.sol";
import { Deploy } from "../../script/Deploy.s.sol";
import { Configure } from "../../script/Configure.s.sol";
import { DeployMock } from "../../script/DeployMock.s.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { LAWPComplianceEngine } from "../../src/core/LAWPComplianceEngine.sol";
import { LAWPTreasury } from "../../src/core/LAWPTreasury.sol";
import { LAWPImpactToken } from "../../src/core/LAWPImpactToken.sol";
import { LAWPActorRegistry } from "../../src/core/LAWPActorRegistry.sol";
import { LAWPMultiSigController } from "../../src/core/LAWPMultiSigController.sol";
import { MockAdminOperations, MockCngn3 } from "../mocks/MockCngn3.sol";

/// @title Deployment Scripts Integration Test
/// @notice Achieves 100% Function, Line, and Branch coverage on Deploy.s.sol, Configure.s.sol, and DeployMock.s.sol
contract DeploymentScriptsTest is Test {
    Deploy deployScript;
    Configure configureScript;
    DeployMock deployMockScript;

    uint256 deployerPk = 0xA11CE;
    address deployer;

    // Dynamically captured addresses during script execution
    address adminOpsAddr;
    address cngnAddr;
    address timelockAddr;
    address registryAddr;
    address treasuryAddr;
    address impactTokenAddr;
    address engineAddr;
    address multiSigAddr;

    function setUp() public {
        // Fix for the Timelock Time Paradox: Move timestamp away from 1 (OZ's _DONE_TIMESTAMP)
        vm.warp(1000);

        deployer = vm.addr(deployerPk);
        deployScript = new Deploy();
        configureScript = new Configure();
        deployMockScript = new DeployMock();

        // 1. Mock Environment Variables required by the Scripts
        vm.setEnv("PRIVATE_KEY", vm.toString(deployerPk));
        vm.setEnv("BASE_URI", "ipfs://lawp-test/");
        vm.setEnv("BOARD_SIGNER_1", vm.toString(address(0x11)));
        vm.setEnv("BOARD_SIGNER_2", vm.toString(address(0x12)));
        vm.setEnv("BOARD_SIGNER_3", vm.toString(address(0x13)));
        vm.setEnv("BOARD_SIGNER_4", vm.toString(address(0x14)));
        vm.setEnv("BOARD_SIGNER_5", vm.toString(address(0x15)));

        vm.setEnv("ADMIN_SAFE_ADDRESS", vm.toString(address(0x99)));
        vm.setEnv("LA2_WALLET", vm.toString(address(0xAA)));
        vm.setEnv("MVI1_WALLET", vm.toString(address(0xBB)));
        vm.setEnv("RISK_POOL_WALLET", vm.toString(address(0xCC)));
        vm.setEnv("DEV_WALLET", vm.toString(address(0xDD)));
    }

    /// @dev Executes DeployMock.s.sol and Deploy.s.sol to populate the environment for Configuration
    function _executeDeployments() internal {
        // 1. Execute DeployMock
        uint256 nonceBeforeMock = vm.getNonce(deployer);
        deployMockScript.run();
        
        // Deterministically predict CREATE addresses based on deployer nonce
        adminOpsAddr = vm.computeCreateAddress(deployer, nonceBeforeMock);
        cngnAddr = vm.computeCreateAddress(deployer, nonceBeforeMock + 1);

        vm.setEnv("CNGN_TOKEN_ADDRESS", vm.toString(cngnAddr));

        // 2. Execute Core Deploy
        uint256 nonceBeforeDeploy = vm.getNonce(deployer);
        deployScript.run();

        // Deterministically map deployed core contracts
        timelockAddr = vm.computeCreateAddress(deployer, nonceBeforeDeploy);
        registryAddr = vm.computeCreateAddress(deployer, nonceBeforeDeploy + 1);
        treasuryAddr = vm.computeCreateAddress(deployer, nonceBeforeDeploy + 2);
        impactTokenAddr = vm.computeCreateAddress(deployer, nonceBeforeDeploy + 3);
        engineAddr = vm.computeCreateAddress(deployer, nonceBeforeDeploy + 4);
        multiSigAddr = vm.computeCreateAddress(deployer, nonceBeforeDeploy + 5);

        vm.setEnv("TIMELOCK_ADDRESS", vm.toString(timelockAddr));
        vm.setEnv("ENGINE_ADDRESS", vm.toString(engineAddr));
        vm.setEnv("TREASURY_ADDRESS", vm.toString(treasuryAddr));
        vm.setEnv("TOKEN_ADDRESS", vm.toString(impactTokenAddr));
        vm.setEnv("REGISTRY_ADDRESS", vm.toString(registryAddr));
        vm.setEnv("MULTISIG_ADDRESS", vm.toString(multiSigAddr));
    }

    /*//////////////////////////////////////////////////////////////
                           HAPPY PATH TEST
    //////////////////////////////////////////////////////////////*/

    function test_HappyPathDeploymentAndConfig() public {
        _executeDeployments();
        
        // 3. Execute Configure
        configureScript.run();

        // Verify DeployMock outcomes
        MockAdminOperations adminOps = MockAdminOperations(adminOpsAddr);
        assertTrue(adminOps.canMint(deployer));
        assertEq(MockCngn3(cngnAddr).name(), "cNGN");

        // Verify Core Deploy & Configure outcomes
        TimelockController timelock = TimelockController(payable(timelockAddr));
        assertEq(LAWPActorRegistry(registryAddr).owner(), timelockAddr);
        assertEq(LAWPTreasury(treasuryAddr).owner(), timelockAddr);
        assertEq(LAWPImpactToken(impactTokenAddr).owner(), timelockAddr);
        assertEq(LAWPComplianceEngine(engineAddr).owner(), timelockAddr);
        assertEq(LAWPMultiSigController(multiSigAddr).owner(), timelockAddr);

        assertEq(timelock.getMinDelay(), 2 days);

        // Verify Deployer Lockout
        bytes32 DEFAULT_ADMIN_ROLE = 0x00;
        assertFalse(timelock.hasRole(DEFAULT_ADMIN_ROLE, deployer));
        assertFalse(timelock.hasRole(timelock.CANCELLER_ROLE(), deployer));
        assertFalse(timelock.hasRole(timelock.PROPOSER_ROLE(), deployer));
        assertFalse(timelock.hasRole(timelock.EXECUTOR_ROLE(), deployer));

        // Verify Admin Safe & Open Execution
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), address(0x99)));
        assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), address(0x99)));
        assertTrue(timelock.hasRole(timelock.EXECUTOR_ROLE(), address(0)));
    }

    /*//////////////////////////////////////////////////////////////
                     100% BRANCH COVERAGE TESTS
    //////////////////////////////////////////////////////////////*/

    /// @dev Wraps vm.mockCall inside a snapshot to isolate state changes and trigger requires
    function _testRevertBranch(
        address target, 
        bytes memory callData, 
        bytes memory retData, 
        string memory expectedRevertMsg,
        bool isPreFlight
    ) internal {
        // Upgraded to non-deprecated snapshot cheatcode
        uint256 snap = vm.snapshotState();
        
        vm.mockCall(target, callData, retData);
        vm.expectRevert(bytes(expectedRevertMsg));
        configureScript.run(); // Will hit the mocked call and fail the specific require() branch
        
        // Pre-flight checks revert BEFORE the script can call vm.stopBroadcast().
        // Post-flight checks revert AFTER the script has already called vm.stopBroadcast().
        if (isPreFlight) {
            vm.stopBroadcast();
        }

        vm.clearMockedCalls();
        // Upgraded to non-deprecated revert cheatcode
        assertTrue(vm.revertToState(snap));
    }

    function test_ConfigureBranches_PreFlight() public {
        _executeDeployments();

        bytes memory pendingOwnerCall = abi.encodeWithSignature("pendingOwner()");
        bytes memory zeroAddressRet = abi.encode(address(0));

        // Force every PreFlight branch to fail and revert (broadcast is still hanging)
        _testRevertBranch(registryAddr, pendingOwnerCall, zeroAddressRet, "PreFlight: Registry owner mismatch", true);
        _testRevertBranch(treasuryAddr, pendingOwnerCall, zeroAddressRet, "PreFlight: Treasury owner mismatch", true);
        _testRevertBranch(impactTokenAddr, pendingOwnerCall, zeroAddressRet, "PreFlight: Token owner mismatch", true);
        _testRevertBranch(engineAddr, pendingOwnerCall, zeroAddressRet, "PreFlight: Engine owner mismatch", true);
        _testRevertBranch(multiSigAddr, pendingOwnerCall, zeroAddressRet, "PreFlight: MultiSig owner mismatch", true);
    }

    function test_ConfigureBranches_PostFlight() public {
        _executeDeployments();

        bytes memory ownerCall = abi.encodeWithSignature("owner()");
        bytes memory zeroAddressRet = abi.encode(address(0));

        // Force every PostFlight branch to fail and revert (broadcast is already closed)
        _testRevertBranch(registryAddr, ownerCall, zeroAddressRet, "PostFlight: Registry handover failed", false);
        _testRevertBranch(treasuryAddr, ownerCall, zeroAddressRet, "PostFlight: Treasury handover failed", false);
        _testRevertBranch(impactTokenAddr, ownerCall, zeroAddressRet, "PostFlight: Token handover failed", false);
        _testRevertBranch(engineAddr, ownerCall, zeroAddressRet, "PostFlight: Engine handover failed", false);
        _testRevertBranch(multiSigAddr, ownerCall, zeroAddressRet, "PostFlight: MultiSig handover failed", false);

        _testRevertBranch(timelockAddr, abi.encodeWithSignature("getMinDelay()"), abi.encode(0), "PostFlight: Delay update failed", false);

        bytes32 DEFAULT_ADMIN_ROLE = 0x00;
        TimelockController tl = TimelockController(payable(timelockAddr));

        _testRevertBranch(
            timelockAddr, 
            abi.encodeWithSignature("hasRole(bytes32,address)", DEFAULT_ADMIN_ROLE, deployer), 
            abi.encode(true), 
            "PostFlight: Deployer retains God Mode!",
            false
        );

        _testRevertBranch(
            timelockAddr, 
            abi.encodeWithSignature("hasRole(bytes32,address)", tl.CANCELLER_ROLE(), deployer), 
            abi.encode(true), 
            "PostFlight: Deployer retains Canceller Mode!",
            false
        );
    }
}