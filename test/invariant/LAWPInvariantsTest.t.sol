// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test, console } from "forge-std/Test.sol";
import { LAWPComplianceEngine } from "../../src/core/LAWPComplianceEngine.sol";
import { LAWPYieldVault } from "../../src/core/LAWPYieldVault.sol";
import { LAWPOperationalVault } from "../../src/core/LAWPOperationalVault.sol";
import { LAWPImpactToken } from "../../src/core/LAWPImpactToken.sol";
import { LAWPActorRegistry } from "../../src/core/LAWPActorRegistry.sol";
import { MockCngn3, MockAdminOperations } from "../mocks/MockCngn3.sol";
import { MockMultiSig } from "../mocks/MockMultiSig.sol";
import { LAWPHandler } from "./LAWPHandler.sol";
import { LAWPStructs } from "../../src/libraries/LAWPStructs.sol";

/// @title LAWPInvariantsTest
/// @notice Stateful fuzzing test suite that probes the LAWP Protocol's mathematical
///         invariants across the full dual-vault architecture.
contract LAWPInvariantsTest is Test {
    LAWPComplianceEngine public engine;
    LAWPYieldVault public yieldVault;
    LAWPOperationalVault public operationalVault;
    LAWPImpactToken public impactToken;
    LAWPActorRegistry public registry;
    MockCngn3 public cngn;
    MockMultiSig public multiSig;
    LAWPHandler public handler;

    address public admin = address(1);
    address public la2 = address(11);
    address public mvi1 = address(12);
    address public riskPool = address(13);
    address public dev = address(14);

    function setUp() public {
        MockAdminOperations adminOps = new MockAdminOperations();
        cngn = new MockCngn3(address(adminOps));

        registry = new LAWPActorRegistry(admin);
        vm.startPrank(admin);
        registry.setLA2Wallet(la2);
        registry.setMVI1Wallet(mvi1);
        registry.setRiskPoolWallet(riskPool);
        registry.setDevWallet(dev);
        vm.stopPrank();

        yieldVault = new LAWPYieldVault(address(cngn), admin);
        operationalVault = new LAWPOperationalVault(address(cngn), admin);
        impactToken = new LAWPImpactToken(admin, "ipfs://lawp/");

        engine = new LAWPComplianceEngine(
            admin,
            address(yieldVault),
            address(operationalVault),
            address(impactToken),
            address(registry),
            address(cngn),
            1000 // 10% risk fee
        );

        multiSig = new MockMultiSig(address(engine));

        vm.startPrank(admin);
        engine.setMultiSigController(address(multiSig));
        yieldVault.setComplianceEngine(address(engine));
        operationalVault.setComplianceEngine(address(engine));
        impactToken.setComplianceEngine(address(engine));
        vm.stopPrank();

        handler = new LAWPHandler(engine, yieldVault, operationalVault, impactToken, multiSig, cngn);

        targetContract(address(handler));
    }

    /*//////////////////////////////////////////////////////////////
               INVARIANT A: RoC Ceiling (Per Token & Global)
    //////////////////////////////////////////////////////////////*/

    /// @notice A user can NEVER receive back more principal than they originally invested.
    function invariant_A_RocCeiling() public view {
        uint256 sumNetPrincipal;
        uint256 sumRocReturned;
        uint256 len = handler.activeTokensLength();

        for (uint256 i = 0; i < len; i++) {
            uint256 tokenId = handler.activeTokens(i);
            LAWPStructs.TokenData memory data = impactToken.getTokenData(tokenId);

            assertLe(
                data.rocReturned, data.netPrincipal, "Invariant A: Per-token RoC exceeds principal"
            );

            sumNetPrincipal += data.netPrincipal;
            sumRocReturned += data.rocReturned;
        }

        assertLe(sumRocReturned, sumNetPrincipal, "Invariant A: Global RoC exceeds total principal");
    }

    /*//////////////////////////////////////////////////////////////
               INVARIANT B: YieldVault Solvency Law
    //////////////////////////////////////////////////////////////*/

    /// @notice YieldVault must always hold enough to cover all unclaimed yield + RoC obligations.
    function invariant_B_YieldVaultSolvency() public view {
        uint256 vaultBalance = cngn.balanceOf(address(yieldVault));
        uint256 totalObligations;
        uint256 len = handler.activePoolsLength();

        for (uint256 i = 0; i < len; i++) {
            uint256 poolId = handler.activePools(i);
            totalObligations += handler.ghost_poolNetDeposits(poolId);
            totalObligations += handler.ghost_poolYieldRouted(poolId);
            totalObligations += handler.ghost_poolRocRouted(poolId);
        }

        uint256 totalClaimed = handler.ghost_totalClaimedYield() + handler.ghost_totalClaimedRoc();
        uint256 netObligations =
            totalObligations > totalClaimed ? totalObligations - totalClaimed : 0;

        assertGe(vaultBalance, netObligations, "Invariant B: YieldVault is INSOLVENT");
    }

    /*//////////////////////////////////////////////////////////////
               INVARIANT C: Dust Conservation
    //////////////////////////////////////////////////////////////*/

    /// @notice Fractional math must never leak a single wei.
    ///         Sum of all token principals in a pool must exactly equal pool net capital.
    function invariant_C_DustConservation() public view {
        uint256 poolLen = handler.activePoolsLength();
        uint256 tokenLen = handler.activeTokensLength();

        for (uint256 i = 0; i < poolLen; i++) {
            uint256 poolId = handler.activePools(i);
            uint256 sumPrincipal;
            uint256 sumBPS;

            for (uint256 j = 0; j < tokenLen; j++) {
                uint256 tokenId = handler.activeTokens(j);
                LAWPStructs.TokenData memory data = impactToken.getTokenData(tokenId);

                if (data.poolId == poolId) {
                    sumPrincipal += data.netPrincipal;
                    sumBPS += data.poolShareBPS;
                }
            }

            assertEq(sumBPS, 10_000, "Invariant C: BPS total != 10000");
            assertEq(
                sumPrincipal,
                handler.ghost_poolNetDeposits(poolId),
                "Invariant C: Wei dust leaked from principal split"
            );
        }
    }

    /*//////////////////////////////////////////////////////////////
               INVARIANT E: No Ghost Tokens
    //////////////////////////////////////////////////////////////*/

    /// @notice Every minted token must represent real value, a valid pool, and a real owner.
    function invariant_E_NoGhostTokens() public view {
        uint256 len = handler.activeTokensLength();

        for (uint256 i = 0; i < len; i++) {
            uint256 tokenId = handler.activeTokens(i);
            LAWPStructs.TokenData memory data = impactToken.getTokenData(tokenId);
            address owner = impactToken.ownerOf(tokenId);

            assertNotEq(owner, address(0), "Invariant E: Ghost token - no owner");
            assertGt(data.poolId, 0, "Invariant E: Ghost token - no pool ID");
            assertGt(data.netPrincipal, 0, "Invariant E: Ghost token - zero principal");
        }
    }

    /*//////////////////////////////////////////////////////////////
               INVARIANT G: Monotonic Yield Tracker Sync
    //////////////////////////////////////////////////////////////*/

    /// @notice The engine's on-chain yield trackers must always match the handler's ghost state.
    function invariant_G_MonotonicYieldSync() public view {
        uint256 len = handler.activePoolsLength();

        for (uint256 i = 0; i < len; i++) {
            uint256 poolId = handler.activePools(i);

            assertEq(
                engine.poolYieldTracker(poolId),
                handler.ghost_poolYieldRouted(poolId),
                "Invariant G: poolYieldTracker desynced from ghost"
            );
            assertEq(
                engine.poolRocTracker(poolId),
                handler.ghost_poolRocRouted(poolId),
                "Invariant G: poolRocTracker desynced from ghost"
            );
        }
    }

    /*//////////////////////////////////////////////////////////////
               INVARIANT H: No Negative Yield
    //////////////////////////////////////////////////////////////*/

    /// @notice The protocol can never distribute more yield than was routed to it.
    function invariant_H_NoNegativeYield() public view {
        uint256 totalRoutedYield;
        uint256 len = handler.activePoolsLength();

        for (uint256 i = 0; i < len; i++) {
            totalRoutedYield += handler.ghost_poolYieldRouted(handler.activePools(i));
        }

        assertGe(
            totalRoutedYield,
            handler.ghost_totalClaimedYield(),
            "Invariant H: Negative yield - more claimed than routed"
        );
    }

    /*//////////////////////////////////////////////////////////////
           INVARIANT I: Zero-Custody (Engine & MultiSig)
    //////////////////////////////////////////////////////////////*/

    /// @notice The Compliance Engine and MockMultiSig must NEVER hold cNGN.
    ///         Only the two vaults are permitted to hold protocol funds.
    function invariant_I_ZeroCustody() public view {
        assertEq(
            cngn.balanceOf(address(engine)),
            0,
            "Invariant I: ComplianceEngine holds cNGN (custody violation)"
        );
        assertEq(
            cngn.balanceOf(address(multiSig)),
            0,
            "Invariant I: MockMultiSig holds cNGN (custody violation)"
        );
    }

    /*//////////////////////////////////////////////////////////////
           INVARIANT J: OperationalVault >= Unclaimed Operational Balances
    //////////////////////////////////////////////////////////////*/

    /// @notice The OperationalVault must always hold enough to cover all ledger obligations.
    function invariant_J_OperationalVaultSolvency() public view {
        uint256 vaultBalance = cngn.balanceOf(address(operationalVault));

        // Sum all unclaimed operational balances from the known actor wallets
        uint256 totalLedger = engine.operationalBalances(la2) + engine.operationalBalances(mvi1)
            + engine.operationalBalances(dev) + engine.operationalBalances(riskPool);

        assertGe(
            vaultBalance,
            totalLedger,
            "Invariant J: OperationalVault cannot cover ledger obligations"
        );
    }
}
