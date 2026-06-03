// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test, console2 } from "forge-std/Test.sol";
import { Deploy } from "../../script/Deploy.s.sol";
import { Configure } from "../../script/Configure.s.sol";
import { DeployMock } from "../../script/DeployMock.s.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { LAWPComplianceEngine } from "../../src/core/LAWPComplianceEngine.sol";
import { LAWPYieldVault } from "../../src/core/LAWPYieldVault.sol";
import { LAWPOperationalVault } from "../../src/core/LAWPOperationalVault.sol";
import { LAWPImpactToken } from "../../src/core/LAWPImpactToken.sol";
import { LAWPActorRegistry } from "../../src/core/LAWPActorRegistry.sol";
import { LAWPMultiSigController } from "../../src/core/LAWPMultiSigController.sol";
import { MockAdminOperations, MockCngn3 } from "../mocks/MockCngn3.sol";

/// @title DeploymentScriptsTest
/// @notice 100% branch coverage for Deploy.s.sol, Configure.s.sol, and DeployMock.s.sol.
///         Validates the full dual-vault deployment and Ownable2Step -> Timelock handover.
contract DeploymentScriptsTest is Test {
    Deploy deployScript;
    Configure configureScript;
    DeployMock deployMockScript;

    uint256 deployerPk = 0xA11CE;
    address deployer;

    // Deterministically captured addresses
    address adminOpsAddr;
    address cngnAddr;
    address timelockAddr;
    address registryAddr;
    address yieldVaultAddr;
    address opVaultAddr;
    address impactTokenAddr;
    address engineAddr;
    address multiSigAddr;

    function setUp() public {
        vm.warp(1000); // Avoid Timelock's _DONE_TIMESTAMP = 1

        deployer = vm.addr(deployerPk);
        deployScript = new Deploy();
        configureScript = new Configure();
        deployMockScript = new DeployMock();

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

    /// @dev Runs DeployMock + Deploy and populates env vars for Configure.
    ///      Deploy order (nonces):
    ///        DeployMock: adminOps(n), cngn(n+1)
    ///        Deploy: timelock(n), registry(n+1), yieldVault(n+2), opVault(n+3),
    ///                impactToken(n+4), engine(n+5), multiSig(n+6)
    function _executeDeployments() internal {
        uint256 nonceMock = vm.getNonce(deployer);
        deployMockScript.run();
        adminOpsAddr = vm.computeCreateAddress(deployer, nonceMock);
        cngnAddr = vm.computeCreateAddress(deployer, nonceMock + 1);
        vm.setEnv("CNGN_TOKEN_ADDRESS", vm.toString(cngnAddr));

        uint256 nonceDeploy = vm.getNonce(deployer);
        deployScript.run();
        timelockAddr = vm.computeCreateAddress(deployer, nonceDeploy);
        registryAddr = vm.computeCreateAddress(deployer, nonceDeploy + 1);
        yieldVaultAddr = vm.computeCreateAddress(deployer, nonceDeploy + 2);
        opVaultAddr = vm.computeCreateAddress(deployer, nonceDeploy + 3);
        impactTokenAddr = vm.computeCreateAddress(deployer, nonceDeploy + 4);
        engineAddr = vm.computeCreateAddress(deployer, nonceDeploy + 5);
        multiSigAddr = vm.computeCreateAddress(deployer, nonceDeploy + 6);

        vm.setEnv("TIMELOCK_ADDRESS", vm.toString(timelockAddr));
        vm.setEnv("ENGINE_ADDRESS", vm.toString(engineAddr));
        vm.setEnv("YIELD_VAULT_ADDRESS", vm.toString(yieldVaultAddr));
        vm.setEnv("OP_VAULT_ADDRESS", vm.toString(opVaultAddr));
        vm.setEnv("TOKEN_ADDRESS", vm.toString(impactTokenAddr));
        vm.setEnv("REGISTRY_ADDRESS", vm.toString(registryAddr));
        vm.setEnv("MULTISIG_ADDRESS", vm.toString(multiSigAddr));
    }

    /*//////////////////////////////////////////////////////////////
                         HAPPY PATH TEST
    //////////////////////////////////////////////////////////////*/

    function test_HappyPath_DeployAndConfigure() public {
        _executeDeployments();
        configureScript.run();

        // Mock token
        assertTrue(MockAdminOperations(adminOpsAddr).canMint(deployer));
        assertEq(MockCngn3(cngnAddr).name(), "cNGN");

        // All contracts owned by Timelock
        TimelockController timelock = TimelockController(payable(timelockAddr));
        assertEq(LAWPActorRegistry(registryAddr).owner(), timelockAddr);
        assertEq(LAWPYieldVault(yieldVaultAddr).owner(), timelockAddr);
        assertEq(LAWPOperationalVault(opVaultAddr).owner(), timelockAddr);
        assertEq(LAWPImpactToken(impactTokenAddr).owner(), timelockAddr);
        assertEq(LAWPComplianceEngine(engineAddr).owner(), timelockAddr);
        assertEq(LAWPMultiSigController(multiSigAddr).owner(), timelockAddr);

        assertEq(timelock.getMinDelay(), 2 days);

        // Deployer fully locked out
        bytes32 DEFAULT_ADMIN_ROLE = 0x00;
        assertFalse(timelock.hasRole(DEFAULT_ADMIN_ROLE, deployer));
        assertFalse(timelock.hasRole(timelock.CANCELLER_ROLE(), deployer));
        assertFalse(timelock.hasRole(timelock.PROPOSER_ROLE(), deployer));
        assertFalse(timelock.hasRole(timelock.EXECUTOR_ROLE(), deployer));

        // Admin Safe has correct roles
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), address(0x99)));
        assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), address(0x99)));
        assertTrue(timelock.hasRole(timelock.EXECUTOR_ROLE(), address(0)));

        // Dual-vault engine wiring
        LAWPComplianceEngine engine = LAWPComplianceEngine(engineAddr);
        assertEq(address(engine.yieldVault()), yieldVaultAddr);
        assertEq(address(engine.operationalVault()), opVaultAddr);
        assertEq(address(engine.multiSigController()), multiSigAddr);

        // Vault engine linkage
        assertEq(LAWPYieldVault(yieldVaultAddr).complianceEngine(), engineAddr);
        assertEq(LAWPOperationalVault(opVaultAddr).complianceEngine(), engineAddr);
    }

    /*//////////////////////////////////////////////////////////////
                    BRANCH COVERAGE: PRE-FLIGHT CHECKS
    //////////////////////////////////////////////////////////////*/

    function _testRevertBranch(
        address target,
        bytes memory callData,
        bytes memory retData,
        string memory expectedRevert,
        bool isPreFlight
    ) internal {
        uint256 snap = vm.snapshotState();
        vm.mockCall(target, callData, retData);
        vm.expectRevert(bytes(expectedRevert));
        configureScript.run();
        if (isPreFlight) vm.stopBroadcast();
        vm.clearMockedCalls();
        assertTrue(vm.revertToState(snap));
    }

    function test_PreFlight_RegistryOwnerMismatch() public {
        _executeDeployments();
        _testRevertBranch(
            registryAddr,
            abi.encodeWithSignature("pendingOwner()"),
            abi.encode(address(0)),
            "PreFlight: Registry owner mismatch",
            true
        );
    }

    function test_PreFlight_YieldVaultOwnerMismatch() public {
        _executeDeployments();
        _testRevertBranch(
            yieldVaultAddr,
            abi.encodeWithSignature("pendingOwner()"),
            abi.encode(address(0)),
            "PreFlight: YieldVault owner mismatch",
            true
        );
    }

    function test_PreFlight_OpVaultOwnerMismatch() public {
        _executeDeployments();
        _testRevertBranch(
            opVaultAddr,
            abi.encodeWithSignature("pendingOwner()"),
            abi.encode(address(0)),
            "PreFlight: OpVault owner mismatch",
            true
        );
    }

    function test_PreFlight_TokenOwnerMismatch() public {
        _executeDeployments();
        _testRevertBranch(
            impactTokenAddr,
            abi.encodeWithSignature("pendingOwner()"),
            abi.encode(address(0)),
            "PreFlight: Token owner mismatch",
            true
        );
    }

    function test_PreFlight_EngineOwnerMismatch() public {
        _executeDeployments();
        _testRevertBranch(
            engineAddr,
            abi.encodeWithSignature("pendingOwner()"),
            abi.encode(address(0)),
            "PreFlight: Engine owner mismatch",
            true
        );
    }

    function test_PreFlight_MultiSigOwnerMismatch() public {
        _executeDeployments();
        _testRevertBranch(
            multiSigAddr,
            abi.encodeWithSignature("pendingOwner()"),
            abi.encode(address(0)),
            "PreFlight: MultiSig owner mismatch",
            true
        );
    }

    /*//////////////////////////////////////////////////////////////
                   BRANCH COVERAGE: POST-FLIGHT CHECKS
    //////////////////////////////////////////////////////////////*/

    function test_PostFlight_RegistryHandoverFailed() public {
        _executeDeployments();
        _testRevertBranch(
            registryAddr,
            abi.encodeWithSignature("owner()"),
            abi.encode(address(0)),
            "PostFlight: Registry handover failed",
            false
        );
    }

    function test_PostFlight_YieldVaultHandoverFailed() public {
        _executeDeployments();
        _testRevertBranch(
            yieldVaultAddr,
            abi.encodeWithSignature("owner()"),
            abi.encode(address(0)),
            "PostFlight: YieldVault handover failed",
            false
        );
    }

    function test_PostFlight_OpVaultHandoverFailed() public {
        _executeDeployments();
        _testRevertBranch(
            opVaultAddr,
            abi.encodeWithSignature("owner()"),
            abi.encode(address(0)),
            "PostFlight: OpVault handover failed",
            false
        );
    }

    function test_PostFlight_DeployerGodMode() public {
        _executeDeployments();
        bytes32 DEFAULT_ADMIN_ROLE = 0x00;
        _testRevertBranch(
            timelockAddr,
            abi.encodeWithSignature("hasRole(bytes32,address)", DEFAULT_ADMIN_ROLE, deployer),
            abi.encode(true),
            "PostFlight: Deployer God Mode!",
            false
        );
    }

    function test_PostFlight_DeployerRetainsCanceller() public {
        _executeDeployments();
        TimelockController tl = TimelockController(payable(timelockAddr));
        _testRevertBranch(
            timelockAddr,
            abi.encodeWithSignature("hasRole(bytes32,address)", tl.CANCELLER_ROLE(), deployer),
            abi.encode(true),
            "PostFlight: Deployer Canceller",
            false
        );
    }

    function test_PostFlight_DelayUpdateFailed() public {
        _executeDeployments();
        _testRevertBranch(
            timelockAddr,
            abi.encodeWithSignature("getMinDelay()"),
            abi.encode(uint256(0)),
            "PostFlight: Delay update failed",
            false
        );
    }
}
