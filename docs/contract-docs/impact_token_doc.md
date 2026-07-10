# LAWPImpactToken

## Purpose

The `LAWPImpactToken` contract represents the actual fractional equity held by contributors.

It is an ERC721 non-fungible token that acts as a secure receipt for pooled capital. It records how much principal a user backed, their exact percentage of the pool, and how much historic yield/RoC they have already claimed, preventing double-spending and ensuring accurate payouts.

---

## Why does this contract exist?

To:

- Mint ERC721 tokens to represent fractionalized ownership of an investment pool.
- Securely store individual `netPrincipal`, `poolShareWAD`, `yieldClaimed`, and `rocClaimed` for each token ID.
- Automatically force yield claims before a transfer occurs, preventing attackers from transferring tokens to steal un-claimed yield.

It intentionally does **not** calculate yield or hold capital. It is purely an accounting token.

---

## Who owns it?

The protocol administrator (`Ownable`).

Only the owner can:

- Set the `LAWPComplianceEngine` address.

---

## Who uses it?

Two primary actors:

### Investors / Token Holders

They:

- hold Impact Tokens in their wallets.
- transfer tokens securely (yield is auto-claimed upon transfer).

### LAWPComplianceEngine

They:

- mint new tokens.
- update `yieldClaimed` and `rocClaimed` ledgers.

---

## Who calls it?

External callers:

- `LAWPComplianceEngine` -> `mint()`, `claimYield()`
- Token Holders -> `safeTransferFrom()`, `safeBatchTransferFrom()`
- Admin -> `setComplianceEngine()`
- Anyone -> view functions (`getTokenData()`)

---

## What data does it own?

## Token Configuration

- `complianceEngine`: The authorized engine address.

## Token Accounting

- `_tokenData`: A mapping linking every `tokenId` to its specific `ImpactTokenData` struct.

---

## What can change?

## At Minting

- `netPrincipal` (written once per token ID)
- `poolShareWAD` (written once per token ID)
- `poolId` (written once per token ID)

## During Claims

- `yieldClaimed` (increases)
- `rocClaimed` (increases)

- `complianceEngine`

---

## What assumptions does it make?

The contract assumes:

- The `LAWPComplianceEngine` is the only entity that should be allowed to mint tokens or update claimed values.
- ERC721 standards are upheld.
- The `try/catch` wrapper around the pre-transfer yield claim will not revert if the engine behaves correctly.

---

## What could break those assumptions?

Examples include:

- The owner accidentally sets the `complianceEngine` to a malicious contract.
- The engine's claim logic unexpectedly reverts during a token transfer, causing the token to become permanently stuck in the sender's wallet.

---

## Which contract trusts it?

- **LAWPComplianceEngine**

The engine trusts this contract to:

- accurately return the `poolShareWAD` and `netPrincipal` when calculating yield.
- accurately save `yieldClaimed` and `rocClaimed` so the engine knows how much has already been paid out.
- reject mint requests from anyone other than the engine.

---

## Which contracts does it trust?

The contract trusts:

- **LAWPComplianceEngine**: To only mint tokens when actual capital is deposited, and to calculate yield payouts correctly during the `_update` pre-transfer hook.

---

### What problem does it solve?

It solves stateful fraction ownership and prevents the "Yield Sniper" exploit.

Specifically it:

- Ties complex struct data (`netPrincipal`, `poolShareWAD`) directly to an ERC721 non-fungible token.
- Prevents users from transferring a token to a new wallet to "reset" their claimed yield balance and double-claim from the same pool.

---

### What data does it remember?

For every minted token:

- Which pool it belongs to (`poolId`)
- The WAD percentage of the pool it represents (`poolShareWAD`)
- The raw cNGN capital backing it (`netPrincipal`)
- How much Yield the owner has withdrawn (`yieldClaimed`)
- How much Return of Capital the owner has withdrawn (`rocClaimed`)

It intentionally does **not** remember:

- How much yield the pool itself has generated (that belongs to the Engine).

---

### What question can it answer?

Examples:

- Who owns token ID 42?
- What percentage of pool 5 does token ID 42 represent?
- How much yield has the owner of token ID 42 already withdrawn?

---

## Core Mathematics

The contract's math is mostly limited to basic addition and subtraction during state updates, but it enforces a critical **Pre-Transfer Yield Accounting** protection mechanism.

---

### 1. The "Yield Sniper" Exploit Prevention

#### The Relatable Scenario

Imagine you own a winning lottery ticket that pays out $100 every month. You hold it for a year, claiming $1,200. Then, you hand the exact same ticket to your friend.
If the system only tracks "who is holding the ticket _right now_", your friend could walk up to the counter and say, _"I have never claimed any money on this ticket, give me my $1,200 for the past year!"_

The protocol would accidentally double-pay the $1,200.

#### The Code Solution

To prevent this, the `LAWPImpactToken` uses an ERC721 `_update()` hook that triggers **automatically every time a token is transferred**.

Before the token actually leaves the sender's wallet, the token contract automatically forces the `LAWPComplianceEngine` to claim any pending yield and RoC owed to the sender.

```solidity
// Inside the _update hook:
try ILAWPComplianceEngine(complianceEngine).claimYield(ids[i]) {} catch {}
```

This ensures the sender gets the money they rightfully earned while holding the token, and the `claimedYield` and `claimedRoC` trackers on the token are updated. When the recipient receives the token, the historic balances are already logged, preventing them from stealing the past yield!

The `try/catch` block ensures that if the engine is paused or empty, the transfer itself doesn't crash and lock the users' tokens.
