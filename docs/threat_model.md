# Libertas Alpha Water Project (LAWP) Threat Model

This document outlines the operational security, trust assumptions, and explicit mitigations embedded in the LAWP Smart Contract architecture. It is designed for auditors, technical integrators, and non-technical stakeholders (NGOs, Investors).

## 1. Executive Summary (For Stakeholders)

The Libertas Alpha Water Project operates on a hybrid model: fiat revenue is generated in the real world (via Planbok), and the resulting yield is distributed transparently on-chain. Because blockchains cannot naturally "see" the real world, the protocol must bridge these two environments securely.

**Our Core Security Philosophy:** Assume the bridge can be attacked, and build mathematical walls to contain the damage.

We separate authority into distinct, isolated layers to ensure no single entity can compromise the community:

- **The Treasury Vault (The Safebox):** Holds the money. It cannot think or make decisions.
- **The Compliance Engine (The Brain):** Calculates the math, distributes equity, and routes yield strictly according to the legal non-profit LTD/GTE splits. It is an unchangeable robot.
- **The Governance Boards (The Hands):** Humans who interact with the system. They are strictly divided into:
  - **Operational Board (Multi-Sig):** 5 trusted members who verify fiat deposits. They only have the power to tell the Engine that money has arrived, and act as an Emergency Guardian capable of instantly freezing the system if an exploit is detected.
  - **Admin Board (Safe + Timelock):** High-level guardians who can update systemic parameters (like changing a broken operational wallet) and unfreeze the protocol. They are bound by a 48-Hour Public Delay, giving the community time to veto or exit if they disagree with a decision.

## 2. Technical Architecture & Trust Boundaries

The system is designed with explicit trust boundaries. We enforce the principle of least privilege at the smart contract level:

- **The Compliance Engine is Trustless:** It relies entirely on immutable O(1) fractional math. It does not trust the Treasury, the Token, or the users.
- **The Treasury is Subordinate:** It trusts only the Compliance Engine. If the Admin Safe or the Deployer directly commands the Treasury to move funds, the transaction will revert.
- **The Multi-Sig Controller is Narrow:** It trusts off-chain EOAs (Externally Owned Accounts) to sign EIP-712 payloads. It is strictly limited to verifying ECDSA cryptography and preventing replay attacks. It has zero authority to alter economic splits.
- **The Timelock is the Ultimate Owner:** The Timelock strictly separates powers:
  - **Proposer & Canceller:** Granted to the 3-of-5 Admin Safe.
  - **Executor:** Granted to `address(0)` (Open Execution to prevent governance censorship).
  - **Admin:** The `DEFAULT_ADMIN_ROLE` (`0x00`) is permanently renounced by the deployer, locking out all backdoors.

## 3. Threat Vectors & Structural Mitigations

### A. Centralization & Admin Abuse (Rug Pull)

- **Threat:** A compromised founder key, or a rogue Admin Safe, attempts to drain the Treasury or alter the Systemic Risk Fee to 100%.
- **Mitigation:** Protocol ownership is locked behind an OpenZeppelin `TimelockController` with a mandatory 2 days delay. The execution role is open (`address(0)`), meaning if a valid proposal passes the 48-hour buffer, anyone can execute it, preventing the admin from censoring their own queued upgrades. If a malicious upgrade is queued, the community has 48 hours of on-chain warning to withdraw or react.

### B. Deployment & Setup Hijacking (The Deployment Trap)

- **Threat:** During contract deployment, the Timelock is initially configured with a 0-day delay, or the deployer accidentally retains hidden privileges (e.g., `CANCELLER_ROLE` or `DEFAULT_ADMIN_ROLE`), allowing them to bypass governance entirely post-launch.
- **Mitigation:** The protocol utilizes an Atomic Bootstrap Pattern. In a single transaction block, the deployment script executes an atomic batch that: 1) Accepts `Ownable2Step` ownership of all contracts, 2) Escalates the Timelock delay instantly to 48 hours, and 3) Explicitly renounces all Deployer roles (`PROPOSER`, `CANCELLER`, `EXECUTOR`, and `DEFAULT_ADMIN_ROLE`). Pre-flight and post-flight assertions guarantee the deployer is fully locked out before the transaction completes.

### C. Zero-Day Exploits vs. Governance Paralysis

- **Threat:** A zero-day exploit is discovered, but the 48-hour Timelock is too slow to stop the bleeding. Conversely, giving pause/unpause power directly to a multi-sig risks an indefinite hostage situation where admins freeze funds forever.
- **Mitigation:** The Emergency Guardian Pattern. The Operational Multi-Sig can trigger `emergencyPause()` instantly to halt capital formation and revenue routing. However, the Multi-Sig cannot unpause the system, upgrade contracts, or extract funds. Unpausing is strictly reserved for the Timelock (`onlyOwner`), requiring a 48-hour transparent governance window. This separates emergency response from administrative power.

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

- **Threat:** Solidity does not support floating-point numbers. Rounding errors in BPS (basis points) calculations during pool processing cause the protocol to route more funds than it actually possesses, rendering the system insolvent over time.
- **Mitigation:** The `_mintContributorShares` function operates on a "Remainder Absorption" pattern. The final contributor in the array receives `remainingCapital` rather than a recalculated BPS slice. The stateful invariant fuzzer (`LAWPInvariants.t.sol`) mathematically proves that `Sum(netPrincipal) == GrossDeposit - RiskFee` down to the exact wei.

## 4. Invariant Guarantees

Through rigorous Handler-based Stateful Fuzzing, the protocol has been mathematically proven to hold the following invariants under infinite chaotic interactions:

- **RoC Ceiling:** A user's `rocReturned` can never exceed their `netPrincipal`.
- **System Solvency:** The Treasury balance will always equal or exceed the total outstanding un-claimed yield + total remaining RoC buffers.
- **No Ghost Tokens:** Every token minted is backed by real capital and bound to a valid deployment pool.
- **Idempotency:** A user cannot claim yield twice without new revenue entering the system.
