// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Script, console2 } from "forge-std/Script.sol";

import { LAWPComplianceEngine } from "../src/core/LAWPComplianceEngine.sol";
import { LAWPYieldVault } from "../src/core/LAWPYieldVault.sol";
import { LAWPOperationalVault } from "../src/core/LAWPOperationalVault.sol";
import { LAWPImpactToken } from "../src/core/LAWPImpactToken.sol";
import { LAWPActorRegistry } from "../src/core/LAWPActorRegistry.sol";
import { LAWPMultiSigController } from "../src/core/LAWPMultiSigController.sol";

/// @title LAWP System Deployment Script
/// @notice Deploys immutable system bytecode and foundational contracts
/// @dev This script ONLY deploys. No wiring, no ownership finalization.
contract DeployLAWPSystem is Script {
    /*//////////////////////////////////////////////////////////////
                            CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    uint256 public constant INITIAL_RISK_FEE_BPS = 1000; // 10%
    uint256 public constant MULTISIG_THRESHOLD = 3;
    uint256 public constant MULTISIG_BOARD_SIZE = 5;

    /*//////////////////////////////////////////////////////////////
                        DEPLOYMENT ENTRYPOINT
    //////////////////////////////////////////////////////////////*/

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployerAddress = vm.addr(deployerPrivateKey);

        address cNGNTokenAddress = vm.envAddress("CNGN_TOKEN_ADDRESS");
        string memory tokenMetadataBaseURI = vm.envString("BASE_URI");

        console2.log("=== LAWP SYSTEM DEPLOYMENT STARTED ===");
        console2.log("Deployer:", deployerAddress);

        vm.startBroadcast(deployerPrivateKey);

        /*//////////////////////////////////////////////////////////////
                            CORE INFRASTRUCTURE
        //////////////////////////////////////////////////////////////*/

        LAWPActorRegistry actorRegistry = new LAWPActorRegistry(deployerAddress);

        console2.log("ActorRegistry deployed at:", address(actorRegistry));

        /*//////////////////////////////////////////////////////////////
                                VAULTS
        //////////////////////////////////////////////////////////////*/

        LAWPYieldVault investorVault = new LAWPYieldVault(cNGNTokenAddress, deployerAddress);

        LAWPOperationalVault operationalVault =
            new LAWPOperationalVault(cNGNTokenAddress, deployerAddress);

        console2.log("YieldVault deployed at:", address(investorVault));
        console2.log("OperationalVault deployed at:", address(operationalVault));

        /*//////////////////////////////////////////////////////////////
                                TOKEN
        //////////////////////////////////////////////////////////////*/

        LAWPImpactToken impactToken = new LAWPImpactToken(deployerAddress, tokenMetadataBaseURI);

        console2.log("ImpactToken deployed at:", address(impactToken));

        /*//////////////////////////////////////////////////////////////
                            COMPLIANCE ENGINE
        //////////////////////////////////////////////////////////////*/

        LAWPComplianceEngine complianceEngine = new LAWPComplianceEngine(
            deployerAddress,
            address(investorVault),
            address(operationalVault),
            address(impactToken),
            address(actorRegistry),
            cNGNTokenAddress,
            INITIAL_RISK_FEE_BPS
        );

        console2.log("ComplianceEngine deployed at:", address(complianceEngine));

        /*//////////////////////////////////////////////////////////////
                            MULTISIG CONTROLLER
        //////////////////////////////////////////////////////////////*/

        address[] memory boardMembers = new address[](MULTISIG_BOARD_SIZE);

        boardMembers[0] = vm.envAddress("BOARD_SIGNER_1");
        boardMembers[1] = vm.envAddress("BOARD_SIGNER_2");
        boardMembers[2] = vm.envAddress("BOARD_SIGNER_3");
        boardMembers[3] = vm.envAddress("BOARD_SIGNER_4");
        boardMembers[4] = vm.envAddress("BOARD_SIGNER_5");

        LAWPMultiSigController multiSigController = new LAWPMultiSigController(
            deployerAddress, address(complianceEngine), boardMembers, MULTISIG_THRESHOLD
        );

        console2.log("MultiSigController deployed at:", address(multiSigController));

        vm.stopBroadcast();

        console2.log("=== DEPLOYMENT COMPLETE (NO CONFIGURATION APPLIED) ===");
    }
}
