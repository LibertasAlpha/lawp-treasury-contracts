// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console2 } from "forge-std/Script.sol";

import { LAWPComplianceEngine } from "../src/core/LAWPComplianceEngine.sol";
import { LAWPYieldVault } from "../src/core/LAWPYieldVault.sol";
import { LAWPOperationalVault } from "../src/core/LAWPOperationalVault.sol";
import { LAWPImpactToken } from "../src/core/LAWPImpactToken.sol";
import { LAWPActorRegistry } from "../src/core/LAWPActorRegistry.sol";
import { LAWPMultiSigController } from "../src/core/LAWPMultiSigController.sol";

/// @title LAWP System Configuration Script
/// @notice Wires all trust boundaries and initiates ownership transfer
/// @dev Must be executed AFTER Deploy.s.sol
contract ConfigureLAWPSystem is Script {
    /*//////////////////////////////////////////////////////////////
                        CONTRACT REFERENCES
    //////////////////////////////////////////////////////////////*/

    LAWPComplianceEngine internal complianceEngine;
    LAWPYieldVault internal yieldVault;
    LAWPOperationalVault internal operationalVault;
    LAWPImpactToken internal impactToken;
    LAWPActorRegistry internal actorRegistry;
    LAWPMultiSigController internal multiSigController;

    address internal adminSafeAddress;
    address internal deployerAddress;

    /*//////////////////////////////////////////////////////////////
                            ENTRYPOINT
    //////////////////////////////////////////////////////////////*/

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        deployerAddress = vm.addr(deployerPrivateKey);

        uint256 adminSafePrivateKey = vm.envUint("ADMIN_SAFE_PRIVATE_KEY");
        adminSafeAddress = vm.addr(adminSafePrivateKey);

        _loadContractAddresses();

        vm.startBroadcast(deployerPrivateKey);

        _configureActorRegistry();
        _wireSystemDependencies();
        _initiateOwnershipTransfer();
        _validatePendingOwnership();

        vm.stopBroadcast();

        _finalVerification();
    }

    /*//////////////////////////////////////////////////////////////
                            LOAD STATE
    //////////////////////////////////////////////////////////////*/

    function _loadContractAddresses() internal {
        complianceEngine = LAWPComplianceEngine(vm.envAddress("ENGINE_ADDRESS"));

        yieldVault = LAWPYieldVault(vm.envAddress("YIELD_VAULT_ADDRESS"));

        operationalVault = LAWPOperationalVault(vm.envAddress("OP_VAULT_ADDRESS"));

        impactToken = LAWPImpactToken(vm.envAddress("TOKEN_ADDRESS"));

        actorRegistry = LAWPActorRegistry(vm.envAddress("REGISTRY_ADDRESS"));

        multiSigController = LAWPMultiSigController(vm.envAddress("MULTISIG_ADDRESS"));
    }

    /*//////////////////////////////////////////////////////////////
                        REGISTRY CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    function _configureActorRegistry() internal {
        actorRegistry.setLA2Wallet(vm.envAddress("LA2_WALLET"));
        actorRegistry.setMVI1Wallet(vm.envAddress("MVI1_WALLET"));
        actorRegistry.setRiskPoolWallet(vm.envAddress("RISK_POOL_WALLET"));
        actorRegistry.setDevWallet(vm.envAddress("DEV_WALLET"));
    }

    /*//////////////////////////////////////////////////////////////
                        TRUST BOUNDARY WIRING
    //////////////////////////////////////////////////////////////*/

    function _wireSystemDependencies() internal {
        complianceEngine.setMultiSigController(address(multiSigController));

        yieldVault.setComplianceEngine(address(complianceEngine));
        operationalVault.setComplianceEngine(address(complianceEngine));
        impactToken.setComplianceEngine(address(complianceEngine));
    }

    /*//////////////////////////////////////////////////////////////
                        OWNERSHIP HANDOVER
    //////////////////////////////////////////////////////////////*/

    function _initiateOwnershipTransfer() internal {
        actorRegistry.transferOwnership(adminSafeAddress);
        yieldVault.transferOwnership(adminSafeAddress);
        operationalVault.transferOwnership(adminSafeAddress);
        impactToken.transferOwnership(adminSafeAddress);
        complianceEngine.transferOwnership(adminSafeAddress);
        multiSigController.transferOwnership(adminSafeAddress);
    }

    function _validatePendingOwnership() internal view {
        require(actorRegistry.pendingOwner() == adminSafeAddress);
        require(yieldVault.pendingOwner() == adminSafeAddress);
        require(operationalVault.pendingOwner() == adminSafeAddress);
        require(impactToken.pendingOwner() == adminSafeAddress);
        require(complianceEngine.pendingOwner() == adminSafeAddress);
        require(multiSigController.pendingOwner() == adminSafeAddress);
    }

    /*//////////////////////////////////////////////////////////////
                        FINAL OWNERSHIP ACCEPTANCE
    //////////////////////////////////////////////////////////////*/

    function _finalVerification() internal {
        vm.startPrank(adminSafeAddress);

        actorRegistry.acceptOwnership();
        yieldVault.acceptOwnership();
        operationalVault.acceptOwnership();
        impactToken.acceptOwnership();
        complianceEngine.acceptOwnership();
        multiSigController.acceptOwnership();

        vm.stopPrank();

        _assertSystemIntegrity();
    }

    /*//////////////////////////////////////////////////////////////
                        SYSTEM INTEGRITY CHECK
    //////////////////////////////////////////////////////////////*/

    function _assertSystemIntegrity() internal view {
        require(
            address(complianceEngine.yieldVault()) == address(yieldVault),
            "Integrity: YieldVault mismatch"
        );

        require(
            address(complianceEngine.operationalVault()) == address(operationalVault),
            "Integrity: OperationalVault mismatch"
        );

        require(
            complianceEngine.multiSigController() == address(multiSigController),
            "Integrity: MultiSig mismatch"
        );

        require(
            yieldVault.complianceEngine() == address(complianceEngine),
            "Integrity: YieldVault engine mismatch"
        );

        require(
            operationalVault.complianceEngine() == address(complianceEngine),
            "Integrity: OperationalVault engine mismatch"
        );

        require(
            impactToken.complianceEngine() == address(complianceEngine),
            "Integrity: ImpactToken engine mismatch"
        );

        console2.log("=== SYSTEM CONFIGURATION COMPLETE ===");
        console2.log("All trust boundaries verified and ownership transferred.");
    }
}
