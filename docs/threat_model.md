# Libertas Alpha Water Project (LAWP) Threat Model

This document outlines the operational security, trust assumptions, and explicit mitigations embedded in the LAWP Smart Contract architecture. It is designed for auditors, technical integrators, and non-technical stakeholders (NGOs, Investors).

## 1. Executive Summary (For Stakeholders)

The Libertas Alpha Water Project operates on a hybrid model: fiat revenue is generated in the real world (via Planbok), and the resulting yield is distributed transparently on-chain. Because blockchains cannot naturally "see" the real world, the protocol must bridge these two environments securely.

**Our Core Security Philosophy:** Assume the bridge can be attacked, and build mathematical walls to contain the damage.

We separate authority into distinct, isolated layers to ensure no single entity can compromise the community:

- **The Treasury Vault (The Safebox):** Holds the money. It cannot think or make decisions.
- **The Compliance Engine (The Brain):** Calculates the math, distributes equity, and routes yield strictly according to the legal non-profit LTD/GTE splits. It is an unchangeable robot.
- **The Governance Boards (The Hands):** Humans who interact with the system. They are strictly divided into:
  - **Operational Board (Multi-Sig):** Five trusted members who verify fiat deposits. Their only authority is to inform the Engine that funds have been received.
  - **Admin Board (Safe):** High-level guardians who can update system parameters (e.g., replacing a compromised operational wallet), freeze the system if an exploit is detected, and unfreeze the protocol when appropriate. They control the Admin Safe and are the ultimate owners of all protocol contracts through Ownable2Step.

## 2. Technical Architecture & Trust Boundaries

The system is designed with explicit trust boundaries. We enforce the principle of least privilege at the smart contract level:

- **The Compliance Engine is Trustless:** It relies entirely on immutable O(1) fractional math. It does not trust the Treasury, the Token, or the users.
- **The Treasury is Subordinate:** It trusts only the Compliance Engine. If the Admin Safe or the Deployer directly commands the Treasury to move funds, the transaction will revert.
- **The Multi-Sig Controller is Narrow:** It trusts off-chain EOAs (Externally Owned Accounts) to sign EIP-712 payloads. It is strictly limited to verifying ECDSA cryptography and preventing replay attacks. It has zero authority to alter economic splits.
- **The Admin Safe is the Ultimate Owner:** All six protocol contracts (Registry, YieldVault, OperationalVault, ImpactToken, Engine, MultiSig) are owned by the Admin Safe via `Ownable2Step`. The Admin Safe holds the exclusive authority to:
  - Update systemic parameters (risk fee, registry wallets).
  - Wire or re-wire trust boundaries (engine <-> vaults).
  - Pause and Unpause the system.

## 3. Threat Vectors & Structural Mitigations

### A. Centralization & Admin Abuse (Rug Pull)

- **Threat:** A compromised Admin Safe key attempts to drain the Treasury or alter the Systemic Risk Fee to 100%.
- **Mitigation:** Protocol contracts can only perform admin operations through the Admin Safe via the `onlyOwner` modifier. The Treasury Vaults are subordinate - they only respond to the Compliance Engine (`onlyComplianceEngine`). Even if the Admin Safe is compromised, it cannot directly extract funds from the vaults. It can only alter parameters (fee, registry wallets), giving token holders and the community time to observe suspicious on-chain transactions.

### B. Deployment & Setup Hijacking (The Deployment Trap)

- **Threat:** During contract deployment, the deployer retains hidden ownership privileges, allowing them to bypass the Admin Safe post-launch.
- **Mitigation:** The protocol utilizes the `Ownable2Step` pattern. During `Configure.s.sol`, the deployer calls `transferOwnership(adminSafe)` on all six contracts, setting the Admin Safe as `pendingOwner`. The deployer's ownership is completely stripped during configuration - `Configure.s.sol` initiates `transferOwnership(adminSafe)` and then completes the handover by calling `acceptOwnership()` on behalf of the Admin Safe. Pre-flight assertions confirm `pendingOwner == adminSafe` on every contract before the script exits.

### C. Zero-Day Exploits vs. Governance Paralysis

- **Threat:** A zero‑day exploit is discovered but the governance process is too slow to stop the bleeding. Conversely, giving pause/unpause power to a single externally owned account (EOA) risks an immediate, unilateral freeze of user funds.

- **Mitigation:** Both `emergencyPause()` and `unpause()` are controlled exclusively by the **Admin Safe** (the contract owner).
  - The Admin Safe is a **multisig wallet** (e.g., a Gnosis Safe) with its own threshold and signers.
  - This means pausing and unpausing **always require multiple, independent signatures**, not a single key.
  - No separate MultiSig Controller contract is needed for these actions - the ownership structure itself provides the required collective security.

  Because the Admin Safe's internal threshold is carefully chosen (e.g., 3-of-5 core team members), the protocol avoids both the paralysis of a slow governance vote and the existential risk of a single compromised key.

### D. The Secondary Market Double-Spend (Yield Duplication)

- **Threat:** User A accumulates 500 cNGN in pending yield. User A sells their Impact Token to User B. User B attempts to claim the historical 500 cNGN, while User A also attempts to claim it.
- **Mitigation:** The protocol utilizes a state-desync Interception Hook inside `LAWPImpactToken._update()`. Before ownership transfers, the hook queries the Engine. If yield exists, it is forcefully flushed to the outgoing owner (User A), and the token's mathematical state is reset. User B receives a token with exactly 0 pending yield. (Proven via Invariant D).

### E. Off-Chain Signature Replay Attacks

- **Threat:** A malicious relayer intercepts a valid revenue signature from the Operational Board (e.g., $10,000 generated) and submits it to the blockchain 50 times to drain the vault.
- **Mitigation:** The `LAWPMultiSigController` utilizes EIP-712 domain separation. It hashes a unique, monotonically increasing `proposalId` into the digest. Execution flips `executedProposals[digest]` to true. Re-submission of the same signature block will revert with `LAWPMultiSigController_ProposalAlreadyExecuted`.

### F. Gas Griefing & Denial of Service (DoS)

- **Threat:** An attacker creates a deployment pool with 15,000 micro-contributors, or submits 500 signatures to the Multi-Sig, causing block-gas-limit Out-of-Gas (OOG) reverts that freeze the protocol permanently.
- **Mitigation:** Strict hard-coded upper bounds. `MAX_CONTRIBUTORS` is capped at 20. `MAX_SIGNERS` is capped at 20. `MAX_BATCH_CLAIM` is capped at 20. Furthermore, yield calculation uses O(1) Cumulative Trackers rather than iterating over historical events, mathematically guaranteeing O(1) gas cost for claims regardless of protocol age.

### G. Insolvency via Fractional Dust

- **Threat:** Solidity does not support floating-point numbers. Rounding errors in WAD (`1e18`) fractional calculations during pool processing cause the protocol to route more funds than it actually possesses, rendering the system insolvent over time.
- **Mitigation:** The `_mintContributorShares` function operates on a "Remainder Absorption" pattern. The final contributor in the array receives `remainingCapital` rather than a recalculated WAD slice. The stateful invariant fuzzer (`LAWPInvariants.t.sol`) mathematically proves that `Sum(netPrincipal) == GrossDeposit - RiskFee` down to the exact wei.

## 4. Invariant Guarantees

Through rigorous Handler-based Stateful Fuzzing, the protocol has been mathematically proven to hold the following invariants under infinite chaotic interactions:

- **RoC Ceiling:** A user's `rocReturned` can never exceed their `netPrincipal`.
- **System Solvency:** The Vault balances will always equal or exceed the total outstanding un-claimed yield + total remaining RoC buffers.
- **No Ghost Tokens:** Every token minted is backed by real capital and bound to a valid deployment pool.
- **Idempotency:** A user cannot claim yield twice without new revenue entering the system.
