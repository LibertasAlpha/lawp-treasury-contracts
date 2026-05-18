// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { LAWPComplianceEngine } from "../../src/core/LAWPComplianceEngine.sol";
import { LAWPYieldVault } from "../../src/core/LAWPYieldVault.sol";
import { LAWPOperationalVault } from "../../src/core/LAWPOperationalVault.sol";
import { LAWPImpactToken } from "../../src/core/LAWPImpactToken.sol";
import { LAWPActorRegistry } from "../../src/core/LAWPActorRegistry.sol";
import { MockCngn3, MockAdminOperations } from "../mocks/MockCngn3.sol";
import { MockMultiSig } from "../mocks/MockMultiSig.sol";
import { LAWPStructs } from "../../src/libraries/LAWPStructs.sol";

/// @title LAWPTestBase
/// @notice Shared Foundry test base providing deterministic deployment and wiring of the
///         full LAWP protocol stack against the simplified dual-vault architecture.
///         All downstream test contracts inherit from this to eliminate boilerplate and
///         ensure consistent, reproducible state across every test category.
abstract contract LAWPTestBase is Test {
    /*//////////////////////////////////////////////////////////////
                              CONTRACTS
    //////////////////////////////////////////////////////////////*/

    LAWPComplianceEngine public engine;
    LAWPYieldVault public yieldVault;
    LAWPOperationalVault public operationalVault;
    LAWPImpactToken public impactToken;
    LAWPActorRegistry public registry;
    MockCngn3 public cngn;
    MockAdminOperations public adminOps;

    /*//////////////////////////////////////////////////////////////
                              ACTORS
    //////////////////////////////////////////////////////////////*/

    address public admin = address(1);
    address public multiSig = address(2);
    address public la2Wallet = address(3);
    address public mvi1Wallet = address(4);
    address public riskPoolWallet = address(5);
    address public devWallet = address(6);
    address public coordinator = address(7); // Relayer: gas payer AND cNGN fund provider

    address public userA = address(10);
    address public userB = address(11);
    address public userC = address(12);
    address public attacker = address(99);

    /*//////////////////////////////////////////////////////////////
                           PROTOCOL CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 public constant RISK_FEE_BPS = 1000; // 10%
    uint256 public constant TOTAL_BPS = 10_000;
    uint256 public constant SEED_AMOUNT = 10_000_000e6;

    /*//////////////////////////////////////////////////////////////
                               SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() public virtual {
        _deployContracts();
        _configureRegistry();
        _deployEngine();
        _linkContracts();
        _seedTokens();
    }

    function _deployContracts() internal {
        adminOps = new MockAdminOperations();
        cngn = new MockCngn3(address(adminOps));

        registry = new LAWPActorRegistry(admin);
        yieldVault = new LAWPYieldVault(address(cngn), admin);
        operationalVault = new LAWPOperationalVault(address(cngn), admin);
        impactToken = new LAWPImpactToken(admin, "ipfs://lawp-test/");
    }

    function _configureRegistry() internal {
        vm.startPrank(admin);
        registry.setLA2Wallet(la2Wallet);
        registry.setMVI1Wallet(mvi1Wallet);
        registry.setRiskPoolWallet(riskPoolWallet);
        registry.setDevWallet(devWallet);
        vm.stopPrank();
    }

    function _deployEngine() internal {
        engine = new LAWPComplianceEngine(
            admin,
            address(yieldVault),
            address(operationalVault),
            address(impactToken),
            address(registry),
            address(cngn),
            RISK_FEE_BPS
        );
    }

    function _linkContracts() internal {
        vm.startPrank(admin);
        engine.setMultiSigController(multiSig);
        yieldVault.setComplianceEngine(address(engine));
        operationalVault.setComplianceEngine(address(engine));
        impactToken.setComplianceEngine(address(engine));
        vm.stopPrank();
    }

    function _seedTokens() internal {
        // Coordinator is the relayer: funds deposits AND gas
        cngn.mintTest(coordinator, SEED_AMOUNT);
        vm.prank(coordinator);
        cngn.approve(address(engine), type(uint256).max);

        // multiSig funds revenue routing (pulls from multiSig when it calls routeOperationalAllocation)
        cngn.mintTest(multiSig, SEED_AMOUNT);
        vm.prank(multiSig);
        cngn.approve(address(engine), type(uint256).max);

        // User balances for direct deposit tests
        cngn.mintTest(userA, SEED_AMOUNT);
        cngn.mintTest(userB, SEED_AMOUNT);
        cngn.mintTest(userC, SEED_AMOUNT);
    }

    /*//////////////////////////////////////////////////////////////
                          HELPER UTILITIES
    //////////////////////////////////////////////////////////////*/

    /// @notice Creates a standard single-pool deposit with two contributors.
    ///         Pool 1, 100_000e6 gross, userA=60%, userB=40%.
    ///         riskFee = 10_000e6 → operationalVault
    ///         netCapital = 90_000e6 → yieldVault
    ///         Token 1 → userA: principal=54_000e6, BPS=6000
    ///         Token 2 → userB: principal=36_000e6, BPS=4000
    function _setupStandardDeposit() internal {
        address[] memory contributors = new address[](2);
        contributors[0] = userA;
        contributors[1] = userB;
        uint256[] memory bps = new uint256[](2);
        bps[0] = 6000;
        bps[1] = 4000;

        vm.prank(coordinator);
        engine.processPoolDeposit(1, 100_000e6, contributors, bps);
    }

    /// @notice Routes a GRANT_INITIAL allocation to pool 1.
    ///         10_000e6 gross:
    ///           colSplit  = 3_000e6 → poolYieldTracker[1], yieldVault
    ///           la2Split  = 5_000e6 → operationalBalances[la2], operationalVault
    ///           mviSplit  = 2_000e6 → operationalBalances[mvi], operationalVault
    function _setupGrantInitial(uint256 amount) internal {
        vm.prank(multiSig);
        engine.routeOperationalAllocation(1, amount, LAWPStructs.FlowType.GRANT_INITIAL);
    }

    /// @notice Routes a GRANT_CONTINUOUS allocation to pool 1.
    function _setupGrantContinuous(uint256 amount) internal {
        vm.prank(multiSig);
        engine.routeOperationalAllocation(1, amount, LAWPStructs.FlowType.GRANT_CONTINUOUS);
    }

    /// @notice Routes an RoC allocation to pool 1.
    function _setupRoC(uint256 amount) internal {
        vm.prank(multiSig);
        engine.routeOperationalAllocation(1, amount, LAWPStructs.FlowType.RoC);
    }

    /// @notice Computes the expected net capital for a given gross deposit.
    function _netCapital(uint256 gross) internal pure returns (uint256) {
        return gross - (gross * 1000) / 10_000;
    }

    /// @notice Builds a single-contributor array set.
    function _singleContributor(address user)
        internal
        pure
        returns (address[] memory c, uint256[] memory b)
    {
        c = new address[](1);
        c[0] = user;
        b = new uint256[](1);
        b[0] = 10_000;
    }
}
