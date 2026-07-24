// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Script, console2 } from "forge-std/Script.sol";

import { MockCNGN } from "../test/mocks/MockCNGN.sol";

import { LAWPComplianceEngine } from "../src/core/LAWPComplianceEngine.sol";
import { LAWPYieldVault } from "../src/core/LAWPYieldVault.sol";
import { LAWPOperationalVault } from "../src/core/LAWPOperationalVault.sol";
import { LAWPImpactToken } from "../src/core/LAWPImpactToken.sol";
import { LAWPActorRegistry } from "../src/core/LAWPActorRegistry.sol";
import { LAWPMultiSigController } from "../src/core/LAWPMultiSigController.sol";
import { LAWPContributionPool } from "../src/core/LAWPContributionPool.sol";

contract DeployLocal is Script {
    uint256 internal constant INITIAL_RISK_FEE_BPS = 1000;
    uint256 internal constant MULTISIG_THRESHOLD = 3;
    uint256 internal constant MULTISIG_BOARD_SIZE = 5;

    function run() external {
        // Read Anvil private key from environment
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console2.log("=== LAWP LOCAL DEPLOYMENT STARTED ===");
        console2.log("Deployer:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        // ---------------------------------------------------------------------
        // Mock Stablecoin
        // ---------------------------------------------------------------------

        MockCNGN cNGN = new MockCNGN();
        cNGN.mint(deployer, 10_000_000 ether);

        console2.log("MockCNGN:", address(cNGN));

        // ---------------------------------------------------------------------
        // Core Contracts
        // ---------------------------------------------------------------------

        LAWPActorRegistry actorRegistry = new LAWPActorRegistry(deployer);

        LAWPYieldVault yieldVault = new LAWPYieldVault(address(cNGN), deployer);

        LAWPOperationalVault operationalVault = new LAWPOperationalVault(address(cNGN), deployer);

        LAWPImpactToken impactToken = new LAWPImpactToken(deployer, "ipfs://Qm...");

        LAWPComplianceEngine complianceEngine = new LAWPComplianceEngine(
            deployer,
            address(yieldVault),
            address(operationalVault),
            address(impactToken),
            address(actorRegistry),
            address(cNGN),
            INITIAL_RISK_FEE_BPS
        );

        // ---------------------------------------------------------------------
        // Multisig
        // ---------------------------------------------------------------------

        address[] memory boardMembers = new address[](MULTISIG_BOARD_SIZE);

        boardMembers[0] = vm.envAddress("BOARD_SIGNER_1");
        boardMembers[1] = vm.envAddress("BOARD_SIGNER_2");
        boardMembers[2] = vm.envAddress("BOARD_SIGNER_3");
        boardMembers[3] = vm.envAddress("BOARD_SIGNER_4");
        boardMembers[4] = vm.envAddress("BOARD_SIGNER_5");

        LAWPMultiSigController multiSig = new LAWPMultiSigController(
            deployer, address(complianceEngine), boardMembers, MULTISIG_THRESHOLD
        );

        // ---------------------------------------------------------------------
        // Contribution Pool
        // ---------------------------------------------------------------------

        LAWPContributionPool contributionPool = new LAWPContributionPool(address(cNGN), deployer);

        vm.stopBroadcast();

        console2.log("");
        console2.log("=========== Deployment Complete ===========");
        console2.log("MockCNGN           :", address(cNGN));
        console2.log("ActorRegistry      :", address(actorRegistry));
        console2.log("YieldVault         :", address(yieldVault));
        console2.log("OperationalVault   :", address(operationalVault));
        console2.log("ImpactToken        :", address(impactToken));
        console2.log("ComplianceEngine   :", address(complianceEngine));
        console2.log("MultiSigController :", address(multiSig));
        console2.log("ContributionPool   :", address(contributionPool));
        console2.log("===========================================");
    }
}
