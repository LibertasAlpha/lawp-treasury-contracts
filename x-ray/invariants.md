# Invariant Map

> LAWP Treasury Contracts | 3 guards | 3 inferred | 0 not enforced on-chain

---

## 1. Enforced Guards (Reference)

### G-1

`require(block.timestamp <= pool.endTime)` · `LAWPContributionPool.sol:230` · Ensures contributions are only accepted during the active campaign window.

#### G-2

`require(pool.state == PoolState.ACTIVE)` · `LAWPContributionPool.sol:229` · Ensures users cannot contribute to cancelled or settled pools.

#### G-3

`require(signatures.length >= threshold)` · `LAWPMultiSigController.sol:112` · Enforces the minimum signer threshold for operational grant execution.

---

## 2. Inferred Invariants (Single-Contract)

### I-1

`Conservation` · On-chain: **Yes**

> The total amount raised in a pool must equal the sum of all individual contributions.

**Derivation** — Δ-pair: `pool.amountRaised += amount` ↔ `contributions[user] += amount` in `contribute()`.

**If violated** — The pool would be undercollateralized at settlement, leading to systemic insolvency when routing funds to the operational and yield vaults.

#### I-2

`Ratio` · On-chain: **Yes**

> Operational and Yield Vault allocations perfectly split the pooled funds according to the 2% / 98% rule.

**Derivation** — guard-lift: `_operationalAmount = (_grossAmount * 200) / 10000; _yieldAmount = _grossAmount - _operationalAmount;`

**If violated** — Operational treasury receives incorrect funding or yield vault becomes underfunded, affecting user claim redemptions.

#### I-3

`StateMachine` · On-chain: **Yes**

> Pool state transitions strictly from ACTIVE to SETTLED or CANCELLED, with no path back to ACTIVE.

**Derivation** — edge: `PoolState.ACTIVE → PoolState.SETTLED` in `settle()`.

**If violated** — A settled pool could be re-opened or re-settled, causing double-minting of impact tokens or double-counting of yield.

---

## 3. Inferred Invariants (Cross-Contract)

### X-1

On-chain: **Yes**

> The Engine assumes the Yield Vault has sufficient cNGN balance to cover yield claims based on the `tokenYieldData` accounting.

**Caller side** — `LAWPComplianceEngine.sol:402` — Engine calls `yieldVault.executeTransfer(user, amount)`.

**Callee side** — `LAWPYieldVault.sol:80` — Vault performs `cNGN.transfer(to, amount)`.

**If violated** — Yield claims revert due to insufficient balance, trapping user returns.

---

## 4. Economic Invariants

### E-1

On-chain: **Yes**

> Yield redemptions are 1:1 backed by cNGN in the Yield Vault, maintaining systemic solvency for contributors.

**Follows from** — I-1 + I-2 + X-1

**If violated** — The protocol defaults on yield payments to impact token holders.
