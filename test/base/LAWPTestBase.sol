// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { LAWPComplianceEngine } from "../../src/core/LAWPComplianceEngine.sol";
import { LAWPYieldVault } from "../../src/core/LAWPYieldVault.sol";
import { LAWPOperationalVault } from "../../src/core/LAWPOperationalVault.sol";
import { LAWPImpactToken } from "../../src/core/LAWPImpactToken.sol";
import { LAWPActorRegistry } from "../../src/core/LAWPActorRegistry.sol";
import { LAWPContributionPool } from "../../src/core/LAWPContributionPool.sol";
import { MockCngn3, MockAdminOperations } from "../mocks/MockCngn3.sol";
import { MockMultiSig } from "../mocks/MockMultiSig.sol";
import { LAWPStructs } from "../../src/libraries/LAWPStructs.sol";

/// @title LAWPTestBase
/// @notice Shared Foundry test base for the LAWP dual-vault protocol.
///
/// @dev TOKEN FLOW ARCHITECTURE (enforced in setUp):
///
///      processPoolDeposit (deposit flow):
///        coordinator -> engine.processPoolDeposit(poolId, gross, contributors, bps)
///        engine does: operationalTreasuryWallet = registry.operationalTreasuryWallet()
///                     operationalBalances[operationalTreasuryWallet] += riskFee (if > 0)
///                     operationalBalances[operationalTreasuryWallet] += netCapital
///                     safeTransferFrom(msg.sender=coordinator, operationalVault, _grossAmount)
///        Approval needed: coordinator -> approves ENGINE
///
///      routeOperationalAllocation (revenue routing flow):
///        coordinator -> mockMultiSig.execute(poolId, amount, flow)
///        mockMultiSig -> engine.routeOperationalAllocation(poolId, amount, coordinator, flow)
///        engine does: safeTransferFrom(_fundProvider=coordinator, vault, amount)
///        Approval needed: coordinator -> approves ENGINE
///
///      contributionPool (pool contribution flow):
///        users -> contributionPool.contribute(poolId, amount)
///        admin  -> contributionPool.settle(poolId)  [onlyOwner]
///        contributionPool -> engine.processPoolDeposit(enginePoolId, totalRaised, contributors, bpsShares)
///        Approval needed: users -> approve CONTRIBUTION_POOL
///                         contributionPool -> approves ENGINE (set/cleared inside settle())
///
///      Both direct and MultiSig deposit flows share the SAME approval (coordinator -> engine).
///      MockMultiSig holds ZERO cNGN at all times.
///      After deposit: only LAWPOperationalVault holds cNGN (full gross amount).
///      After revenue routing: LAWPYieldVault accumulates collective yield and RoC.
///      LAWPYieldVault holds ZERO cNGN immediately after a bare deposit.
abstract contract LAWPTestBase is Test {
    /*//////////////////////////////////////////////////////////////
                              CONTRACTS
    //////////////////////////////////////////////////////////////*/

    LAWPComplianceEngine public engine;
    LAWPYieldVault public yieldVault;
    LAWPOperationalVault public operationalVault;
    LAWPImpactToken public impactToken;
    LAWPActorRegistry public registry;
    LAWPContributionPool public contributionPool;
    MockCngn3 public cngn;
    MockAdminOperations public adminOps;
    MockMultiSig public mockMultiSig;

    /*//////////////////////////////////////////////////////////////
                              ACTORS
    //////////////////////////////////////////////////////////////*/

    address public admin = address(1);

    /// @notice The relayer: gas payer AND ERC20 fund provider for both deposit and routing.
    ///         Approves the ENGINE directly - never the MockMultiSig.
    address public coordinator = address(7);

    address public la2Wallet = address(3);
    address public mvi1Wallet = address(4);
    address public operationalTreasuryWallet = address(5);
    address public devWallet = address(6);

    address public userA = address(10);
    address public userB = address(11);
    address public userC = address(12);
    address public attacker = address(99);

    /*//////////////////////////////////////////////////////////////
                           CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 public constant RISK_FEE_BPS = 1000;
    uint256 public constant TOTAL_BPS = 10_000;
    uint256 public constant SEED_AMOUNT = 100_000_000e6;

    /*//////////////////////////////////////////////////////////////
                               SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() public virtual {
        _deployMockToken();
        _deployRegistry();
        _deployVaults();
        _deployImpactToken();
        _deployEngine();
        _deployMockMultiSig();
        _deployContributionPool();
        _linkContracts();
        _seedAndApprove();
        _assertSetupInvariants();
    }

    function _deployMockToken() internal {
        adminOps = new MockAdminOperations();
        cngn = new MockCngn3(address(adminOps));
    }

    function _deployRegistry() internal {
        registry = new LAWPActorRegistry(admin);
        vm.startPrank(admin);
        registry.setLA2Wallet(la2Wallet);
        registry.setMVI1Wallet(mvi1Wallet);
        registry.setOperationalTreasuryWallet(operationalTreasuryWallet);
        registry.setDevWallet(devWallet);
        vm.stopPrank();
    }

    function _deployVaults() internal {
        yieldVault = new LAWPYieldVault(address(cngn), admin);
        operationalVault = new LAWPOperationalVault(address(cngn), admin);
    }

    function _deployImpactToken() internal {
        impactToken = new LAWPImpactToken(admin, "ipfs://lawp-test/");
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

    function _deployMockMultiSig() internal {
        // Pass-through contract. Holds zero cNGN.
        mockMultiSig = new MockMultiSig(address(engine));
    }

    /// @dev Deploys the ContributionPool. Engine and cNGN must be deployed first.
    ///      The pool owner is `admin`, matching the other protocol contracts.
    function _deployContributionPool() internal {
        contributionPool = new LAWPContributionPool(address(cngn), admin);
    }

    function _linkContracts() internal {
        vm.startPrank(admin);
        engine.setMultiSigController(address(mockMultiSig));
        yieldVault.setComplianceEngine(address(engine));
        operationalVault.setComplianceEngine(address(engine));
        impactToken.setComplianceEngine(address(engine));
        contributionPool.setComplianceEngine(address(engine));
        vm.stopPrank();
    }

    function _seedAndApprove() internal {
        // Coordinator is the sole fund provider for ALL direct protocol flows.
        // ONE approval to the ENGINE covers both deposit and revenue routing.
        cngn.mintTest(coordinator, SEED_AMOUNT);
        vm.prank(coordinator);
        cngn.approve(address(engine), type(uint256).max);

        // Users for contribution pool flows - they approve the POOL, not the engine.
        cngn.mintTest(userA, SEED_AMOUNT);
        cngn.mintTest(userB, SEED_AMOUNT);
        cngn.mintTest(userC, SEED_AMOUNT);
    }

    function _assertSetupInvariants() internal view {
        // Only vaults hold protocol cNGN
        assertEq(cngn.balanceOf(address(mockMultiSig)), 0, "MockMultiSig must hold zero cNGN");
        assertEq(cngn.balanceOf(address(engine)), 0, "Engine must hold zero cNGN");
        // ContributionPool starts empty
        assertEq(
            cngn.balanceOf(address(contributionPool)),
            0,
            "ContributionPool must hold zero cNGN at deploy"
        );
        // Pool counter starts at 1
        assertEq(contributionPool.poolCount(), 1, "ContributionPool poolCount must start at 1");
    }

    /*//////////////////////////////////////////////////////////////
                          HELPER UTILITIES
    //////////////////////////////////////////////////////////////*/

    /// @notice Standard 2-contributor deposit: pool 1, 100_000e6 gross.
    ///         Full gross (100_000e6) -> operationalVault in a single transfer.
    ///         operationalBalances[operationalTreasuryWallet]:
    ///           riskFee component  = 10_000e6
    ///           netCapital component = 90_000e6
    ///         Token 1 -> userA: netPrincipal=54_000e6, BPS=6000
    ///         Token 2 -> userB: netPrincipal=36_000e6, BPS=4000
    function _setupStandardDeposit() internal {
        address[] memory c = new address[](2);
        c[0] = userA;
        c[1] = userB;
        uint256[] memory b = new uint256[](2);
        b[0] = 6000;
        b[1] = 4000;
        vm.prank(coordinator);
        engine.processPoolDeposit(1, 100_000e6, c, b);
    }

    /// @notice Routes revenue through MockMultiSig. Coordinator is fund provider.
    function _routeRevenue(uint256 _poolId, uint256 _amount, LAWPStructs.FlowType _flow) internal {
        vm.prank(coordinator);
        mockMultiSig.execute(_poolId, _amount, _flow);
        // Invariant: MockMultiSig always returns to zero after execution
        assertEq(cngn.balanceOf(address(mockMultiSig)), 0, "MockMultiSig balance leaked");
    }

    function _setupGrantInitial(uint256 amount) internal {
        _routeRevenue(1, amount, LAWPStructs.FlowType.GRANT_INITIAL);
    }

    function _setupGrantContinuous(uint256 amount) internal {
        _routeRevenue(1, amount, LAWPStructs.FlowType.GRANT_CONTINUOUS);
    }

    function _setupRoC(uint256 amount) internal {
        _routeRevenue(1, amount, LAWPStructs.FlowType.RoC);
    }

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

    function _netCapital(uint256 gross) internal pure returns (uint256) {
        return gross - (gross * 1000) / 10_000;
    }

    /*//////////////////////////////////////////////////////////////
                       CONTRIBUTION POOL HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Creates a standard contribution pool via the base contributionPool fixture.
    ///         PoolId starts at 1 (constructor sets poolCount = 1).
    /// @param _enginePoolId  The engine-level poolId forwarded at settlement.
    /// @param _goal          Minimum gross cNGN required.
    /// @param _startTime     Window open timestamp.
    /// @param _endTime       Window close timestamp.
    function _createContribPool(
        uint256 _enginePoolId,
        uint256 _goal,
        uint256 _startTime,
        uint256 _endTime
    ) internal returns (uint256 poolId) {
        vm.prank(admin);
        poolId = contributionPool.createPool(_enginePoolId, _goal, _startTime, _endTime);
    }

    /// @notice Approves the contribution pool and contributes on behalf of `_user`.
    function _contribute(address _user, uint256 _poolId, uint256 _amount) internal {
        vm.prank(_user);
        cngn.approve(address(contributionPool), _amount);
        vm.prank(_user);
        contributionPool.contribute(_poolId, _amount);
    }

    /// @notice Admin settles a contribution pool (onlyOwner).
    function _settlePool(uint256 _poolId) internal {
        vm.prank(admin);
        contributionPool.settle(_poolId);
    }
}
