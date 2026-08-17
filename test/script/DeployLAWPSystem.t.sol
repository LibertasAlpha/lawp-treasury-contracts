// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {DeployLAWPSystem} from "../../script/DeployLAWPSystem.s.sol";
import {LAWPComplianceEngine} from "../../src/core/LAWPComplianceEngine.sol";
import {LAWPMultiSigController} from "../../src/core/LAWPMultiSigController.sol";
import {LAWPContributionPool} from "../../src/core/LAWPContributionPool.sol";
import {LAWPImpactToken} from "../../src/core/LAWPImpactToken.sol";
import {LAWPYieldVault} from "../../src/core/LAWPYieldVault.sol";
import {LAWPOperationalVault} from "../../src/core/LAWPOperationalVault.sol";

contract DeployLAWPSystemTest is Test {
    DeployLAWPSystem deployer;

    function setUp() public {
        deployer = new DeployLAWPSystem();

        // Set environment variables required for the deploy script
        vm.setEnv("PRIVATE_KEY", "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"); // Anvil default account 0
        vm.setEnv("ADMIN_ADDRESS", "0x0000000000000000000000000000000000001111");
        vm.setEnv("CNGN_TOKEN_ADDRESS", ""); // Empty implies mock
        vm.setEnv("MULTISIG_THRESHOLD", "3");
        vm.setEnv("LA2_WALLET", "0x0000000000000000000000000000000000000002");
        vm.setEnv("MVI1_WALLET", "0x0000000000000000000000000000000000000003");
        vm.setEnv("DEV_WALLET", "0x0000000000000000000000000000000000000004");
        vm.setEnv("OP_TREASURY_WALLET", "0x0000000000000000000000000000000000000005");
        vm.setEnv("CAMPAIGN_MANAGER", "0x0000000000000000000000000000000000000007");
        vm.setEnv(
            "SIGNERS",
            "0x0000000000000000000000000000000000000008,0x0000000000000000000000000000000000000009,0x000000000000000000000000000000000000000a"
        );
    }

    function test_DeployScript_All() public {
        // Enforce safe initial state
        vm.setEnv("ADMIN_ADDRESS", "0x0000000000000000000000000000000000001111");

        // 1. Run with mock token
        vm.chainId(31337);
        vm.setEnv("CNGN_TOKEN_ADDRESS", "");
        deployer.run();

        // 2. Run with real token
        vm.setEnv("CNGN_TOKEN_ADDRESS", "0x0000000000000000000000000000000000009999");
        deployer.run();

        // 3. Revert on zero admin
        vm.setEnv("ADMIN_ADDRESS", "0x0000000000000000000000000000000000000000");
        vm.expectRevert("Final admin cannot be zero");
        deployer.run();
        vm.setEnv("ADMIN_ADDRESS", "0x0000000000000000000000000000000000001111"); // Reset

        // 4. Mainnet mock protection
        vm.setEnv("CNGN_TOKEN_ADDRESS", "");

        vm.chainId(1);
        vm.expectRevert("Cannot deploy MockCNGN on Mainnet!");
        deployer.run();

        vm.chainId(137);
        vm.expectRevert("Cannot deploy MockCNGN on Mainnet!");
        deployer.run();

        vm.chainId(8453);
        vm.expectRevert("Cannot deploy MockCNGN on Mainnet!");
        deployer.run();

        // 5. Successful Mainnet deployment with real token
        vm.setEnv("CNGN_TOKEN_ADDRESS", "0x0000000000000000000000000000000000009999");
        vm.chainId(8453);
        (
            LAWPComplianceEngine engine,
            LAWPMultiSigController multisig,
            LAWPContributionPool pool,
            LAWPImpactToken impactToken,
            LAWPYieldVault yieldVault,
            LAWPOperationalVault operationalVault
        ) = deployer.run();

        /*//////////////////////////////////////////////////////////////
                           POST-DEPLOYMENT ASSERTIONS
        //////////////////////////////////////////////////////////////*/

        // 1. Wallets Configuration
        assertEq(engine.la2Wallet(), vm.envAddress("LA2_WALLET"));
        assertEq(engine.mvi1Wallet(), vm.envAddress("MVI1_WALLET"));
        assertEq(engine.devWallet(), vm.envAddress("DEV_WALLET"));
        assertEq(engine.operationalTreasuryWallet(), vm.envAddress("OP_TREASURY_WALLET"));

        // 2. Roles Configuration
        address finalAdmin = vm.envAddress("ADMIN_ADDRESS");
        address deployerAddress = vm.addr(vm.envUint("PRIVATE_KEY"));

        assertTrue(engine.hasRole(engine.GOVERNANCE_ROLE(), finalAdmin));
        assertTrue(engine.hasRole(0x00, finalAdmin)); // DEFAULT_ADMIN_ROLE

        assertFalse(engine.hasRole(engine.GOVERNANCE_ROLE(), deployerAddress));
        assertFalse(engine.hasRole(0x00, deployerAddress));

        assertTrue(engine.hasRole(engine.CAMPAIGN_MANAGER_ROLE(), vm.envAddress("CAMPAIGN_MANAGER")));
        assertTrue(engine.hasRole(engine.CAMPAIGN_MANAGER_ROLE(), address(pool)));
        assertTrue(engine.hasRole(engine.OPERATOR_ROLE(), address(multisig)));

        // We know signers string is "0x...8,0x...9,0x...a" from setup
        // Let's just assert the addresses directly to avoid parsing in Solidity test
        assertTrue(engine.hasRole(engine.SIGNER_ROLE(), 0x0000000000000000000000000000000000000008));
        assertTrue(engine.hasRole(engine.SIGNER_ROLE(), 0x0000000000000000000000000000000000000009));
        assertTrue(engine.hasRole(engine.SIGNER_ROLE(), 0x000000000000000000000000000000000000000A));

        // 3. Engine Linkages
        assertEq(address(yieldVault.complianceEngine()), address(engine));
        assertEq(address(operationalVault.complianceEngine()), address(engine));
        assertEq(address(impactToken.complianceEngine()), address(engine));

        // 4. Multisig Threshold
        assertEq(multisig.threshold(), 3);
    }
}
