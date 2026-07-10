# LAWPComplianceEngine

## Purpose

The `LAWPComplianceEngine` is the central financial and compliance hub of the protocol.

It handles capital deposits, exacts protocol risk fees, routes yield and return-of-capital (RoC) from external treasuries, and calculates the precise fractional payouts that investors can claim based on their Impact Token holdings.

---

## Why does this contract exist?

To:

- Process settled crowdfunding capital.
- Safely route operational risk fees to the protocol.
- Issue non-fungible fractional equity (Impact Tokens).
- Maintain immutable mathematical accumulators for yield distribution.
- Execute claim logic, ensuring no user can ever double-claim or extract unbacked funds.

It intentionally acts as the **only** entity that can instruct the token vaults to transfer funds back to users.

---

## Who owns it?

The protocol administrator (`Ownable`).

Only the owner can:

- Pause the entire protocol during emergencies.
- Migrate operational funds.
- Set the registry dependencies.

---

## Who uses it?

Two primary actors:

### Investors / Token Holders

They:

- claim accumulated yield and RoC on their tokens
- batch claim across multiple tokens

### Operational Treasury (Protocol)

They:

- claim accumulated risk fees and protocol revenue from the engine's internal ledger

---

## Who calls it?

External callers:

- `LAWPContributionPool` -> `processPoolDeposit()`
- Token Holders -> `claimYield()`, `claimYieldBatch()`
- Operational Treasury -> `claimOperationalFunds()`
- Admin -> `emergencyPause()`, `emergencyUnpause()`
- Anyone -> view functions (yield calculators)

---

## What data does it own?

## Pool Ledgers

- `poolTotalPrincipal`: Immutable starting net capital.
- `poolYieldTracker`: Monotonic accumulator of all yield ever routed to a pool.
- `poolRocTracker`: Monotonic accumulator of all RoC ever routed to a pool.

## Operational Ledgers

- `operationalBalances`: Pending claims for protocol revenue.

## Registration State

- `pools`: Registration flags indicating if a pool ID has been processed.

---

## What can change?

## At Deposit

- `poolTotalPrincipal` (written once)
- `operationalBalances` (increases)
- `pools` existence flag

## During Routing (via External MultiSig)

- `poolYieldTracker` (increases)
- `poolRocTracker` (increases)

## During Claims

- `operationalBalances` (decreases)
- The token's internal `claimedYield` and `claimedRoC` state via `ILAWPImpactToken(impactToken).claimYield()`

---

## What assumptions does it make?

The contract assumes:

- It is the sole spender authorized to move tokens out of `YieldVault` and `OperationalVault`.
- The `LAWPContributionPool` supplies a mathematically perfect WAD distribution where `Σ wadShares == 1e18`.
- The Impact Token contract correctly stores and returns `netPrincipal` and `poolShareWAD`.
- The token vaults actually hold the physical cNGN balances recorded in the engine's accumulators.

---

## What could break those assumptions?

Examples include:

- The token vaults are bypassed or drained directly by a compromised multisig.
- The Contribution Pool passes a corrupted array length.
- A fee-on-transfer token upgrade breaks the `actualReceived` delta measurement.

---

## Which contract trusts it?

## LAWPImpactToken

The token trusts this engine to:

- authorize minting of new equity tokens
- dictate when a token's `claimedYield` state should be updated

## LAWPContributionPool

The pool trusts this engine to:

- securely hold the deposited capital
- properly mint the corresponding tokens for its contributors

---

## Which contracts does it trust?

The contract trusts:

- **LAWPContributionPool**: To provide accurate contributor arrays and `1e18` WAD allocations.
- **LAWPImpactToken**: To enforce non-transferability correctly and supply accurate token metadata.
- **LAWPMultiSigController**: To securely authorize the external routing of new yield.

---

### What problem does it solve?

It solves non-custodial, mathematically sound dividend distribution.

Specifically it:

- Distributes yield to thousands of investors without looping (which would hit block gas limits).
- Prevents double-claiming.
- Enforces an immutable RoC ceiling (you can never be refunded more than the pool's principal).

---

### What data does it remember?

For every pool:

- Total principal
- Total historic yield routed
- Total historic RoC routed

It intentionally does **not** remember:

- How much an individual user has claimed (that belongs to the Impact Token).

---

### What question can it answer?

Examples:

- How much yield is a specific token ID currently owed?
- Has this pool hit its RoC ceiling?
- How much revenue is the protocol currently owed?

---

## Core Mathematics

The contract performs two highly critical mathematical transformations.

---

### 1. Capital Dust Absorption (Minting)

Just like the Contribution Pool absorbs WAD fraction dust, the Compliance Engine must absorb physical capital dust.

When `1,000,000` wei is split into three equal 33.33% WAD shares, the EVM calculates:
`333,333` wei each.
Total minted = `999,999` wei.
`1` wei is lost.

To prevent this, the engine forces the **last contributor in the array** to absorb the exact remaining balance.
If the engine fails to mint tokens exactly equal to `netCapital`, the transaction mathematically reverts.

---

### 2. Monotonic Yield Accumulators

Instead of tracking every single dividend payment to every single user, the engine uses **Monotonic Accumulators**.

#### The Relatable Scenario

Imagine a company tracking dividends. Instead of mailing checks every month, the company just keeps a public ledger saying: _"Since the beginning of time, this company has generated $1,000,000 in total historic profit."_

If you own 10% of the company, you know you are entitled to 10% of that historic total:
`$1,000,000 × 10% = $100,000`

If your personal record shows you have already claimed `$80,000` in the past, you know your _pending claimable balance_ is exactly `$20,000`.

#### The Code Formula

This is exactly how `calculateProportionalYield()` works in O(1) gas time:

```bash
Global Yield Entitlement = (poolYieldTracker[poolId] × token.poolShareWAD) ÷ 1e18
```

```bash
Currently Claimable = Global Yield Entitlement − token.yieldClaimed
```

Whenever new yield is routed to the pool, `poolYieldTracker` goes up. Your `Global Yield Entitlement` automatically goes up. When you claim, your `token.yieldClaimed` goes up to match it, bringing your `Currently Claimable` back to `0`.

This math makes it impossible to double-claim, and makes gas costs flat regardless of how many times yield is routed.
