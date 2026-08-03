// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {LAWPActors} from "../utils/LAWPActors.sol";
import {LAWPConstants} from "../utils/LAWPConstants.sol";
import {MockCNGN} from "../mocks/MockCNGN.sol";

import {LAWPComplianceEngine} from "../../src/core/LAWPComplianceEngine.sol";
import {LAWPContributionPool} from "../../src/core/LAWPContributionPool.sol";
import {LAWPMultiSigController} from "../../src/core/LAWPMultiSigController.sol";
import {LAWPOperationalVault} from "../../src/core/LAWPOperationalVault.sol";
import {LAWPYieldVault} from "../../src/core/LAWPYieldVault.sol";
import {LAWPImpactToken} from "../../src/core/LAWPImpactToken.sol";

/// @title LAWPFixture
/// @notice Minimal base setup verifying valid, reproducible deployment wiring and dependencies.
contract LAWPFixture is LAWPActors {
    MockCNGN token;
    LAWPComplianceEngine engine;
    LAWPContributionPool pool;
    LAWPMultiSigController multisig;
    LAWPOperationalVault opVault;
    LAWPYieldVault yieldVault;
    LAWPImpactToken impactToken;

    function setUp() public virtual {
        // 1. Deploy Mock Asset
        token = new MockCNGN();

        // 2. Precompute Engine Address to resolve circular dependency
        // Current nonce is used for token, so next nonces will be:
        // +0: opVault
        // +1: yieldVault
        // +2: impactToken
        // +3: engine
        uint64 nonce = vm.getNonce(address(this));
        address computedEngine = vm.computeCreateAddress(address(this), nonce + 3);

        // 3. Deploy Satellites & Vaults using computed Engine address
        opVault = new LAWPOperationalVault(address(token), computedEngine);
        yieldVault = new LAWPYieldVault(address(token), computedEngine);
        impactToken = new LAWPImpactToken(computedEngine, "ipfs://QmBase/");

        // 4. Deploy Central Hub (ComplianceEngine)
        engine = new LAWPComplianceEngine(
            governance, // admin
            address(yieldVault), // yieldVault
            address(opVault), // operationalVault
            address(impactToken), // impactToken
            address(token), // cNGNToken
            50 // initialRiskFeeBPS
        );

        require(address(engine) == computedEngine, "CREATE address mismatch");

        // 5. Deploy edge satellites
        pool = new LAWPContributionPool(address(token), address(engine));
        multisig = new LAWPMultiSigController(address(engine), 2); // 2 of 3 threshold

        // 6. Configure Wallets & Roles
        vm.startPrank(governance);
        engine.setLA2Wallet(la2Wallet);
        engine.setMVI1Wallet(mvi1Wallet);
        engine.setDevWallet(devWallet);
        engine.setOperationalTreasuryWallet(opTreasuryWallet);

        engine.grantRole(LAWPConstants.CAMPAIGN_MANAGER_ROLE, campaignManager);
        engine.grantRole(LAWPConstants.OPERATOR_ROLE, operator);
        engine.grantRole(LAWPConstants.SIGNER_ROLE, signer1);
        engine.grantRole(LAWPConstants.SIGNER_ROLE, signer2);
        engine.grantRole(LAWPConstants.SIGNER_ROLE, signer3);
        vm.stopPrank();
    }
}

/// @title LAWPFixtureTest
/// @notice Validates the fixture initialization and immutable wiring.
contract LAWPFixtureTest is LAWPFixture {
    function test_FixtureDeploymentWiring() public view {
        // Assert token wiring
        assertEq(address(engine.cNGNToken()), address(token));
        assertEq(address(pool.cNGNToken()), address(token));
        assertEq(address(opVault.cNGNToken()), address(token));
        assertEq(address(yieldVault.cNGNToken()), address(token));

        // Assert immutable engine references in satellites
        assertEq(address(pool.complianceEngine()), address(engine));
        assertEq(address(multisig.engine()), address(engine));
        assertEq(opVault.complianceEngine(), address(engine));
        assertEq(yieldVault.complianceEngine(), address(engine));
        assertEq(impactToken.complianceEngine(), address(engine));

        // Assert engine satellite resolution
        assertEq(address(engine.yieldVault()), address(yieldVault));
        assertEq(address(engine.operationalVault()), address(opVault));
        assertEq(address(engine.impactToken()), address(impactToken));
    }

    function test_FixtureRoleInitialization() public view {
        assertTrue(engine.hasRole(LAWPConstants.GOVERNANCE_ROLE, governance));
        assertTrue(engine.hasRole(LAWPConstants.DEFAULT_ADMIN_ROLE, governance));
        assertTrue(engine.hasRole(LAWPConstants.CAMPAIGN_MANAGER_ROLE, campaignManager));
        assertTrue(engine.hasRole(LAWPConstants.OPERATOR_ROLE, operator));

        assertTrue(engine.hasRole(LAWPConstants.SIGNER_ROLE, signer1));
        assertTrue(engine.hasRole(LAWPConstants.SIGNER_ROLE, signer2));
        assertTrue(engine.hasRole(LAWPConstants.SIGNER_ROLE, signer3));
    }

    function test_FixtureTargetWallets() public view {
        assertEq(engine.la2Wallet(), la2Wallet);
        assertEq(engine.mvi1Wallet(), mvi1Wallet);
        assertEq(engine.devWallet(), devWallet);
    }
}
