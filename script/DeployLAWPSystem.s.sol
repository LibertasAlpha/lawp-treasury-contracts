// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {LAWPComplianceEngine} from "../src/core/LAWPComplianceEngine.sol";
import {LAWPContributionPool} from "../src/core/LAWPContributionPool.sol";
import {LAWPImpactToken} from "../src/core/LAWPImpactToken.sol";
import {LAWPMultiSigController} from "../src/core/LAWPMultiSigController.sol";
import {LAWPOperationalVault} from "../src/core/LAWPOperationalVault.sol";
import {LAWPYieldVault} from "../src/core/LAWPYieldVault.sol";
import {MockCNGN} from "../test/mocks/MockCNGN.sol";

contract DeployLAWPSystem is Script {
    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;

    function run()
        public
        returns (
            LAWPComplianceEngine engine,
            LAWPMultiSigController multisig,
            LAWPContributionPool pool,
            LAWPImpactToken impactToken,
            LAWPYieldVault yieldVault,
            LAWPOperationalVault operationalVault
        )
    {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        require(vm.envAddress("ADMIN_ADDRESS") != address(0), "Final admin cannot be zero");

        // 1. Resolve or deploy cNGN Token
        address cNgnAddress = vm.envOr("CNGN_TOKEN_ADDRESS", address(0));

        uint256 currentChainId = block.chainid;
        // If mainnet (Base=8453, Eth=1, Polygon=137), revert if mock is needed.
        if (currentChainId == 1 || currentChainId == 137 || currentChainId == 8453) {
            require(cNgnAddress != address(0), "Cannot deploy MockCNGN on Mainnet!");
        }

        vm.startBroadcast(deployerPrivateKey);

        if (cNgnAddress == address(0)) {
            MockCNGN mockNgn = new MockCNGN();
            cNgnAddress = address(mockNgn);
            console.log("Deployed MockCNGN at:", cNgnAddress);
        } else {
            console.log("Using existing cNGN Token at:", cNgnAddress);
        }

        // 2. Deploy Vaults and Impact Token
        yieldVault = new LAWPYieldVault(cNgnAddress);
        console.log("Deployed LAWPYieldVault at:", address(yieldVault));

        operationalVault = new LAWPOperationalVault(cNgnAddress);
        console.log("Deployed LAWPOperationalVault at:", address(operationalVault));

        string memory baseUri = vm.envOr("IMPACT_TOKEN_BASE_URI", string("ipfs://lawp-impact/"));
        impactToken = new LAWPImpactToken(baseUri);
        console.log("Deployed LAWPImpactToken at:", address(impactToken));

        // 3. Deploy Compliance Engine (Deployer is initial admin)
        engine = new LAWPComplianceEngine(
            deployer,
            address(yieldVault),
            address(operationalVault),
            address(impactToken),
            cNgnAddress,
            1000 // Initial Risk Fee BPS (10%)
        );
        console.log("Deployed LAWPComplianceEngine at:", address(engine));

        // 4. Deploy Pool and MultiSig Controller
        pool = new LAWPContributionPool(cNgnAddress, address(engine));
        console.log("Deployed LAWPContributionPool at:", address(pool));

        multisig = new LAWPMultiSigController(address(engine), vm.envOr("MULTISIG_THRESHOLD", uint256(3)));
        console.log("Deployed LAWPMultiSigController at:", address(multisig));

        // 5. Lock in Compliance Engine References
        yieldVault.setComplianceEngine(address(engine));
        operationalVault.setComplianceEngine(address(engine));
        impactToken.setComplianceEngine(address(engine));

        // 6. Configure Wallets
        engine.setLA2Wallet(vm.envAddress("LA2_WALLET"));
        engine.setMVI1Wallet(vm.envAddress("MVI1_WALLET"));
        engine.setDevWallet(vm.envAddress("DEV_WALLET"));
        engine.setOperationalTreasuryWallet(vm.envAddress("OP_TREASURY_WALLET"));

        // 7. Grant Roles to Contracts & Actors
        engine.grantRole(engine.CAMPAIGN_MANAGER_ROLE(), vm.envAddress("CAMPAIGN_MANAGER"));
        engine.grantRole(engine.CAMPAIGN_MANAGER_ROLE(), address(pool));

        // Note: In this architecture, there is only CAMPAIGN_MANAGER_ROLE.
        // It manages both the pool creation and pool settlement.
        engine.grantRole(engine.OPERATOR_ROLE(), address(multisig));

        address[] memory signers = vm.envAddress("SIGNERS", ",");
        for (uint256 i = 0; i < signers.length; i++) {
            engine.grantRole(engine.SIGNER_ROLE(), signers[i]);
            console.log("Granted SIGNER_ROLE to:", signers[i]);
        }

        // 8. Ownership Handover
        engine.grantRole(engine.GOVERNANCE_ROLE(), vm.envAddress("ADMIN_ADDRESS"));
        engine.grantRole(DEFAULT_ADMIN_ROLE, vm.envAddress("ADMIN_ADDRESS"));

        // Revoke deployer roles
        engine.revokeRole(engine.GOVERNANCE_ROLE(), deployer);
        engine.revokeRole(DEFAULT_ADMIN_ROLE, deployer);

        console.log("Ownership successfully handed over to:", vm.envAddress("ADMIN_ADDRESS"));

        vm.stopBroadcast();
    }
}
