# LAWPMultiSigController

## Purpose

The `LAWPMultiSigController` contract is the cryptographic gatekeeper of the protocol.

It handles the secure routing of Yield and Return of Capital (RoC) from external off-chain treasuries (or admin Safes) into the protocol's internal ledgers. It ensures that no funds are routed without cryptographic proof from an authorized set of administrators using EIP-712 typed data signatures.

---

## Why does this contract exist?

To:

- Validate multi-signature approvals for sensitive financial actions.
- Provide a secure bridge between off-chain decision making (e.g., Gnosis Safe) and on-chain protocol execution.
- Prevent replay attacks using unique, auto-incrementing nonces.
- Protect the `LAWPComplianceEngine` from unauthorized or malicious yield routing.

It intentionally does **not** hold funds or calculate WAD percentages. It purely verifies signatures and forwards verified commands.

---

## Who owns it?

There is no traditional `Ownable` owner. Instead, authority is decentralized across the `authorizedSigners` array.

Only a threshold (e.g., 3 out of 5) of these authorized signers can:

- Route new yield to a pool.
- Route new RoC to a pool.

---

## Who uses it?

Two primary actors:

### Authorized Signers

They:

- sign EIP-712 structured payloads off-chain authorizing financial routing.

### Executors / Relayers

They:

- take the off-chain signatures and submit them on-chain via `routeYield()` or `routeRoc()`.
- Anyone can be a relayer, because the security relies entirely on the signatures, not the `msg.sender`.

---

## Who calls it?

External callers:

- Any Relayer -> `routeYield()`, `routeRoc()`
- Anyone -> view functions (`isSigner()`, `getDomainSeparator()`)

During execution, this contract calls:

- `LAWPComplianceEngine.routeYield()`
- `LAWPComplianceEngine.routeRoc()`

---

## What data does it own?

## Cryptographic Configuration

- `DOMAIN_SEPARATOR`: Immutable EIP-712 domain hash binding signatures to this specific contract and chain.
- `authorizedSigners`: A list of addresses whose signatures are valid.
- `THRESHOLD`: The minimum number of valid signatures required to execute an action.

## Security State

- `nonces`: A mapping tracking the next valid nonce for any given pool ID to prevent signature replay.

---

## What can change?

## During Routing

- `nonces` (increases by 1 per successful execution)

## Registration State

- Nothing. Signers and Thresholds are immutable once the contract is deployed.

---

## What assumptions does it make?

The contract assumes:

- The provided signatures were generated using standard Ethereum ECDSA (Elliptic Curve Digital Signature Algorithm).
- The `LAWPComplianceEngine` will correctly update its ledgers when the `routeYield` or `routeRoc` functions are called.
- Signers keep their private keys secure.

---

## What could break those assumptions?

Examples include:

- A private key of an authorized signer is compromised.
- An attacker generates signatures with `v` values outside the `{0, 1, 27, 28}` boundaries if not properly normalized.
- A chain fork occurs, though the `DOMAIN_SEPARATOR` includes the `block.chainid` to protect against cross-chain replays.

---

## Which contract trusts it?

## LAWPComplianceEngine

The engine trusts this contract to:

- absolutely guarantee that only threshold-approved routing requests ever reach the engine.
- safely filter out unauthorized actors.

Because of this, the engine's `routeYield` and `routeRoc` functions use the `onlyMultiSig` modifier.

---

## Which contracts does it trust?

The contract trusts:

- **LAWPComplianceEngine**: To actually execute the ledger updates once the cryptographic verification has succeeded.

---

### What problem does it solve?

It solves the "Single Point of Failure" problem for routing external capital.

Specifically it:

- Eliminates the risk of a single compromised admin wallet draining or inflating the protocol's ledgers.
- Standardizes off-chain approvals using the EIP-712 standard (which allows human-readable signing in wallets like MetaMask).
- Prevents "Signature Replay Attacks" where an attacker takes a valid signature from yesterday and resubmits it today.

---

### What data does it remember?

For every pool:

- The next required cryptographic `nonce`.

It intentionally does **not** remember:

- How much yield was routed (that belongs to the Engine).

---

### What question can it answer?

Examples:

- Is address X an authorized signer?
- What is the current nonce for pool Y?
- What is the EIP-712 Domain Separator for this contract?

---

## Core Mathematics

The contract's math is focused purely on Cryptography and Combinatorics.

---

### 1. EIP-712 Signature Verification

EIP-712 is a standard for hashing typed data. Instead of signing a random string of hex code, signers sign a structured JSON object.

The contract reconstructs exactly what the signer saw by hashing the data in a specific order:

```bash
Hash = keccak256( DomainSeparator + HashStruct(poolId, amount, nonce) )
```

It then uses `ecrecover` to extract the public address from the provided signature. If the extracted address matches one of the `authorizedSigners`, the signature is valid.

---

### 2. The Signature Array Verification

#### The Relatable Scenario

Imagine a bank vault that requires 3 different managers to turn their keys simultaneously. If manager A, manager C, and manager D turn their keys, the vault opens. If manager A tries to turn their key three times, the vault stays locked.

#### The Code Implementation

The contract requires an array of signatures to be submitted. To prevent an attacker from submitting the **same** valid signature multiple times to hit the threshold, the contract enforces two rules:

1. **Uniqueness:** The extracted signer address must be strictly greater than the previous signer address (`currentOwner > lastOwner`). This mathematically forces the signatures to be submitted in ascending order of the signer's wallet address.
2. **Threshold Counting:** The array of signatures must have exactly `THRESHOLD` number of valid items.

If the signatures are valid, the unique `nonce` for that pool is incremented (`nonces[poolId]++`), meaning those exact signatures are now permanently void and can never be used again.
