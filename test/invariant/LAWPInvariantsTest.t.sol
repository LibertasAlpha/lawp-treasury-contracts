// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test, console } from "forge-std/Test.sol";
import { LAWPComplianceEngine } from "../../src/core/LAWPComplianceEngine.sol";
import { LAWPTreasury } from "../../src/core/LAWPTreasury.sol";
import { LAWPImpactToken } from "../../src/core/LAWPImpactToken.sol";
import { LAWPActorRegistry } from "../../src/core/LAWPActorRegistry.sol";
import { MockCngn3, MockAdminOperations } from "../mocks/MockCngn3.sol";
import { MockMultiSig } from "../mocks/MockMultiSig.sol";
import { LAWPHandler } from "./LAWPHandler.sol";
import { LAWPStructs } from "../../src/libraries/LAWPStructs.sol";

contract LAWPInvariantsTest is Test {
    LAWPComplianceEngine public engine;
    LAWPTreasury public treasury;
    LAWPImpactToken public impactToken;
    LAWPActorRegistry public registry;
    MockCngn3 public cngn;
    MockAdminOperations public adminOps;
    MockMultiSig public multiSig;
    LAWPHandler public handler;

    address public admin = address(1);

    function setUp() public {
        adminOps = new MockAdminOperations();
        cngn = new MockCngn3(address(adminOps));

        registry = new LAWPActorRegistry(admin);
        treasury = new LAWPTreasury(address(cngn), admin);
        impactToken = new LAWPImpactToken(admin, "ipfs://base/");

        vm.startPrank(admin);
        registry.setLA2Wallet(address(11));
        registry.setMVI1Wallet(address(12));
        registry.setRiskPoolWallet(address(13));
        registry.setDevWallet(address(14));
        vm.stopPrank();

        engine = new LAWPComplianceEngine(
            admin, address(treasury), address(impactToken), address(registry), address(cngn), 1000
        );

        multiSig = new MockMultiSig(address(engine));

        vm.startPrank(admin);
        engine.setMultiSigController(address(multiSig));
        treasury.setComplianceEngine(address(engine));
        treasury.setRiskPoolWallet(address(13));
        impactToken.setComplianceEngine(address(engine));
        vm.stopPrank();

        handler = new LAWPHandler(engine, treasury, impactToken, multiSig, cngn);

        targetContract(address(handler));
    }

    /// @notice Invariant A: RoC Ceiling (Per Token & Globally Aggregated)
    /// @dev System-wide, a user can NEVER receive back more principal than they invested.
    function invariant_A_RocCeiling() public view {
        uint256 sumNetPrincipal = 0;
        uint256 sumRocReturned = 0;
        uint256 len = handler.activeTokensLength();

        for (uint256 i = 0; i < len; i++) {
            uint256 tokenId = handler.activeTokens(i);
            LAWPStructs.TokenData memory data = impactToken.getTokenData(tokenId);

            // Per Token Hard Limit
            assertLe(
                data.rocReturned, data.netPrincipal, "Invariant A: Individual RoC breached cap"
            );

            sumNetPrincipal += data.netPrincipal;
            sumRocReturned += data.rocReturned;
        }

        // Global Protocol Aggregation
        assertLe(sumRocReturned, sumNetPrincipal, "Invariant A: Global RoC breached cap");
    }

    /// @notice Invariant B: Solvency Law (Bankruptcy Preventer)
    /// @dev The Treasury must ALWAYS have enough balance to cover every single un-claimed obligation.
    function invariant_B_SolvencyLaw() public view {
        uint256 treasuryBalance = treasury.getVaultBalance();
        uint256 totalGlobalObligations = 0;
        uint256 len = handler.activePoolsLength();

        for (uint256 i = 0; i < len; i++) {
            uint256 poolId = handler.activePools(i);

            // Unclaimed obligations = Net Deposits (unclaimed RoC buffer) + Yields Routed
            totalGlobalObligations += handler.ghost_poolNetDeposits(poolId);
            totalGlobalObligations += handler.ghost_poolYieldRouted(poolId);
        }

        uint256 totalLiabilities = totalGlobalObligations
            - (handler.ghost_totalClaimedYield() + handler.ghost_totalClaimedRoc());

        assertGe(treasuryBalance, totalLiabilities, "Invariant B: Protocol is BANKRUPT");
    }

    /// @notice Invariant C: Dust & Principal Conservation
    /// @dev Fractional math must NEVER leak a single wei. Everything is perfectly conserved.
    function invariant_C_DustConservation() public view {
        uint256 poolLen = handler.activePoolsLength();
        uint256 tokenLen = handler.activeTokensLength();

        for (uint256 i = 0; i < poolLen; i++) {
            uint256 poolId = handler.activePools(i);
            uint256 sumNetPrincipal = 0;
            uint256 sumBPS = 0;

            for (uint256 j = 0; j < tokenLen; j++) {
                uint256 tokenId = handler.activeTokens(j);
                LAWPStructs.TokenData memory data = impactToken.getTokenData(tokenId);

                if (data.poolId == poolId) {
                    sumNetPrincipal += data.netPrincipal;
                    sumBPS += data.poolShareBPS;
                }
            }

            // Exactly 10000 BPS (No missing or overflow ownership)
            assertEq(sumBPS, 10000, "Invariant C: BPS does not sum to 10000");
            // Zero wei lost to rounding errors
            assertEq(
                sumNetPrincipal,
                handler.ghost_poolNetDeposits(poolId),
                "Invariant C: Wei lost to fractional dust"
            );
        }
    }

    /// @notice Invariant E: No Ghost Tokens (State Integrity)
    /// @dev Every minted token must represent real value, valid pools, and exist in a user's wallet.
    function invariant_E_NoGhostTokens() public view {
        uint256 len = handler.activeTokensLength();

        for (uint256 i = 0; i < len; i++) {
            uint256 tokenId = handler.activeTokens(i);
            LAWPStructs.TokenData memory data = impactToken.getTokenData(tokenId);
            address owner = impactToken.ownerOf(tokenId);

            assertNotEq(owner, address(0), "Invariant E: Ghost token (No Owner)");
            assertGt(data.poolId, 0, "Invariant E: Ghost token (No Pool ID)");
            assertGt(data.netPrincipal, 0, "Invariant E: Ghost token (Zero Principal)");
        }
    }

    /// @notice Invariant G: Monotonic Yield Tracking (Accounting Correctness)
    /// @dev The engine's internal ledgers must never skew from the parallel off-chain truth.
    function invariant_G_MonotonicYield() public view {
        uint256 len = handler.activePoolsLength();

        for (uint256 i = 0; i < len; i++) {
            uint256 poolId = handler.activePools(i);
            uint256 trackerYield = engine.poolYieldTracker(poolId);
            uint256 trackerRoc = engine.poolRocTracker(poolId);

            assertEq(
                trackerYield,
                handler.ghost_poolYieldRouted(poolId),
                "Invariant G: Yield accounting desync"
            );
            assertEq(
                trackerRoc,
                handler.ghost_poolRocRouted(poolId),
                "Invariant G: RoC accounting desync"
            );
        }
    }

    /// @notice Invariant H: No Negative Yield (Conservation of Creation)
    /// @dev The protocol can NEVER claim more yield than what was routed to it globally.
    function invariant_H_NoNegativeYield() public view {
        uint256 totalGlobalRoutedYield = 0;
        uint256 len = handler.activePoolsLength();

        for (uint256 i = 0; i < len; i++) {
            uint256 poolId = handler.activePools(i);
            totalGlobalRoutedYield += handler.ghost_poolYieldRouted(poolId);
        }

        assertGe(
            totalGlobalRoutedYield,
            handler.ghost_totalClaimedYield(),
            "Invariant H: Negative Yield (Over-claimed)"
        );
    }
}
