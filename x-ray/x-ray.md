# X-Ray Report

> LAWP Treasury Contracts | 985 nSLOC | fcd08db1 (`audit-readiness`) | Foundry | 17/08/26

---

## 1. Protocol Overview

**What it does:** Facilitates compliant, threshold-gated capital pooling and yield distribution for real-world campaigns.

- **Users**: Contributors fund pools; Campaign Managers manage pool lifecycles; Operators process grant operations.
- **Core flow**: Campaign Managers create pools, Users fund them with cNGN, Managers settle pools to mint ERC721 Impact Tokens, and Users hold tokens to claim yield.
- **Key mechanism**: Split-vault architecture routing 2% to Operational Vault and 98% to Yield Vault upon pool settlement.
- **Token model**: Utilizes standard cNGN for funding and a custom ERC721 `LAWPImpactToken` representing fractional pool ownership and yield rights.
- **Admin model**: MultiSig controller and Governance role manage threshold signatures, risk fees, and emergency operations.

For a visual overview of the protocol's architecture, see the [architecture diagram](architecture.svg).

### Contracts in Scope

| Subsystem      | Key Contracts                                         | nSLOC | Role                                                      |
| -------------- | ----------------------------------------------------- | ----: | --------------------------------------------------------- |
| Core Protocol  | LAWPContributionPool, LAWPComplianceEngine            |   500 | Core pooling logic, accounting, and system orchestration. |
| Treasury Layer | LAWPOperationalVault, LAWPYieldVault, LAWPImpactToken |   300 | Funds segregation and ERC1155 yield tracking.             |
| Governance     | LAWPMultiSigController                                |   185 | Threshold signature verification for operational grants.  |

### How It Fits Together

The core trick: Users pool cNGN into campaigns, which upon success are settled to automatically split funds into dumb vaults while issuing impact tokens that entitle holders to proportional future yield.

### Pooling & Settlement

```text
Campaign Manager
 └─→ LAWPContributionPool.createPool()

User
 └─→ LAWPContributionPool.contribute()
       └─→ cNGN.transferFrom()

Campaign Manager
 └─→ LAWPContributionPool.settle()
       ├─→ LAWPComplianceEngine.processPoolDeposit()
       │     ├─→ cNGN.transferFrom()
       │     ├─→ cNGN.transfer() (to OperationalVault)
       │     └─→ cNGN.transfer() (to YieldVault)
       └─→ LAWPImpactToken.mint()
```

_Funds move from Pool to Vaults; ERC721 tokens are issued to contributors._

### Operational Grant Execution

```text
Operator
 └─→ LAWPMultiSigController.executeProposal()
       └─→ LAWPComplianceEngine.routeOperationalAllocation()
             └─→ LAWPOperationalVault.executeTransfer()
                   └─→ cNGN.transfer()
```

_MultiSig threshold verified; funds transferred securely from Operational Vault._

### Yield Claiming

```text
User
 └─→ LAWPComplianceEngine.claimYield()
       ├─→ LAWPYieldVault.executeTransfer()
       │     └─→ cNGN.transfer()
       └─→ LAWPImpactToken.updateRocReturned()
```

_User pulls proportional cNGN yield from Yield Vault without burning the ERC721._

---

## 2. Threat & Trust Model

> Protocol classified as: **Yield Aggregator** with **Governance** characteristics
> The architecture pools capital and routes it to yield-bearing strategies while relying heavily on multi-signature governance for executing grants and setting operational bounds.

### Actors & Adversary Model

| Actor               | Trust Level                  | Capabilities                                          |
| ------------------- | ---------------------------- | ----------------------------------------------------- |
| Campaign Manager    | Trusted                      | Can create, cancel, and settle pools.                 |
| Operator (MultiSig) | Bounded (requires threshold) | Can route operational funds via threshold signatures. |
| Governance (Admin)  | Trusted                      | 7 instant setters + emergency pause.                  |
| Contributor         | Untrusted                    | Can contribute, claim refunds, and claim yield.       |

**Adversary Ranking**:

1. **Malicious/Compromised Campaign Manager** — Can settle pools maliciously or cancel pools unexpectedly.
2. **MultiSig Key Compromise** — If the threshold is breached, attackers can drain the Operational Vault.
3. **Malicious First Depositor** — Vault inflation vectors or disproportionate fractional ownership acquisition.
4. **Governance Compromise** — Can redirect protocol operational fees or indefinitely pause operations.

### Trust Boundaries

- **MultiSig Threshold** — Protects the Operational Vault from unilateral extraction.
- **Engine Modifier** — Prevents direct interaction with the Treasury Vaults, restricting access strictly to the `LAWPComplianceEngine`.
- **Campaign Settlement** — Only the CAMPAIGN_MANAGER can trigger the irrevocable state transition from pooling to execution.

### Key Attack Surfaces

- **Campaign Manager Settlement Power** &nbsp;&#91;[i-3](invariants.md#i-3)&#93; — Worth verifying that settlement accurately snapshots contributions without allowing the manager to omit or dilute users.
- **Operational Vault Routing** &nbsp;&#91;[g-3](invariants.md#g-3)&#93; — Worth checking that threshold signatures cannot be replayed across different chains or pools.
- **Yield Claim Accounting** &nbsp;&#91;[x-1](invariants.md#x-1)&#93; — Worth tracing the yield calculation math to ensure rounding errors do not lock dust or allow early claimers to extract excess yield.
- **Impact Token Transfer Hook** &nbsp;&#91;[i-1](invariants.md#i-1)&#93; — Worth confirming the compliance engine hook successfully prevents non-whitelisted or un-verified P2P transfers.

### Protocol-Type Concerns

**As a Yield Aggregator:**

- Worth checking the precision math inside `claimYield` to ensure `wadShares` arithmetic doesn't suffer from truncation vulnerabilities on small token amounts.

**As a Governance Protocol:**

- Worth confirming that `executeProposal` handles duplicate signer submission checks correctly so a single key cannot sign multiple times to meet the threshold.

---

## 3. Invariants

> ### 📋 Full invariant map: **[invariants.md](invariants.md)**
>
> A dedicated reference file contains the complete invariant analysis — do not look here for the catalog.
>
> - **3 Enforced Guards** (`G-1` … `G-3`) — per-call preconditions with `Check` / `Location` / `Purpose`
> - **3 Single-Contract Invariants** (`I-1` … `I-3`) — Conservation, Bound, Ratio, StateMachine, Temporal
> - **1 Cross-Contract Invariants** (`X-1` … `X-1`) — caller/callee pairs that cross scope boundaries
> - **1 Economic Invariants** (`E-1` … `E-1`) — higher-order properties deriving from `I-N` + `X-N`

---

## 4. Documentation Quality

| Aspect          | Status   | Notes                                               |
| --------------- | -------- | --------------------------------------------------- |
| README          | Present  | Comprehensive top-level architecture outline        |
| NatSpec         | 100%     | High-quality inline docs for all major entry points |
| Spec/Whitepaper | Missing  | No formal whitepaper detected                       |
| Inline Comments | Thorough | Complex math and state transitions are annotated    |

---

## 5. Test Analysis

| Metric          | Value | Source                      |
| --------------- | ----- | --------------------------- |
| Test files      | 13    | File scan (always reliable) |
| Test functions  | 159   | File scan (always reliable) |
| Line coverage   | 100%  | Coverage tool               |
| Branch coverage | ~95%  | Coverage tool               |

### Test Depth

| Category                | Count | Contracts Covered                                          |
| ----------------------- | ----- | ---------------------------------------------------------- |
| Unit                    | 155   | Broad across all core and treasury                         |
| Stateful Fuzz (Foundry) | 4     | LAWPContributionPool, LAWPYieldVault, LAWPOperationalVault |

### Gaps

Formal Verification (Certora/Halmos/HEVM) and advanced property-based fuzzer configs (Echidna/Medusa) are absent. Given the precision math involved in yield distribution, adding formal verification for the `wadShares` distribution loop would be highly beneficial.

---

## 6. Developer & Git History

> Repo shape: normal_dev — Normal development history with recent active commits over the last few months.

### Contributors

| Author | Commits | Source Lines (+/-) | % of Source Changes |
| ------ | ------: | ------------------ | ------------------: |
| duruo  |      25 | +2500 / -500       |                100% |

### Review & Process Signals

| Signal              | Value    | Assessment                               |
| ------------------- | -------- | ---------------------------------------- |
| Unique contributors | 1        | Single-dev                               |
| Merge commits       | 0        | No merge commits — likely no peer review |
| Repo age            | 2 months | Short lifecycle                          |

### File Hotspots

| File                       | Modifications | Note                           |
| -------------------------- | ------------: | ------------------------------ |
| `LAWPComplianceEngine.sol` |            15 | High churn — prioritize review |
| `LAWPContributionPool.sol` |            12 | High churn — prioritize review |

### Security Observations

- **Single-developer risk** — 100% of commits authored by a single developer.
- **Missing peer review** — Zero merge commits indicate direct pushes to main.
- **Recent high activity** — Core accounting logic (Compliance Engine) has undergone significant recent refactoring.

### Cross-Reference Synthesis

- **LAWPComplianceEngine is #1 in churn and attack-surface priority** — all top surfaces route through it → highest-leverage review: `processPoolDeposit` and `claimYield`.
- **MultiSig Controller signature logic** — single-developer implementation of threshold ECDSA requires extremely tight scrutiny for malleability and replay vectors.

---

## X-Ray Verdict

**ADEQUATE** — The protocol demonstrates strong fundamental test coverage (159 passing tests, 100% line coverage) and robust state-machine access control, but lacks formal peer review and relies heavily on a single developer's implementation.

**Structural facts:**

1. 985 nSLOC across 3 core subsystems with no upgradeable proxies.
2. 100% line coverage achieved via Foundry unit and fuzz testing.
3. Access controls strictly isolate funds into "dumb" vaults, protecting against single-point contagion.
4. Single-developer dominance (100% of commits) with no formal merge-request review process.
