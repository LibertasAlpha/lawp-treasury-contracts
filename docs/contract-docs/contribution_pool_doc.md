# LAWPContributionPool

## Purpose

The `LAWPContributionPool` contract is the protocol's crowdfunding layer.

It aggregates cNGN contributions from multiple users into a single funding pool, computes each contributor's proportional ownership (WAD share), and deposits the pooled capital into the `LAWPComplianceEngine` for protocol processing and Impact Token issuance.

---

## Why does this contract exist?

To:

- Accept contributions from multiple contributors.
- Track contributor balances.
- Manage crowdfunding pools.
- Compute deterministic ownership percentages.
- Transfer pooled capital into the Compliance Engine once settlement conditions are met.

It intentionally does **not** calculate protocol fees or mint Impact Tokens.

---

## Who owns it?

The protocol administrator (`Ownable`).

Only the owner can:

- Create pools.
- Cancel pools.
- Settle pools.

Contributors have no administrative permissions.

---

## Who uses it?

Two primary actors:

### Contributors

They:

- contribute cNGN
- reclaim their contributions if the logic not met
- query their contributions
- query pool information

### Protocol Administrator

They:

- create funding pools
- cancel pools without funds
- settle successful pools

---

## Who calls it?

External callers:

- Contributors -> `contribute()`
- Contributors -> `claimRefund()`
- Owner -> `createPool()`
- Owner -> `cancelPool()`
- Owner -> `settle()`
- Anyone -> view functions

During settlement, this contract calls:

- `LAWPComplianceEngine.processPoolDeposit()`

---

## What data does it own?

## Pool configuration

- enginePoolId
- goal
- startTime
- endTime
- status

## Pool accounting

- totalRaised
- contributorCount

## Contributor records

- contribution amount
- WAD ownership share

## Contributor registry

- contributor address list

## Protocol state

- nextPoolId

---

## What can change?

## Pool creation

- nextPoolId
- new PoolConfig

## Contributions

- contributor amount
- contributorCount
- totalRaised
- contributor list

## Settlement

- contributor WAD shares
- pool status (`Open -> Settled`)

After settlement, contribution accounting becomes immutable.

---

## What assumptions does it make?

The contract assumes:

- cNGN behaves as a standard ERC20.
- The Compliance Engine is trusted.
- Engine pool IDs are valid.
- Contributions are recorded atomically.
- Contributor count never exceeds `MAX_CONTRIBUTORS`.
- Pool configuration is immutable after creation.
- Ownership shares always sum to exactly `1e18`.

---

## What could break those assumptions?

Examples include:

- Non-standard ERC20 behaviour.
- A compromised Compliance Engine.
- Incorrect registry configuration.
- Token proxy upgrades changing transfer semantics.
- Incorrect WAD calculations.
- Unexpected external contract behaviour.

---

## Which contract trusts it?

## LAWPComplianceEngine

The engine trusts this contract to provide:

- valid contributor addresses
- valid contribution amounts
- correctly computed WAD ownership
- contributor count within protocol limits

The engine validates that:

```bash
Σ wadShares == 1e18
```

but does **not** recompute ownership from contribution amounts.

---

## Which contracts does it trust?

The contract trusts:

- **LAWPComplianceEngine** To:
  - compute protocol fees
  - process deposits
  - mint Impact Tokens
  - maintain principal accounting

- **cNGN** To:
  - transfer tokens correctly
  - honour approvals

---

### What problem does it solve?

It solves decentralized pooled fundraising.

Specifically it:

- pools many contributors
- records contribution history
- computes proportional ownership
- forwards one aggregated deposit
- preserves ownership after protocol fees

---

### What data does it remember?

For every pool:

- configuration
- funding goal
- funding window
- contributors
- contributor amounts
- totalRaised
- contributorCount
- WAD ownership shares
- settlement status

It intentionally does **not** remember:

- protocol fees
- net capital
- Impact Tokens minted

Those belong to the Compliance Engine.

---

### What question can it answer?

Examples:

- Does pool X exist?
- Is pool X open?
- Has pool X settled?
- How much has pool X raised?
- Who contributed?
- How much did a contributor contribute?
- What ownership percentage does a contributor own?
- Has the goal been reached?
- Is the contribution window currently open?

---

## Core Mathematics

The contract performs **two mathematical transformations**.

---

### 1. Contribution -> Ownership (WAD)

Every contributor owns a fraction of the pool proportional to their contribution.

The contract represents ownership using **WAD precision**, where:

```bash
100% = 1e18
```

instead of floating-point numbers.

Formula:

```bash
wad = (amount × TOTAL_SHARES) ÷ totalRaised
```

where

```bash
TOTAL_SHARES = 1e18
```

### Why multiply first?

Solidity performs integer division.

This would be incorrect:

```bash
(amount ÷ totalRaised) × 1e18
```

Example:

```bash
250 ÷ 1000 = 0
```

which permanently loses precision.

Instead the contract computes:

```bash
(250 × 1e18) ÷ 1000 = 250000000000000000
```

which correctly represents:

```bash
25%
```

---

### Example

Pool:

```bash
Alice = 600 cNGN
Bob   = 400 cNGN

totalRaised = 1000
```

Ownership:

```bash
Alice = (600 × 1e18) ÷ 1000 = 600000000000000000
------------------------------------------------
Bob = (400 × 1e18) ÷ 1000 = 400000000000000000
```

Interpretation:

| Contributor |                WAD | Ownership |
| ----------- | -----------------: | --------: |
| Alice       | 600000000000000000 |       60% |
| Bob         | 400000000000000000 |       40% |

Total:

```bash
600000000000000000 + 400000000000000000 = 1000000000000000000
= 1e18
```

---

## 2. Rounding Dust Absorption

Integer division truncates decimals.

Example:

Three equal contributors:

```bash
1
1
1
```

Total:

```bash
3
```

Each contributor computes:

```bash
1e18 ÷ 3 = 333333333333333333
```

If every contributor is calculated independently:

```bash
333333333333333333 + 333333333333333333 + 333333333333333333
= 999999999999999999
```

Expected:

```bash
1000000000000000000
```

One ownership unit disappears.

To prevent ownership loss, the contract assigns the final contributor:

```bash
lastShare = TOTAL_SHARES − accumulatedShares
```

Example:

```bash
Contributor A = 333333333333333333

Contributor B = 333333333333333333

Accumulated = 666666666666666666
```

Last contributor:

```bash
1000000000000000000 − 666666666666666666 = 333333333333333334
```

Now:

```bash
333333333333333333 + 333333333333333333 + 333333333333333334
= 1000000000000000000
```

Exactly.

This guarantees:

```bash
Σ wadShares == 1e18
```

for every settled pool.

---

## Why use WAD instead of BPS?

Ownership requires extremely high precision.

BPS (`10000`) would zero-out very small contributors in sufficiently large pools.

WAD (`1e18`) preserves fractional ownership while remaining entirely integer-based.

Conversely, protocol fee calculations use **Basis Points (BPS)** because:

- fees are human-configurable percentages
- 0.01% precision is operationally sufficient
- lower precision reduces complexity
- BPS is the industry standard for financial protocols

Therefore the protocol intentionally uses:

| Purpose   |              Precision |
| --------- | ---------------------: |
| Ownership |           WAD (`1e18`) |
| Fees      | Basis Points (`10000`) |

This separation provides maximum ownership precision while keeping fee calculations simple and efficient.
