# LAWPActorRegistry

## Purpose

The `LAWPActorRegistry` contract acts as a centralized, immutable-like directory for the protocol's critical operational addresses.

It stores and manages the wallet addresses responsible for project management, systemic ecosystem growth, the main operational treasury, and the technical development team.

---

## Why does this contract exist?

To:

- Prevent hardcoding critical wallet addresses in the core logic contracts.
- Allow the protocol administrator to rotate compromised or obsolete operational wallets without needing to upgrade the core protocol contracts.
- Serve as a single source of truth so that the `LAWPComplianceEngine` knows exactly where to send protocol revenue and campaign capital.

It intentionally does **not** hold funds or execute transfers. It is purely a data directory.

---

## Who owns it?

The protocol administrator (`Ownable2Step`).

Only the owner can:

- Update the LA2 (Project Management) wallet.
- Update the MVI1 (System Treasury) wallet.
- Update the Operational Treasury wallet.
- Update the DApp Team (Dev) wallet.

_Note: Ownership transfer requires a secure two-step confirmation process, and ownership can never be accidentally renounced._

---

## Who uses it?

Two primary actors:

### Core Protocol Contracts (e.g., LAWPComplianceEngine)

They:

- query the registry during fee processing to know exactly which address should be credited with operational funds and net capital.

### The Administrator (Admin Safe)

They:

- manage the addresses stored in the registry to ensure operational security.

---

## Who calls it?

External callers:

- Admin -> `setLA2Wallet()`, `setMVI1Wallet()`, `setOperationalTreasuryWallet()`, `setDevWallet()`
- Core Contracts -> `la2Wallet()`, `mvi1Wallet()`, `operationalTreasuryWallet()`, `devWallet()`
- Anyone -> view functions to see current configurations

---

## What data does it own?

## Wallet Configurations

- `la2Wallet`: Responsible for operational stability and factory upkeep.
- `mvi1Wallet`: Responsible for governance and ecosystem funding.
- `operationalTreasuryWallet`: The primary custodian for campaign capital and systemic risk fees.
- `devWallet`: Responsible for continuous technical support and platform innovation.

---

## What can change?

## During Governance

- Any of the four wallet addresses can be updated by the owner.
- The owner of the contract itself can be transferred via the two-step process.

---

## What assumptions does it make?

The contract assumes:

- The owner (Admin Safe) is highly secure and will only update addresses to trusted, protocol-controlled wallets.
- The addresses provided are capable of receiving and managing ERC20 tokens or utilizing the protocol's internal ledger.

---

## What could break those assumptions?

Examples include:

- The Admin Safe is compromised, and an attacker changes the `operationalTreasuryWallet` to their own address, redirecting all future campaign capital and risk fees.
- An administrator accidentally sets a wallet to a smart contract address that cannot interact with the protocol (though zero-address checks exist).

---

## Which contract trusts it?

## LAWPComplianceEngine

The engine trusts this contract to:

- always provide the correct, currently authorized addresses when it is time to distribute risk fees or route net capital to the operational pull-ledger.

---

## Which contracts does it trust?

The contract trusts:

- None. It is a standalone registry that does not rely on external contract logic.

---

### What problem does it solve?

It solves the "Hardcoded Address" problem.

Specifically it:

- Decouples operational wallet management from complex financial logic.
- Ensures that if the development team or treasury structure changes in the future, the protocol can adapt seamlessly without requiring a complex migration of the `LAWPComplianceEngine`.

---

### What data does it remember?

- The current authorized address for 4 distinct operational roles.

It intentionally does **not** remember:

- How much money those addresses have earned or withdrawn.

---

### What question can it answer?

Examples:

- Where should the protocol send the development team's revenue share?
- Who is currently acting as the Operational Treasury?
- Has the MVI1 wallet address been rotated recently? (Via the `ActorUpdated` event).
