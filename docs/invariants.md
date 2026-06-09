# LAWP Core Testing Invariants

This document serves as the absolute source of truth for the stateful testing suite of the Libertas Alpha Water Project (LAWP) Smart Contracts. If any test or chaotic fuzzing breaks these mathematical rules, the protocol is considered compromised.

## 1. Proportional Yield & The Pull-over-Push Pattern

**Definition:** The right to claim continuous "Human Node" yield and Return of Contribution (RoC) is strictly bound to the ownership of a specific ERC-721 Impact Token ID.

**Invariant (Total BPS):** The sum of `poolShareBPS` across all tokens minted for a specific `poolId` MUST strictly equal 10000 (100%).

**Invariant (State Desync / Double Spend):** A `claimableYield` must never be double-spent. The overriding of `transferFrom` (The Interception Hook) must guarantee that all pending yields are flushed to the outgoing owner, and the state reset to zero, before the token changes ownership.

## 2. Risk Fee Deduction & Flow Whitelisting

**Definition:** All deposits must pass through the systemic risk management layer.

**Invariant (Capital Lock):** The `netPrincipal` locked in the smart contract MUST equal `depositAmount - (depositAmount * riskFeeBPS / 10000)`.

**Invariant (Whitelisted Outflows):** No arbitrary withdrawals can occur. Outflows are strictly limited to:

- RoC (capped at 100% of `netPrincipal`)
- `GRANT_INITIAL` (30/50/20 split)
- `GRANT_CONTINUOUS` (10/55/25/10 split)

## 3. The "Dumb Vault" Separation

**Definition:** To minimize upgrade vulnerability and separate asset custody from business logic, the Vaults (`LAWPYieldVault` and `LAWPOperationalVault`) operate strictly as "Dumb Vaults."

**Invariant (Vault Subordination):** The Vaults hold 100% of the locked assets but contain zero routing logic. They MUST revert any execution command that does not originate explicitly from the authenticated `LAWPComplianceEngine`.

## 4. Formal Stateful Fuzzing Assertions (The Laws of Physics)

These invariants are explicitly asserted in `test/invariant/LAWPInvariants.t.sol` using a parallel-truth simulation (Ghost Variables) and are verified across 10,000+ randomized execution depths per CI run.

**Invariant A (RoC Ceiling):** A user's `rocReturned` can NEVER exceed their `netPrincipal`. Globally, `Sum(rocReturned) <= Sum(netPrincipal)`.

**Invariant B (Solvency Law / Bankruptcy Preventer):** The Vaults must ALWAYS have enough balance to cover every single un-claimed obligation. `VaultBalances >= (TotalNetDeposits + TotalYieldRouted) - (TotalClaimedYield + TotalClaimedRoC)`.

**Invariant C (Dust Conservation):** Fractional math must NEVER leak a single wei. `Sum(netPrincipal)` across all tokens in a pool must exactly equal `PoolGrossDeposit - RiskFee`. All remainder dust is natively absorbed by the final array index.

**Invariant D (The Transfer Hook):** Upon an ERC-721 token transfer:

- **D1 (Sender Correctness):** Sender's wallet must explicitly increase by the exact flushed yield and RoC.
- **D2 (Receiver Correctness):** Receiver's pending yield MUST evaluate to exactly 0 immediately post-transfer.
- **D3 (No Duplication):** The total yield claimable globally across the transfer remains completely constant.

**Invariant E (No Ghost Tokens):** Every minted token must represent real value (`netPrincipal > 0`), belong to a valid pool (`poolId > 0`), and exist in a real user's wallet (`owner != address(0)`).

**Invariant F (Claim Idempotency):** Calling `claimYield` twice in a row without new revenue entering the system must evaluate to exactly 0 for the second claim.

**Invariant G (Monotonic Yield Tracking):** The Compliance Engine's internal cumulative ledgers (`poolYieldTracker`, `poolRocTracker`) must never drift or skew from the external parallel-truth simulation.

**Invariant H (No Negative Yield):** The protocol can NEVER distribute more yield than what was globally routed to it by the Multi-Sig Operational Board.

**Invariant I (Single-Asset Settlement):** The settlement token (`cNGNToken`) is permanently fixed at deployment via Solidity's `immutable` keyword. No on-chain mechanism exists to alter it. All vault balances, cumulative yield/RoC trackers, and operational ledgers are denominated in this single asset. This structurally prevents asset-accounting drift between recorded state and physical vault holdings.
