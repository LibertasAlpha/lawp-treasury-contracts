# LAWP Frontend Product Specification

This document outlines the product requirements and technical architecture for the Libertas Alpha Water Project (LAWP) Frontend, focusing on actionable implementation details, role-based access, and smart contract integration boundaries.

---

## 1. Core Concepts & Math

- **WAD Fractional Equity:** Pool ownership is calculated using WAD (`1e18`) precision (e.g., `2e17 WAD = 20%`). The sum of all `poolShareWAD` in a pool strictly equals `1e18`.
- **Zero-Custody Engine:** The `LAWPComplianceEngine` routes revenue and enforces math but holds no funds.
- **Dual Vaults:** `LAWPOperationalVault` holds net campaign capital. `LAWPYieldVault` holds investor yield and RoC generated from off-chain revenue.
- **Impact Token (ERC-721):** Represents fractional pool ownership, storing `netPrincipal`, `poolShareWAD`, `poolId`, and `rocReturned`.

---

## 2. Portals & Workflows

### 2.1 Investor Portal (`app.lawp.io`)

**Goal:** Participate in funding pools, view portfolio, and claim yield/RoC.

**Workflows:**

1. **Capital Formation:** Users call `LAWPContributionPool.contribute(poolId, amount)` with cNGN.
2. **Claim Yield/RoC:** Users click "Claim", triggering `engine.claimYield(tokenId)` or `engine.claimRoC(tokenId)`.
   - _UX Rule:_ Disable claim buttons if pending balance is zero or system is paused.

### 2.2 Operational Board Portal (`board.lawp.io`)

**Goal:** Authorize fiat-backed revenue routing.

**Workflows:**

1. **Sign Payloads:** 5 trusted board members sign EIP-712 payloads (`poolId`, `amount`, `flowType`) verifying fiat generation.
2. **Execution:** Once the threshold (e.g., 3-of-5) is met, any relayer broadcasts `LAWPMultiSigController.executeProposal(..., signatures)`.

### 2.3 Admin Panel (`admin.lawp.io`)

**Goal:** System management and capital settlement.

**Workflows:**

1. **Manage Pools:** Admin creates pools via `LAWPContributionPool.createPool()`.
2. **Settle Capital:** Once a pool goal is met, Admin calls `LAWPContributionPool.settle(poolId)`. This automatically computes `wadShares` and triggers the Engine to mint Impact Tokens.
3. **Emergency Controls:** Admin can toggle `emergencyPause` via the Engine to freeze protocol flows.

---

## 3. Frontend Integration Map

### Key Read & Write Interfaces

| Contract                     | Key Reads                                          | Key Writes                                                |
| ---------------------------- | -------------------------------------------------- | --------------------------------------------------------- |
| **`LAWPContributionPool`**   | `getPool(id)`, `getContribution(poolId, user)`     | `contribute(id, amount)`, `settle(id)`, `claimRefund(id)` |
| **`LAWPImpactToken`**        | `balanceOf(user)`, `getTokenData(id)`              | _None (Minted by Engine)_                                 |
| **`LAWPComplianceEngine`**   | `poolYieldTracker(id)`, `paused()`, `riskFeeBPS()` | `claimYield(id)`, `claimRoC(id)`                          |
| **`LAWPMultiSigController`** | `nonce()`, `executedProposals(id)`                 | `executeProposal(..., signatures)`                        |

### UI & UX Guidelines

- **WAD Translation:** Never show "WAD" to users. Convert `poolShareWAD` to percentage: `(poolShareWAD * 100) / 1e18` (e.g., `20.00%`).
- **Idempotency Events:** Listen to `YieldClaimed`, `RocClaimed`, and `PoolSettled` events to update UI state without aggressive polling.
- **Error Handling:** Catch specific custom errors like `LAWPComplianceEngine_Paused` and `LAWPContributionPool_GoalNotMet` to show actionable toast notifications.
