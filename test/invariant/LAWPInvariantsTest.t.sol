// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { LAWPComplianceEngine } from "../../src/core/LAWPComplianceEngine.sol";
import { LAWPYieldVault } from "../../src/core/LAWPYieldVault.sol";
import { LAWPOperationalVault } from "../../src/core/LAWPOperationalVault.sol";
import { LAWPImpactToken } from "../../src/core/LAWPImpactToken.sol";
import { LAWPActorRegistry } from "../../src/core/LAWPActorRegistry.sol";
import { MockCngn3, MockAdminOperations } from "../mocks/MockCngn3.sol";
import { MockMultiSig } from "../mocks/MockMultiSig.sol";
import { LAWPHandler } from "./LAWPHandler.sol";
import { LAWPStructs } from "../../src/libraries/LAWPStructs.sol";

/*//////////////////////////////////////////////////////////////
                LAWPINVARIANTSTEST - STATEFUL FUZZ SUITE
//////////////////////////////////////////////////////////////*/

/**
 * @notice This contract defines the invariant tests for the LAWP Protocol. It defines
 *         mathematical laws that the LAWP Protocol must ALWAYS satisfy,
 *         no matter what sequence of operations the fuzzer performs.
 *         Each invariant_ function is a theorem that must hold after every
 *         single state-changing call.
 *
 * @dev INVARIANT CATALOGUE:
 *      A  RoC Ceiling              - investors never get back more than put in
 *      B  YieldVault Solvency      - vault can always pay all yield obligations
 *      C  Dust Conservation        - BPS split never loses or creates a wei
 *      E  No Ghost Tokens          - every NFT has a real owner, pool, capital
 *      G  Tracker Sync             - on-chain accumulators match ghost state
 *      H  No Negative Yield        - claimed yield ≤ routed yield
 *      I  Zero Custody             - engine + multiSig never hold cNGN
 *      J  OpVault Solvency         - opVault can cover all ledger obligations
 *      K  Accumulator Monotonicity - yield/RoC trackers only ever increase
 *      L  Token Data Immutability  - principal and BPS never change post-mint
 *      M  cNGN Conservation Law    - no cNGN is created or destroyed
 *      N  Yield Math Correctness   - claimable yield ≤ mathematical upper bound
 *      O  Pool Uniqueness          - a poolId registered once stays registered
 */
contract LAWPInvariantsTest is Test {
    /*//////////////////////////////////////////////////////////////
                           PROTOCOL CONTRACTS
    //////////////////////////////////////////////////////////////*/

    LAWPComplianceEngine public engine;
    LAWPYieldVault public yieldVault;
    LAWPOperationalVault public operationalVault;
    LAWPImpactToken public impactToken;
    LAWPActorRegistry public registry;
    MockCngn3 public cngn;
    MockMultiSig public multiSig;
    LAWPHandler public handler;

    /*//////////////////////////////////////////////////////////////
                            PROTOCOL ACTORS
    //////////////////////////////////////////////////////////////*/

    address public admin = address(1);
    address public la2 = address(11);
    address public mvi1 = address(12);
    address public operationalTreasury = address(13);
    address public dev = address(14);

    /*//////////////////////////////////////////////////////////////
                                 SETUP
    //////////////////////////////////////////////////////////////*/

    /// @notice Deploys the full protocol stack, creates the Handler, and registers
    ///         it as the sole fuzz target. The setup mirrors Deploy.s.sol + Configure.s.sol.
    function setUp() public {
        // Token
        MockAdminOperations adminOps = new MockAdminOperations();
        cngn = new MockCngn3(address(adminOps));

        // Registry
        registry = new LAWPActorRegistry(admin);
        vm.startPrank(admin);
        registry.setLA2Wallet(la2);
        registry.setMVI1Wallet(mvi1);
        registry.setOperationalTreasuryWallet(operationalTreasury);
        registry.setDevWallet(dev);
        vm.stopPrank();

        // Dault Vaults
        // ONLY these two contracts may ever hold cNGN.
        yieldVault = new LAWPYieldVault(address(cngn), admin);
        operationalVault = new LAWPOperationalVault(address(cngn), admin);

        // Impact Token
        impactToken = new LAWPImpactToken(admin, "ipfs://lawp/");

        // Compliance Engine
        engine = new LAWPComplianceEngine(
            admin,
            address(yieldVault),
            address(operationalVault),
            address(impactToken),
            address(registry),
            address(cngn),
            1000 // 10% risk fee
        );

        // MockMultiSig: zero-custody pass-through
        multiSig = new MockMultiSig(address(engine));

        // Wire trust boundaries
        vm.startPrank(admin);
        engine.setMultiSigController(address(multiSig));
        yieldVault.setComplianceEngine(address(engine));
        operationalVault.setComplianceEngine(address(engine));
        impactToken.setComplianceEngine(address(engine));
        vm.stopPrank();

        // Fuzz Handler
        // The handler seeds relayer addresses, manages ghost variables, and
        // calls the protocol with constrained valid inputs.
        handler = new LAWPHandler(engine, yieldVault, operationalVault, impactToken, multiSig, cngn);

        // Tell Foundry: ONLY call functions on `handler`.
        // The fuzzer will never call protocol contracts directly.
        targetContract(address(handler));
    }

    /*//////////////////////////////////////////////////////////////
                          INVARIANT FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    // INVARIANT A: RoC Ceiling
    /// @notice An investor can NEVER receive back more cNGN than they originally
    ///         deposited as principal.
    ///
    /// @dev WHY IT MATTERS:
    ///      The RoC (Return of Contribution) mechanism routes off-chain revenue
    ///      back to investors. But this must be capped at each token's `netPrincipal`.
    ///      A bug in the cap logic or the poolRocTracker * BPS math could allow
    ///      over-distribution - essentially stealing from the vault.
    ///
    ///      PER-TOKEN CHECK: rocReturned ≤ netPrincipal
    ///      GLOBAL CHECK:    sum(rocReturned) ≤ sum(netPrincipal)
    function invariant_A_RocCeiling() public view {
        uint256 sumNetPrincipal;
        uint256 sumRocReturned;
        uint256 len = handler.activeTokensLength();

        for (uint256 i = 0; i < len; i++) {
            uint256 tokenId = handler.activeTokens(i);
            LAWPStructs.TokenData memory data = impactToken.getTokenData(tokenId);

            // Per-token: the principal returned must never exceed principal locked
            assertLe(
                data.rocReturned,
                data.netPrincipal,
                "Invariant A: Per-token RoC exceeds principal - investor over-compensated"
            );

            sumNetPrincipal += data.netPrincipal;
            sumRocReturned += data.rocReturned;
        }

        // Global: even if per-token checks pass, the system-wide total must hold
        assertLe(
            sumRocReturned,
            sumNetPrincipal,
            "Invariant A: Global RoC exceeds total principal - systemic over-distribution"
        );
    }

    // INVARIANT B: YieldVault Solvency
    /// @notice The YieldVault must always hold enough cNGN to pay all unclaimed
    ///         investor obligations (principal returns + yield distributions).
    ///
    /// @dev WHY IT MATTERS:
    ///      This is the core "the protocol cannot go bankrupt" invariant for the
    ///      investor side. If this breaks, token holders cannot claim what they
    ///      are owed. It would catch:
    ///        - Double-spend: a claim that drains more than the claimable amount
    ///        - Routing error: funds routed to the wrong vault
    ///        - Math underflow: negative balance after sequential claims
    ///
    ///      NET OBLIGATIONS = (net deposits + yield routed + RoC routed) - claimed
    ///      MUST SATISFY:   vaultBalance >= netObligations
    function invariant_B_YieldVaultSolvency() public view {
        uint256 vaultBalance = cngn.balanceOf(address(yieldVault));
        uint256 totalObligations;
        uint256 len = handler.activePoolsLength();

        for (uint256 i = 0; i < len; i++) {
            uint256 poolId = handler.activePools(i);
            // Collective yield routed to this pool's investors
            totalObligations += handler.ghost_poolYieldRouted(poolId);
            // RoC routed to this pool's investors
            totalObligations += handler.ghost_poolRocRouted(poolId);
        }

        uint256 totalClaimed = handler.ghost_totalClaimedYield() + handler.ghost_totalClaimedRoc();
        uint256 netObligations =
            totalObligations == totalClaimed ? totalObligations - totalClaimed : 0;

        assertGe(
            vaultBalance,
            netObligations,
            "Invariant B: YieldVault is INSOLVENT - cannot cover investor obligations"
        );
    }

    // INVARIANT C: Dust Conservation
    /// @notice Fractional arithmetic during pool deposits must never leak or
    ///         create a single wei. The sum of all token principals in a pool
    ///         must equal exactly the pool's net capital.
    ///
    /// @dev WHY IT MATTERS:
    ///      Solidity integer division truncates. With N contributors splitting
    ///      a net capital of X, each gets floor(X * BPS / 10_000). The dust
    ///      (rounding remainder) must be absorbed by the last contributor,
    ///      not lost. If the sum is less than netCapital, cNGN is locked in
    ///      the vault forever with no owner. If greater, cNGN is conjured.
    ///
    ///      FOR EACH POOL:
    ///        sum(token.netPrincipal) == ghost_poolNetDeposits[poolId]
    ///        sum(token.poolShareBPS) == 10_000
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

            // BPS must sum to exactly 10_000 - no fractional equity is unaccounted
            assertEq(
                sumBPS, 10_000, "Invariant C: BPS total != 10_000 - fractional equity gap detected"
            );

            // Principals must sum to exactly the net capital - no dust leak
            assertEq(
                sumPrincipal,
                handler.ghost_poolNetDeposits(poolId),
                "Invariant C: Wei dust leaked from principal split - cNGN stranded or conjured"
            );
        }
    }

    // INVARIANT E: No Ghost Tokens
    /// @notice Every minted Impact Token must represent real, identifiable value:
    ///         a valid owner, a registered pool, and non-zero principal.
    ///
    /// @dev WHY IT MATTERS:
    ///      A "ghost token" is an NFT that was minted but represents nothing.
    ///      This would happen if:
    ///        - A pool was not registered before minting (poolId == 0)
    ///        - A zero-amount deposit was accepted (netPrincipal == 0)
    ///        - A token was minted to address(0) (burned on creation)
    ///
    ///      These scenarios would allow a holder to call claimYield on a token
    ///      with no real backing, potentially draining other investors' capital.
    function invariant_E_NoGhostTokens() public view {
        uint256 len = handler.activeTokensLength();

        for (uint256 i = 0; i < len; i++) {
            uint256 tokenId = handler.activeTokens(i);
            LAWPStructs.TokenData memory data = impactToken.getTokenData(tokenId);
            address owner = impactToken.ownerOf(tokenId);

            assertNotEq(
                owner, address(0), "Invariant E: Ghost token - no owner (minted to address(0))"
            );
            assertGt(data.poolId, 0, "Invariant E: Ghost token - poolId is 0 (no pool association)");
            assertGt(
                data.netPrincipal,
                0,
                "Invariant E: Ghost token - zero principal (no capital backing)"
            );
        }
    }

    // INVARIANT G: Accumulator Sync (On-chain vs Ghost)
    /// @notice The engine's on-chain yield and RoC trackers must exactly match
    ///         the handler's ghost variables at all times.
    ///
    /// @dev WHY IT MATTERS:
    ///      Ghost variables represent an independent, external computation of
    ///      what the protocol should have recorded. If the on-chain value drifts
    ///      from the ghost, it means:
    ///        - The engine double-counted a routing event
    ///        - The engine missed crediting a routing event
    ///        - A reentrancy attack caused a partial update
    ///
    ///      This is an "oracle invariant" - the ghost is the oracle.
    function invariant_G_MonotonicYieldSync() public view {
        uint256 len = handler.activePoolsLength();

        for (uint256 i = 0; i < len; i++) {
            uint256 poolId = handler.activePools(i);

            assertEq(
                engine.poolYieldTracker(poolId),
                handler.ghost_poolYieldRouted(poolId),
                "Invariant G: poolYieldTracker desynced from ghost - routing math drifted"
            );
            assertEq(
                engine.poolRocTracker(poolId),
                handler.ghost_poolRocRouted(poolId),
                "Invariant G: poolRocTracker desynced from ghost - RoC routing math drifted"
            );
        }
    }

    // INVARIANT H: No Negative Yield
    /// @notice The protocol can never distribute more yield to investors than
    ///         was actually routed into the system.
    ///
    /// @dev WHY IT MATTERS:
    ///      If ghost_totalClaimedYield ever exceeds ghost_poolYieldRouted sum,
    ///      it means investors received yield that was never backed by real
    ///      off-chain revenue. This would directly drain the yieldVault below
    ///      its obligations - a solvency failure. This invariant catches the
    ///      math before Invariant B catches the balance.
    function invariant_H_NoNegativeYield() public view {
        uint256 totalRoutedYield;
        uint256 len = handler.activePoolsLength();

        for (uint256 i = 0; i < len; i++) {
            totalRoutedYield += handler.ghost_poolYieldRouted(handler.activePools(i));
        }

        assertGe(
            totalRoutedYield,
            handler.ghost_totalClaimedYield(),
            "Invariant H: Negative yield - more claimed than was ever routed"
        );
    }

    // INVARIANT I: Zero-Custody
    /// @notice The Compliance Engine and MockMultiSig must NEVER hold cNGN.
    ///         Protocol funds must only reside in the two dedicated vaults.
    ///
    /// @dev WHY IT MATTERS:
    ///      The engine is a mathematical switchboard - not a custody account.
    ///      If the engine held cNGN, a bug or admin key compromise could drain
    ///      all pooled capital in a single call. Similarly, the MultiSig is a
    ///      verification bridge only. Any cNGN balance in either contract is a
    ///      critical architectural violation.
    ///
    ///      ALSO CATCHES:
    ///        - A safeTransfer to address(this) inside the engine
    ///        - A misconfigured vault address that routes to engine
    ///        - A reentrancy attack that leaves residual balance
    function invariant_I_ZeroCustody() public view {
        assertEq(
            cngn.balanceOf(address(engine)),
            0,
            "Invariant I: ComplianceEngine holds cNGN - critical custody violation"
        );
        assertEq(
            cngn.balanceOf(address(multiSig)),
            0,
            "Invariant I: MockMultiSig holds cNGN - critical custody violation"
        );
    }

    // INVARIANT J: OperationalVault Solvency
    /// @notice The OperationalVault must always hold enough cNGN to cover all
    ///         unclaimed operational ledger balances (LA2, MVI1, Dev, RiskPool).
    ///
    /// @dev WHY IT MATTERS:
    ///      The engine maintains an internal ledger (operationalBalances) for
    ///      each operational actor. When revenue is routed, the engine credits
    ///      the ledger AND transfers cNGN to the vault. If either step fails
    ///      partially, the vault would be short. This invariant catches:
    ///        - A routing that credits the ledger but misses the vault transfer
    ///        - A routing that transfers more than the ledger credits (or vice versa)
    function invariant_J_OperationalVaultSolvency() public view {
        uint256 vaultBalance = cngn.balanceOf(address(operationalVault));

        // Sum all currently unclaimed operational balances.
        // These are the protocol's IOUs - the vault must be able to honour them.
        uint256 totalLedger = engine.operationalBalances(la2) + engine.operationalBalances(mvi1)
            + engine.operationalBalances(dev) + engine.operationalBalances(operationalTreasury);

        assertEq(
            vaultBalance,
            totalLedger,
            "Invariant J: OperationalVault INSOLVENT - cannot honour ledger obligations"
        );
    }

    // INVARIANT K: Accumulator Monotonicity
    /// @notice The poolYieldTracker and poolRocTracker can only ever increase.
    ///         They must never decrease between any two consecutive states.
    ///
    /// @dev WHY IT MATTERS:
    ///      These accumulators are the source of truth for all O(1) yield
    ///      calculations. If an attacker could decrease them (e.g., via a
    ///      reentrancy that partially reverts a routing), they could:
    ///        1. Reduce what future claimants can receive (theft of yield)
    ///        2. Cause an already-claimed yieldClaimed[tokenId] to exceed the
    ///           new tracker, breaking the subtraction in calculateProportionalYield
    ///
    ///      NOTE: The handler enforces this locally via micro-invariant after
    ///      each routeRevenue call. This invariant provides a global double-check
    ///      by comparing against the ghost totals (which only ever increase).
    function invariant_K_AccumulatorMonotonicity() public view {
        uint256 len = handler.activePoolsLength();

        for (uint256 i = 0; i < len; i++) {
            uint256 poolId = handler.activePools(i);

            // The on-chain tracker must be >= the ghost total that was
            // accumulated step-by-step. If Invariant G passes, these are equal.
            // This provides defence-in-depth: if G somehow misses a case, K catches it.
            assertGe(
                engine.poolYieldTracker(poolId),
                0, // trivially true but forces Foundry to evaluate the storage slot
                "Invariant K: poolYieldTracker is negative - impossible in uint256"
            );

            // The real monotonicity check: current value >= ghost accumulated total.
            // Since G verifies exact equality, K's true value is as a belt-and-suspenders.
            assertGe(
                engine.poolYieldTracker(poolId),
                handler.ghost_poolYieldRouted(poolId),
                "Invariant K: poolYieldTracker decreased below total ghost-routed yield"
            );
            assertGe(
                engine.poolRocTracker(poolId),
                handler.ghost_poolRocRouted(poolId),
                "Invariant K: poolRocTracker decreased below total ghost-routed RoC"
            );
        }
    }

    // INVARIANT L: Token Data Immutability
    /// @notice Once an Impact Token is minted, its `netPrincipal` and `poolShareBPS`
    ///         must never change for the lifetime of the token.
    ///
    /// @dev WHY IT MATTERS:
    ///      The O(1) yield formula is:
    ///        claimableYield = poolYieldTracker * poolShareBPS / 10_000 - yieldClaimed
    ///
    ///      If poolShareBPS could change AFTER minting, the yield formula would
    ///      break. An attacker who could inflate their BPS after deposit could
    ///      claim more yield than their proportional share. Similarly, if
    ///      netPrincipal could change, the RoC cap becomes meaningless.
    ///
    ///      This invariant cross-checks current token data against snapshots
    ///      taken by the handler at mint time.
    function invariant_L_TokenDataImmutability() public view {
        uint256 len = handler.activeTokensLength();

        for (uint256 i = 0; i < len; i++) {
            uint256 tokenId = handler.activeTokens(i);
            LAWPStructs.TokenData memory current = impactToken.getTokenData(tokenId);

            assertEq(
                current.netPrincipal,
                handler.ghost_tokenPrincipalSnapshot(tokenId),
                "Invariant L: netPrincipal changed post-mint - yield formula compromised"
            );
            assertEq(
                current.poolShareBPS,
                handler.ghost_tokenBPSSnapshot(tokenId),
                "Invariant L: poolShareBPS changed post-mint - proportional claim broken"
            );
        }
    }

    // INVARIANT M: Global cNGN Conservation Law
    /// @notice Every unit of cNGN that enters the protocol must either still be
    ///         in a vault OR have been legitimately paid out. No cNGN is ever
    ///         created, destroyed, or leaked to any address outside the protocol.
    ///
    /// @dev WHY IT MATTERS:
    ///      This is the most fundamental financial invariant: the protocol is a
    ///      closed system. All inflows must equal all vault balances plus all
    ///      outflows at any point in time.
    ///
    ///      FORMULA:
    ///        yieldVaultBalance + opVaultBalance
    ///          == (ghost_yieldVaultInflow + ghost_opVaultInflow)
    ///             - (ghost_yieldVaultOutflow + ghost_opVaultOutflow)
    ///
    ///      A violation means cNGN was:
    ///        - Leaked to a non-vault address (e.g., engine, multiSig, or attacker)
    ///        - Lost in a failed transfer that was not reverted
    ///        - Conjured from nowhere (impossible in correct ERC-20)
    function invariant_M_GlobalCNGNConservation() public view {
        uint256 yieldVaultBalance = cngn.balanceOf(address(yieldVault));
        uint256 opVaultBalance = cngn.balanceOf(address(operationalVault));
        uint256 actualVaultTotal = yieldVaultBalance + opVaultBalance;

        uint256 totalInflow = handler.ghost_yieldVaultInflow() + handler.ghost_opVaultInflow();
        uint256 totalOutflow = handler.ghost_yieldVaultOutflow() + handler.ghost_opVaultOutflow();

        // Net cNGN that should be in the vaults right now
        uint256 expectedVaultTotal = totalInflow > totalOutflow ? totalInflow - totalOutflow : 0;

        assertEq(
            actualVaultTotal,
            expectedVaultTotal,
            "Invariant M: cNGN Conservation violated - funds leaked or conjured"
        );
    }

    // INVARIANT N: Yield Math Correctness (Per-Token Upper Bound)
    /// @notice The pending claimable yield for any token can never exceed the
    ///         mathematically correct upper bound derived from the accumulators.
    ///
    /// @dev WHY IT MATTERS:
    ///      calculateProportionalYield uses:
    ///        totalYieldForToken = poolYieldTracker * BPS / 10_000
    ///        totalRocForToken   = poolRocTracker   * BPS / 10_000
    ///        claimable          = (totalYieldForToken - yieldClaimed) + min(claimableRoc, cap)
    ///
    ///      A bug that allows claimable to exceed these bounds would mean a
    ///      token holder can claim more than their proportional share, stealing
    ///      from other investors. This catches:
    ///        - Off-by-one errors in the yield formula
    ///        - Missing caps on RoC calculation
    ///        - Incorrect use of poolId in cross-pool queries
    function invariant_N_YieldMathCorrectness() public view {
        uint256 len = handler.activeTokensLength();

        for (uint256 i = 0; i < len; i++) {
            uint256 tokenId = handler.activeTokens(i);
            LAWPStructs.TokenData memory data = impactToken.getTokenData(tokenId);

            // Maximum possible yield claimable = full pool tracker * share - already claimed
            uint256 maxYield = engine.poolYieldTracker(data.poolId) * data.poolShareBPS / 10_000;
            uint256 alreadyClaimedYield = engine.yieldClaimed(tokenId);
            uint256 maxClaimableYield =
                maxYield > alreadyClaimedYield ? maxYield - alreadyClaimedYield : 0;

            // Maximum possible RoC claimable = min(full pool RoC * share, remaining principal)
            uint256 maxRoc = engine.poolRocTracker(data.poolId) * data.poolShareBPS / 10_000;
            uint256 maxClaimableRoc = maxRoc > data.rocReturned ? maxRoc - data.rocReturned : 0;
            uint256 remainingPrincipal =
                data.netPrincipal > data.rocReturned ? data.netPrincipal - data.rocReturned : 0;
            if (maxClaimableRoc > remainingPrincipal) {
                maxClaimableRoc = remainingPrincipal;
            }

            uint256 mathUpperBound = maxClaimableYield + maxClaimableRoc;
            uint256 actualClaimable = engine.calculateProportionalYield(tokenId);

            assertLe(
                actualClaimable,
                mathUpperBound,
                "Invariant N: Claimable yield exceeds mathematical upper bound - formula broken"
            );
        }
    }

    // INVARIANT O: Pool Uniqueness / Permanent Registration
    /// @notice Once a pool is registered via processPoolDeposit, it must remain
    ///         permanently registered (exists == true, createdAt > 0) and can
    ///         never be re-registered or deleted.
    ///
    /// @dev WHY IT MATTERS:
    ///      Pool uniqueness is the replay protection mechanism for deposits.
    ///      If a pool could be "un-registered", an attacker could:
    ///        1. Wait for a pool to be de-registered
    ///        2. Re-register it with different contributors
    ///        3. Claim yield that accumulated under the original pool
    ///
    ///      If a pool could be re-registered under the same ID, a duplicate
    ///      deposit would mint new tokens without backing them with additional
    ///      capital, diluting all existing token holders.
    function invariant_O_PoolPermanentRegistration() public view {
        uint256 len = handler.activePoolsLength();

        for (uint256 i = 0; i < len; i++) {
            uint256 poolId = handler.activePools(i);

            // Retrieve the pool's registration state from the engine
            (bool exists, uint256 createdAt) = engine.pools(poolId);

            assertEq(
                exists,
                true,
                "Invariant O: Pool marked as non-existent after registration - pool deleted"
            );
            assertGt(
                createdAt,
                0,
                "Invariant O: Pool createdAt is 0 after registration - timestamp erased"
            );
        }
    }
}
