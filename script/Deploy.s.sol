// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console2 } from "forge-std/Script.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { LAWPComplianceEngine } from "../src/core/LAWPComplianceEngine.sol";
import { LAWPTreasury } from "../src/core/LAWPTreasury.sol";
import { LAWPImpactToken } from "../src/core/LAWPImpactToken.sol";
import { LAWPActorRegistry } from "../src/core/LAWPActorRegistry.sol";
import { LAWPMultiSigController } from "../src/core/LAWPMultiSigController.sol";

/// @title LAWP Deployment Script
/// @author Obinna Franklin Duru (BinnaDev)
/// @notice Deploys the bare bytecodes to the network. Configuration is handled separately.
contract Deploy is Script {
    /*//////////////////////////////////////////////////////////////
                       CONFIGURATION CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Initial delay set to 0 to allow atomic Ownable2Step configuration in Configure.s.sol.
    /// @dev This will be updated to 2 days by the Timelock itself during the final handover.
    uint256 public constant INITIAL_TIMELOCK_DELAY = 0;

    /// @notice The initial Systemic Risk Fee deducted from gross deposits in Basis Points.
    uint256 public constant INITIAL_RISK_FEE_BPS = 1000; // 10%

    /// @notice The number of authorized signers initialized on the Multi-Sig Board.
    uint256 public constant BOARD_SIZE = 5;

    /// @notice The minimum number of valid signatures required to route off-chain revenue.
    uint256 public constant MULTISIG_THRESHOLD = 3;

    /*//////////////////////////////////////////////////////////////
                           EXECUTION LOGIC
    //////////////////////////////////////////////////////////////*/

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        // Environment Variables
        address cngnToken = vm.envAddress("CNGN_TOKEN_ADDRESS");
        string memory baseURI = vm.envString("BASE_URI");

        console2.log("Starting LAWP Deployment from:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy Timelock (0 delay for atomic setup)
        // Deployer temporarily receives Proposer, Executor, and Admin roles.
        address[] memory proposers = new address[](1);
        proposers[0] = deployer;
        address[] memory executors = new address[](1);
        executors[0] = deployer;

        TimelockController timelock =
            new TimelockController(INITIAL_TIMELOCK_DELAY, proposers, executors, deployer);
        console2.log("TimelockController deployed at:", address(timelock));

        // 2. Deploy Core Dependencies (Owned temporarily by Deployer)
        LAWPActorRegistry registry = new LAWPActorRegistry(deployer);
        console2.log("LAWPActorRegistry deployed at:", address(registry));

        LAWPTreasury treasury = new LAWPTreasury(cngnToken, deployer);
        console2.log("LAWPTreasury deployed at:", address(treasury));

        LAWPImpactToken impactToken = new LAWPImpactToken(deployer, baseURI);
        console2.log("LAWPImpactToken deployed at:", address(impactToken));

        // 3. Deploy Engine (Using named constant for Risk Fee)
        LAWPComplianceEngine engine = new LAWPComplianceEngine(
            deployer,
            address(treasury),
            address(impactToken),
            address(registry),
            cngnToken,
            INITIAL_RISK_FEE_BPS
        );
        console2.log("LAWPComplianceEngine deployed at:", address(engine));

        // 4. Deploy Operational Multi-Sig (Revenue Verification)
        address[] memory initialBoard = new address[](BOARD_SIZE);
        initialBoard[0] = vm.envAddress("BOARD_SIGNER_1");
        initialBoard[1] = vm.envAddress("BOARD_SIGNER_2");
        initialBoard[2] = vm.envAddress("BOARD_SIGNER_3");
        initialBoard[3] = vm.envAddress("BOARD_SIGNER_4");
        initialBoard[4] = vm.envAddress("BOARD_SIGNER_5");

        LAWPMultiSigController multiSig = new LAWPMultiSigController(
            deployer, address(engine), initialBoard, MULTISIG_THRESHOLD
        );
        console2.log("LAWPMultiSigController deployed at:", address(multiSig));

        vm.stopBroadcast();
        console2.log("Deployment Phase Complete. Proceed to Configure.s.sol.");
    }
}
