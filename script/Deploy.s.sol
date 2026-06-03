// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console2 } from "forge-std/Script.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { LAWPComplianceEngine } from "../src/core/LAWPComplianceEngine.sol";
import { LAWPYieldVault } from "../src/core/LAWPYieldVault.sol";
import { LAWPOperationalVault } from "../src/core/LAWPOperationalVault.sol";
import { LAWPImpactToken } from "../src/core/LAWPImpactToken.sol";
import { LAWPActorRegistry } from "../src/core/LAWPActorRegistry.sol";
import { LAWPMultiSigController } from "../src/core/LAWPMultiSigController.sol";

/// @title LAWP Deployment Script
/// @author Obinna Franklin Duru (BinnaDev)
/// @notice Deploys bare bytecodes to the network. Configuration handled by Configure.s.sol.
/// @dev Dual-vault architecture: LAWPYieldVault holds investor capital, LAWPOperationalVault
///      holds risk fees and operational splits.
contract Deploy is Script {
    uint256 public constant INITIAL_TIMELOCK_DELAY = 0;
    uint256 public constant INITIAL_RISK_FEE_BPS = 1000; // 10%
    uint256 public constant BOARD_SIZE = 5;
    uint256 public constant MULTISIG_THRESHOLD = 3;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address cngnToken = vm.envAddress("CNGN_TOKEN_ADDRESS");
        string memory baseURI = vm.envString("BASE_URI");

        console2.log("Starting LAWP Deployment from:", deployer);
        vm.startBroadcast(deployerPrivateKey);

        // // 1. Timelock (0-delay for atomic setup)
        // address[] memory proposers = new address[](1);
        // proposers[0] = deployer;
        // address[] memory executors = new address[](1);
        // executors[0] = deployer;
        // TimelockController timelock =
        //     new TimelockController(INITIAL_TIMELOCK_DELAY, proposers, executors, deployer);
        // console2.log("TimelockController:", address(timelock));

        // // 2. Core dependencies (temporarily owned by deployer)
        // LAWPActorRegistry registry = new LAWPActorRegistry(deployer);
        // console2.log("LAWPActorRegistry:", address(registry));

        // 3. Dual vaults - only these two contracts ever hold protocol cNGN
        LAWPYieldVault yieldVault = new LAWPYieldVault(cngnToken, deployer);
        console2.log("LAWPYieldVault:", address(yieldVault));

        LAWPOperationalVault operationalVault = new LAWPOperationalVault(cngnToken, deployer);
        console2.log("LAWPOperationalVault:", address(operationalVault));

        // LAWPImpactToken impactToken = new LAWPImpactToken(deployer, baseURI);
        // console2.log("LAWPImpactToken:", address(impactToken));

        address impactToken = address(LAWPImpactToken(0x9b6ead83f73963a943073d47a8768578dc885596));
        address registry = address(LAWPActorRegistry(0x62b58e143caf914db57532ff05b5dba47b9fa233));

        // 4. Compliance Engine
        LAWPComplianceEngine engine = new LAWPComplianceEngine(
            deployer,
            address(yieldVault),
            address(operationalVault),
            address(impactToken),
            address(registry),
            cngnToken,
            INITIAL_RISK_FEE_BPS
        );
        console2.log("LAWPComplianceEngine:", address(engine));

        // // 5. Multi-Sig Controller
        // address[] memory initialBoard = new address[](BOARD_SIZE);
        // initialBoard[0] = vm.envAddress("BOARD_SIGNER_1");
        // initialBoard[1] = vm.envAddress("BOARD_SIGNER_2");
        // initialBoard[2] = vm.envAddress("BOARD_SIGNER_3");
        // initialBoard[3] = vm.envAddress("BOARD_SIGNER_4");
        // initialBoard[4] = vm.envAddress("BOARD_SIGNER_5");

        // LAWPMultiSigController multiSig = new LAWPMultiSigController(
        //     deployer, address(engine), initialBoard, MULTISIG_THRESHOLD
        // );
        // console2.log("LAWPMultiSigController:", address(multiSig));

        vm.stopBroadcast();
        console2.log("Deployment complete. Run Configure.s.sol next.");
    }
}
