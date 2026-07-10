# LAWPOperationalVault

## Purpose

The `LAWPOperationalVault` is a dedicated, non-custodial safe designed to securely isolate the protocol's operational and campaign capital from investor returns.

It acts as a physical holding pen for the underlying ERC20 tokens (cNGN) that belong to real-world campaigns, protocol risk fees, and payroll distributions.

---

## Why does this contract exist?

To:

- Create a strict physical boundary between investor yield and operational/campaign funds.
- Hold campaign capital securely until the Operational Treasury claims it.
- Allow the protocol to apply custom security, multisig, or vesting logic to operational funds in the future without disrupting the investor Yield Vault.
- Eliminate the risk of the `LAWPComplianceEngine` being drained directly, as the engine holds no physical tokens itself.

It intentionally does **not** perform any accounting, fee calculation, or fractional math.

---

## Who owns it?

The protocol administrator (`Ownable2Step`).

Only the owner can:

- Link the vault to a specific `LAWPComplianceEngine`.

_Note: Ownership transfer requires a secure two-step confirmation process, and ownership can never be accidentally renounced._

---

## Who uses it?

Two primary actors:

### The Protocol (via Operational Treasury)

They:

- receive funds that are physically transferred out of this vault when they execute a claim on the Compliance Engine.

### LAWPContributionPool

They:

- deposit raw cNGN into this vault upon the settlement of a successful crowdfunding campaign.

---

## Who calls it?

External callers:

- `LAWPComplianceEngine` -> `executeTransfer()`
- Admin -> `setComplianceEngine()`

> Note: While the Contribution Pool sends money to this vault, it does so directly via the ERC20 token contract, not by calling a function on the vault.

---

## What data does it own?

## Vault Configuration

- `complianceEngine`: The singular authorized orchestrator allowed to command this vault to move funds.
- `cNGNToken`: The immutable ERC20 settlement token.

---

## What can change?

## During Governance

- The authorized `complianceEngine` address can be updated by the owner.
- The owner of the vault itself can be transferred.

---

## What assumptions does it make?

The contract assumes:

- The `LAWPComplianceEngine` is secure and its internal pull-ledgers perfectly mirror the physical balance in this vault.
- The underlying `cNGNToken` behaves exactly according to the ERC20 standard (specifically regarding `safeTransfer`).

---

## What could break those assumptions?

Examples include:

- The `complianceEngine` address is accidentally updated to a malicious contract, allowing it to execute transfers and drain the vault.
- Someone forcefully sends a non-standard token or physical ETH to this contract (which would be permanently stuck, as this vault only manages `cNGN`).

---

## Which contract trusts it?

## LAWPComplianceEngine

The engine trusts this vault to:

- hold the funds securely.
- reliably execute physical ERC20 transfers when the engine's internal accounting says an actor is owed money.

---

## Which contracts does it trust?

The contract trusts:

- **LAWPComplianceEngine**: To be the exclusive and infallible decision-maker regarding when, where, and how much capital should leave the vault.
- **cNGNToken**: To physically move the tokens securely.

---

### What problem does it solve?

It solves the "Honeypot" and "Commingled Funds" problems.

Specifically it:

- Prevents a scenario where an exploit in investor yield routing accidentally drains campaign operational capital.
- Ensures the `LAWPComplianceEngine` acts as an accounting ledger while this vault acts as the physical bank, adhering to strict separation of concerns.

---

### What data does it remember?

- Which contract is acting as the Compliance Engine.
- Which ERC20 token it manages.

It intentionally does **not** remember:

- Who deposited the funds, who the funds belong to, or how much anyone is owed (that belongs to the Engine).

---

### What question can it answer?

Examples:

- Who is the current Compliance Engine?
- What token does this vault hold?

---

## Core Mathematics

Because this is purely a physical holding vault, it contains **zero mathematical transformations**.

It simply receives an `_amount` from the engine, and forwards that exact `_amount` to the ERC20 `safeTransfer` function. If the vault doesn't have enough tokens to fulfill the transfer, the underlying ERC20 contract will mathematically revert the transaction natively.
