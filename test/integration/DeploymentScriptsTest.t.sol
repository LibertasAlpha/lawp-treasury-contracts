// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { MockCngn3, MockAdminOperations } from "../mocks/MockCngn3.sol";

import { DeployLAWPSystem } from "../../script/Deploy.s.sol";
import { ConfigureLAWPSystem } from "../../script/Configure.s.sol";

import { LAWPComplianceEngine } from "../../src/core/LAWPComplianceEngine.sol";
import { LAWPYieldVault } from "../../src/core/LAWPYieldVault.sol";
import { LAWPOperationalVault } from "../../src/core/LAWPOperationalVault.sol";
import { LAWPImpactToken } from "../../src/core/LAWPImpactToken.sol";
import { LAWPActorRegistry } from "../../src/core/LAWPActorRegistry.sol";
import { LAWPMultiSigController } from "../../src/core/LAWPMultiSigController.sol";

/// @title DeploymentScriptsTest
/// @notice Full branch + line + function coverage for Deploy.s.sol and Configure.s.sol
contract DeploymentScriptsTest is Test {
    DeployLAWPSystem internal deployScript;
    ConfigureLAWPSystem internal configureScript;

    // ----------------------------
    // Actors
    // ----------------------------
    uint256 internal constant DEPLOYER_PRIVATE_KEY = 0xA11CE;
    address internal deployer;
    uint256 internal constant ADMIN_SAFE_PRIVATE_KEY = 0xB0B;
    address internal adminSafe;

    // ----------------------------
    // Deployed contract addresses
    // ----------------------------
    address internal registryAddress;
    address internal yieldVaultAddress;
    address internal operationalVaultAddress;
    address internal impactTokenAddress;
    address internal engineAddress;
    address internal multiSigAddress;

    // ----------------------------
    // Setup
    // ----------------------------
    function setUp() public {
        deployer = vm.addr(DEPLOYER_PRIVATE_KEY);
        adminSafe = vm.addr(ADMIN_SAFE_PRIVATE_KEY);

        deployScript = new DeployLAWPSystem();
        configureScript = new ConfigureLAWPSystem();

        _configureEnvironment();
    }

    function _configureEnvironment() internal {
        vm.setEnv("DEPLOYER_PRIVATE_KEY", vm.toString(DEPLOYER_PRIVATE_KEY));
        vm.setEnv("BASE_URI", "ipfs://lawp-test/");

        vm.setEnv("ADMIN_SAFE_PRIVATE_KEY", vm.toString(ADMIN_SAFE_PRIVATE_KEY));

        // Deploy a mock cNGN so the deploy script can read CNGN_TOKEN_ADDRESS.
        MockAdminOperations adminOps = new MockAdminOperations();
        MockCngn3 cngnMock = new MockCngn3(address(adminOps));
        vm.setEnv("CNGN_TOKEN_ADDRESS", vm.toString(address(cngnMock)));

        vm.setEnv("BOARD_SIGNER_1", vm.toString(address(0x11)));
        vm.setEnv("BOARD_SIGNER_2", vm.toString(address(0x12)));
        vm.setEnv("BOARD_SIGNER_3", vm.toString(address(0x13)));
        vm.setEnv("BOARD_SIGNER_4", vm.toString(address(0x14)));
        vm.setEnv("BOARD_SIGNER_5", vm.toString(address(0x15)));

        vm.setEnv("LA2_WALLET", vm.toString(address(0xAA)));
        vm.setEnv("MVI1_WALLET", vm.toString(address(0xBB)));
        vm.setEnv("OPERATIONAL_TREASURY_WALLET", vm.toString(address(0xCC)));
        vm.setEnv("DEV_WALLET", vm.toString(address(0xDD)));
    }

    // ------------------------------------------------------------
    // Deployment execution + deterministic address capture
    // ------------------------------------------------------------
    function _deploySystem() internal {
        uint256 deployNonce = vm.getNonce(deployer);

        deployScript.run();

        registryAddress = vm.computeCreateAddress(deployer, deployNonce);
        yieldVaultAddress = vm.computeCreateAddress(deployer, deployNonce + 1);
        operationalVaultAddress = vm.computeCreateAddress(deployer, deployNonce + 2);
        impactTokenAddress = vm.computeCreateAddress(deployer, deployNonce + 3);
        engineAddress = vm.computeCreateAddress(deployer, deployNonce + 4);
        multiSigAddress = vm.computeCreateAddress(deployer, deployNonce + 5);

        vm.setEnv("ENGINE_ADDRESS", vm.toString(engineAddress));
        vm.setEnv("YIELD_VAULT_ADDRESS", vm.toString(yieldVaultAddress));
        vm.setEnv("OP_VAULT_ADDRESS", vm.toString(operationalVaultAddress));
        vm.setEnv("TOKEN_ADDRESS", vm.toString(impactTokenAddress));
        vm.setEnv("REGISTRY_ADDRESS", vm.toString(registryAddress));
        vm.setEnv("MULTISIG_ADDRESS", vm.toString(multiSigAddress));
    }

    // ============================================================
    // HAPPY PATH
    // ============================================================
    function test_HappyPath_FullDeploymentAndConfiguration() public {
        _deploySystem();
        configureScript.run();

        // ----------------------------
        // Post-configuration ownership (Configure.s.sol completes the full
        // Ownable2Step handover: transferOwnership + acceptOwnership).
        // ----------------------------
        assertEq(LAWPActorRegistry(registryAddress).owner(), adminSafe);
        assertEq(LAWPYieldVault(yieldVaultAddress).owner(), adminSafe);
        assertEq(LAWPOperationalVault(operationalVaultAddress).owner(), adminSafe);
        assertEq(LAWPImpactToken(impactTokenAddress).owner(), adminSafe);
        assertEq(LAWPComplianceEngine(engineAddress).owner(), adminSafe);
        assertEq(LAWPMultiSigController(multiSigAddress).owner(), adminSafe);

        // ----------------------------
        // Wiring validation
        // ----------------------------
        LAWPComplianceEngine engine = LAWPComplianceEngine(engineAddress);

        assertEq(address(engine.yieldVault()), yieldVaultAddress);
        assertEq(address(engine.operationalVault()), operationalVaultAddress);
        assertEq(engine.multiSigController(), multiSigAddress);

        assertEq(LAWPYieldVault(yieldVaultAddress).complianceEngine(), engineAddress);
        assertEq(LAWPOperationalVault(operationalVaultAddress).complianceEngine(), engineAddress);
        assertEq(LAWPImpactToken(impactTokenAddress).complianceEngine(), engineAddress);

        // ----------------------------
        // Registry correctness
        // ----------------------------
        assertEq(LAWPActorRegistry(registryAddress).la2Wallet(), address(0xAA));
        assertEq(LAWPActorRegistry(registryAddress).mvi1Wallet(), address(0xBB));
        assertEq(LAWPActorRegistry(registryAddress).operationalTreasuryWallet(), address(0xCC));
        assertEq(LAWPActorRegistry(registryAddress).devWallet(), address(0xDD));
    }

    // ============================================================
    // PRE-FLIGHT FAILURE BRANCHES
    // ============================================================
    function _expectPreFlightFailure(address mockedContract) internal {
        vm.mockCall(
            mockedContract, abi.encodeWithSignature("pendingOwner()"), abi.encode(address(0))
        );

        vm.expectRevert();
        configureScript.run();

        vm.clearMockedCalls();
    }

    function test_PreFlight_RegistryMismatch() public {
        _deploySystem();
        _expectPreFlightFailure(registryAddress);
    }

    function test_PreFlight_YieldVaultMismatch() public {
        _deploySystem();
        _expectPreFlightFailure(yieldVaultAddress);
    }

    function test_PreFlight_OpVaultMismatch() public {
        _deploySystem();
        _expectPreFlightFailure(operationalVaultAddress);
    }

    function test_PreFlight_TokenMismatch() public {
        _deploySystem();
        _expectPreFlightFailure(impactTokenAddress);
    }

    function test_PreFlight_EngineMismatch() public {
        _deploySystem();
        _expectPreFlightFailure(engineAddress);
    }

    function test_PreFlight_MultiSigMismatch() public {
        _deploySystem();
        _expectPreFlightFailure(multiSigAddress);
    }

    // ============================================================
    // POST-FLIGHT FAILURE BRANCHES
    // ============================================================
    function _expectPostFlightFailure(
        address target,
        bytes memory callData,
        bytes memory returnData,
        string memory expectedRevert
    ) internal {
        vm.mockCall(target, callData, returnData);

        vm.expectRevert(bytes(expectedRevert));
        configureScript.run();

        vm.clearMockedCalls();
    }

    function test_PostFlight_EngineYieldVaultMismatch() public {
        _deploySystem();

        _expectPostFlightFailure(
            engineAddress,
            abi.encodeWithSignature("yieldVault()"),
            abi.encode(address(0)),
            "Integrity: YieldVault mismatch"
        );
    }

    function test_PostFlight_EngineOpVaultMismatch() public {
        _deploySystem();

        _expectPostFlightFailure(
            engineAddress,
            abi.encodeWithSignature("operationalVault()"),
            abi.encode(address(0)),
            "Integrity: OperationalVault mismatch"
        );
    }

    function test_PostFlight_EngineMultiSigMismatch() public {
        _deploySystem();

        _expectPostFlightFailure(
            engineAddress,
            abi.encodeWithSignature("multiSigController()"),
            abi.encode(address(0)),
            "Integrity: MultiSig mismatch"
        );
    }
}
