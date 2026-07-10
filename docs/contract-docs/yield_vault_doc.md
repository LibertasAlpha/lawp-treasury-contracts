# LAWPYieldVault

## Purpose

The `LAWPYieldVault` is a dedicated, non-custodial safe designed exclusively to securely hold Investor Yield and Return of Capital (RoC).

It acts as a physical holding pen for the underlying ERC20 tokens (cNGN) that are routed into the protocol from external real-world campaign treasuries, waiting to be claimed by Impact Token holders.

---

## Why does this contract exist?

To:

- Create a strict physical boundary between operational/campaign capital and investor returns.
- Safely accumulate routed dividends (yield) and returned principal (RoC).
- Allow the protocol to apply custom security logic (like investor lockups or KYC-gated withdrawals) to investor funds in the future without disrupting the Operational Vault.
- Eliminate the risk of the `LAWPComplianceEngine` being drained directly, as the engine holds no physical tokens itself.

It intentionally does **not** perform any fractional math or track user claims.

---

## Who owns it?

The protocol administrator (`Ownable2Step`).

Only the owner can:

- Link the vault to a specific `LAWPComplianceEngine`.

_Note: Ownership transfer requires a secure two-step confirmation process, and ownership can never be accidentally renounced._

---

## Who uses it?

Two primary actors:

### Investors / Token Holders

They:

- receive funds that are physically transferred out of this vault when they execute `claimYield()` on the Compliance Engine.

### External Campaign Treasuries

They:

- deposit raw cNGN into this vault when routing yield or RoC back into the protocol (authorized via the MultiSig Controller).

---

## Who calls it?

External callers:

- `LAWPComplianceEngine` -> `executeTransfer()`
- Admin -> `setComplianceEngine()`

> Note: While external treasuries send money to this vault, they do so directly via the ERC20 token contract, not by calling a function on the vault.

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

- The `LAWPComplianceEngine` is secure and its internal yield accumulators perfectly mirror the physical balance routed into this vault.
- The underlying `cNGNToken` behaves exactly according to the ERC20 standard (specifically regarding `safeTransfer`).

---

## What could break those assumptions?

Examples include:

- The `complianceEngine` address is accidentally updated to a malicious contract, allowing it to execute transfers and steal investor yield.
- Someone forcefully sends a non-standard token or physical ETH to this contract (which would be permanently stuck, as this vault only manages `cNGN`).

---

## Which contract trusts it?

## LAWPComplianceEngine

The engine trusts this vault to:

- hold investor dividends and returned capital securely.
- reliably execute physical ERC20 transfers when an investor claims their accumulated WAD-proportional yield.

---

## Which contracts does it trust?

The contract trusts:

- **LAWPComplianceEngine**: To be the exclusive and infallible decision-maker regarding when, where, and how much investor capital should leave the vault.
- **cNGNToken**: To physically move the tokens securely.

---

### What problem does it solve?

It solves the "Honeypot" and "Commingled Funds" problems.

Specifically it:

- Prevents a scenario where an exploit in operational payroll or campaign treasury routing accidentally drains investor yield.
- Ensures the `LAWPComplianceEngine` acts as an accounting ledger while this vault acts as the physical bank, adhering to strict separation of concerns.

---

### What data does it remember?

- Which contract is acting as the Compliance Engine.
- Which ERC20 token it manages.

It intentionally does **not** remember:

- Who deposited the funds, who the funds belong to, or how much any individual investor is owed (that belongs to the Impact Token and the Engine).

---

### What question can it answer?

Examples:

- Who is the current Compliance Engine?
- What token does this vault hold?

---

## Core Mathematics

Because this is purely a physical holding vault, it contains **zero mathematical transformations**.

It simply receives an `_amount` from the engine, and forwards that exact `_amount` to the ERC20 `safeTransfer` function. If the vault doesn't have enough tokens to fulfill the transfer, the underlying ERC20 contract will mathematically revert the transaction natively.
