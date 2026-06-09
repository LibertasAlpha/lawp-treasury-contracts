# Libertas Alpha Water Project (LAWP) v1.0.0

## Protocol Summary

The Libertas Alpha Water Project (LAWP) is an institutional-grade hybrid routing protocol designed to bridge real-world fiat revenue (via the Planbok system) with on-chain fractional Impact Equity. By separating asset custody from routing logic through a Zero-Custody Switchboard and Dual-Treasury Architecture, the protocol translates strict non-profit (LTD/GTE) legal mandates into impassable, immutable math. It features an O(1) continuous yield engine, direct Admin Safe governance, and cryptographically verified off-chain reporting to ensure transparency, solvency, and decentralized accountability.

**Additional documentation:**

- [Threat Model](https://github.com/LibertasAlpha/lawp-treasury-contracts/blob/main/docs/threat_model.md)
- [Testing Invariants](https://github.com/LibertasAlpha/lawp-treasury-contracts/blob/main/docs/invariants.md)
- [Rekt Test Answers](https://github.com/LibertasAlpha/lawp-treasury-contracts/blob/main/docs/rekt_test_answers.md)

## Key Features

- **Zero-Custody Switchboard:** The Compliance Engine holds a 0 balance, routing funds directly from the off-chain Relayer or Injector Wallet to specific vaults in a single hop.
- **Dual-Treasury Segregation:** Pure physical separation of Investor Funds (`LAWPYieldVault`) and Operational/Payroll Funds (`LAWPOperationalVault`).
- **100% Pull-over-Push Accounting:** Both investors and operational wallets (LA2, Dev) must proactively claim their funds. Operational wallet failures or blocklists can never block investor yields.
- **Trustless Revenue Routing:** Enforces strict mathematical splits for Initial Grants (30/50/20) and Continuous Grants (10/55/25/10) without manual intervention.
- **Atomic Transfer Hook (Double-Spend Protection):** Forcefully flushes pending yields upon ERC-721 token transfer, ensuring secondary market buyers receive a clean state.
- **Emergency Guardian Pattern:** The Admin Safe owner can instantly pause/unpause the system to mitigate potential exploits or systemic risks.
- **Fractional Dust Conservation:** Absorbs all wei rounding errors natively, mathematically guaranteeing 100% protocol solvency.
- **Immutable Settlement Token:** The cNGN token address is permanently fixed at deployment via `immutable` for all deposits, fees, and yield distributions.

## System Architecture

### Core Components

- **LAWPComplianceEngine (The Zero-Custody Switchboard)**
  - **Responsibility:** Calculates proportional equity, deducts systemic risk fees, and executes mathematical routing. Updates internal accounting ledgers and instructs the movement of tokens without holding funds.
  - **Key Functions:** `processPoolDeposit()`, `routeOperationalAllocation()`, `claimYield()`, `claimOperationalFunds()`

- **LAWPYieldVault (Vault A: Investor Funds)**
  - **Responsibility:** Subordinate vault holding Net Principal, Return of Contribution (RoC), and pending Yield. Contains no public deposit functions to prevent orphaned capital.
  - **Key Functions:** `executeTransfer()`

- **LAWPOperationalVault (Vault B: Protocol Funds)**
  - **Responsibility:** Subordinate vault holding Systemic Risk Fees, Dev splits, LA2, and MVI1 payouts. Contains no public deposit functions.
  - **Key Functions:** `executeTransfer()`

- **LAWPImpactToken (The Equity)**
  - **Responsibility:** ERC-721 implementation representing fractional ownership of a deployment pool. Houses the state-desync interception hook.
  - **Key Functions:** `mint()`, `updateRocReturned()`, `getTokenData()`, `_update()`

- **LAWPMultiSigController (The Bridge)**
  - **Responsibility:** An EIP-712 ECDSA verification engine. Validates off-chain signatures from the Operational Board to confirm real-world fiat generation before triggering the Compliance Engine.
  - **Key Functions:** `executeProposal()`, `getProposalDigest()`, `addSigner()`

- **LAWPActorRegistry (The Directory)**
  - **Responsibility:** Centralized registry for dynamic operational wallets (LA2, MVI1, Risk Pool, Dev Team) to allow updatability without migrating the Engine.
  - **Key Functions:** `setLA2Wallet()`, `setMVI1Wallet()`

### Component Interaction Flow

1. **Real World to Bridge**
   - Operators convert fiat from 3 segregated physical bank accounts (Activator, Service, RoC) to cNGN in the "Injector Wallet".
   - Board members observe a fiat to CNGN on-ramp in the Injector Wallet. They construct the EIP-712 payload (`proposalId`, `poolId`, `deadline`, etc.) and sign it locally.

2. **User (Relayer) -> LAWPMultiSigController**
   - Calls `executeProposal` with an EIP-712 payload containing signatures, the `poolId`, the generated `totalAmount`, and the `flowType`.

3. **LAWPMultiSigController -> LAWPMultiSigController (Internal)**
   - Validates the digest, checks the 3-of-5 signature threshold, and verifies cryptographic replay protection (nonce mapping).

4. **LAWPMultiSigController -> LAWPComplianceEngine**
   - Calls `routeOperationalAllocation()` with the validated revenue parameters.

5. **LAWPComplianceEngine -> Vaults & Internal Ledgers**
   - The Engine pulls the Yield portion directly from the Injector Wallet to the `LAWPYieldVault`.
   - The Engine pulls the Operational portion directly from the Injector Wallet to the `LAWPOperationalVault`.
   - Credits the O(1) `poolYieldTracker` (for investors) and the `operationalBalances` ledger (for operators).

6. **Final State**
   - Funds rest safely in the dual vaults.
   - Impact Token holders and Operational Teams must manually trigger claims to pull their respective balances permissionlessly.

### Example Execution

#### Yield Claim Process (Pull-over-Push)

1. User calls:

   ```solidity
     engine.claimYield(tokenId);
   ```

2. **LAWPComplianceEngine processes request:**
   - Queries `LAWPImpactToken` for the token's `poolId`, `poolShareBPS`, and `rocReturned`.
   - Computes total historical yield for the pool: `(poolYieldTracker[poolId] * poolShareBPS) / 10000`.
   - Subtracts the user's previously claimed yield: `totalHistorical - yieldClaimed[tokenId]`.

3. **Internal operations:**
   - Updates the user's `yieldClaimed` and `rocReturned` state to prevent re-entrancy and idempotency failures.
   - Executes cross-contract call to `LAWPYieldVault`.

- **Result:**
  - `LAWPYieldVault` pushes the exact cNGN amount to the user's wallet.
  - `YieldClaimed` event is emitted.

## State & Data Model

- **LAWPStructs.TokenData (Struct)**
  - **Description:** Tracks the exact fractional equity and RoC state of a contributor.
  - **Fields:** `uint256 netPrincipal`, `uint256 rocReturned`, `uint256 poolShareBPS`, `uint256 poolId`

- **LAWPStructs.Proposal (Struct - EIP-712)**
  - **Description:** Gas-optimized proposal structure for off-chain Multi-Sig payloads.
  - **Fields:** `uint96 totalRevenue`, `FlowType flowType`, `bool executed`, `uint40 submittedAt`

- **poolYieldTracker & poolRocTracker (Mappings)**
  - **Description:** The core of the O(1) Math Engine. Tracks the cumulative, all-time revenue/repayment routed to a specific `poolId` for Investors.

- **operationalBalances (Mapping)**
  - **Description:** Tracks the internal balance of specific operational wallets (e.g., LA2, Dev, Risk Pool) to facilitate pull-over-push.

## Invariants & Security Model

The protocol is mathematically secured by a Stateful Invariant Fuzzing suite (`LAWPInvariants.t.sol`) tested tested across 25,000 invariant runs with 250-depth state exploration and 10,000 fuzzing iterations.

- **Invariant A (RoC Ceiling):** A user's `rocReturned` can never exceed their `netPrincipal`.
- **Invariant B (Solvency Law):** The Vault balances will always equal or exceed the total outstanding un-claimed yield + total remaining RoC buffers.
- **Invariant C (Dust Conservation):** Fractional math must never leak a single wei. `Sum(netPrincipal) == GrossDeposit - RiskFee`.
- **Invariant D (The Transfer Hook):** Receiver's pending yield MUST evaluate to exactly 0 immediately post-transfer. Yield is not duplicated.
- **No Orphaned Capital:** Vaults lack public `deposit()` functions. All funds must pass through the Engine to be registered on an internal ledger.
- **Single-Asset Invariant:** The settlement token (cNGN) is `immutable`. All vault balances and cumulative accounting trackers are permanently denominated in this token, eliminating asset-accounting drift.
- **Vault Segregation:** `LAWPYieldVault` balance MUST always be >= Unclaimed Investor Liabilities. `LAWPOperationalVault` balance MUST always be >= Unclaimed Operational Liabilities.

### Failure Conditions

Reverts when:

- `LAWPImpactToken._update()`: The token transfer attempts to execute while the Compliance Engine is paused.
- `LAWPMultiSigController.executeProposal()`: Signatures are unordered (duplicate submission) or `v, r, s` malleability is detected.
- `LAWPComplianceEngine.processPoolDeposit()`: Basis points (`bpsShares`) array does not sum to exactly 10,000.
- `LAWPYieldVault.executeTransfer()` / `LAWPOperationalVault.executeTransfer()`: The caller is anyone other than the registered Compliance Engine.

## External Dependencies

- **OpenZeppelin Contracts v5.0.2**
  - **Purpose:** Provides highly audited foundational logic: `Ownable2Step`, `Pausable`, `ReentrancyGuard`, `ERC20`, `SafeERC20`, and `EIP712`.
- **cNGN Token (ERC20)**
  - **Usage:** The immutable fiat-backed stablecoin for all capital formation, risk fees, and yield distribution. Fixed at deployment — cannot be changed.

## Configuration

- **INITIAL_RISK_FEE_BPS**
  - **Description:** The systemic risk fee deducted from gross deposits to stabilize the ecosystem.
  - **Default:** 1000 (10%)
- **BOARD_SIZE & MULTISIG_THRESHOLD**
  - **Description:** Operational Board execution requirements.
  - **Default:** 5 Board Members, 3 Signatures Required.

## Getting Started

### Requirements

- Foundry (Forge, Cast, Anvil, Chisel)
- Solidity ^0.8.24
- Make

### Installation

```bash
git clone https://github.com/LibertasAlpha/lawp-treasury-contracts.git
cd lawp-treasury-contracts
forge install
```

### Environment Setup

Create `.env` file in the root directory:

```env
DEPLOYER_PRIVATE_KEY=your_deployer_private_key
ADMIN_SAFE_PRIVATE_KEY=0x...  # Private key for the Ownable2Step handover target (Admin Safe)
BASE_SEPOLIA_RPC=https://sepolia.base.org
BASESCAN_API_KEY=your_basescan_api_key

CNGN_TOKEN_ADDRESS=0x...
BASE_URI=ipfs://your-base-uri/
BOARD_SIGNER_1=0x...
BOARD_SIGNER_2=0x...
BOARD_SIGNER_3=0x...
BOARD_SIGNER_4=0x...
BOARD_SIGNER_5=0x...

LA2_WALLET=0x...
MVI1_WALLET=0x...
RISK_POOL_WALLET=0x...
DEV_WALLET=0x...
```

### Build

```bash
make build
```

### Test

Run the standard unit and integration testing suite:

```bash
make test
```

Run the heavy stateful invariant fuzzer (Ghost Variables & Parallel Truths):

```bash
make test-invariant
```

### Coverage

```bash
make coverage
```

### Deployment (Simulations & Live)

We utilize an Atomic Bootstrap Pattern to deploy and immediately wire all trust boundaries. `Configure.s.sol` completes the FULL Ownable2Step handover atomically — the deployer initiates with `transferOwnership()` and the Admin Safe accepts with `acceptOwnership()` within the same script execution. No separate manual step is required.

**Dry-Run / Simulate Deployments:**

```bash
make simulate-deploy-core
make simulate-configure
```

**Live Testnet Broadcasts:**

```bash
make deploy-core-testnet
make configure-protocol-testnet
```

## Notes & Variants

- For Emergency Pausing, use `engine.emergencyPause()` (Callable by the Multi-Sig).
- For Unpausing, use `engine.unpause()` (Callable only by the Admin/Owner).

## Roadmap

- [x] Phase 1-3: Engine, Vault, Equity Tokens, fractional math.
- [x] Phase 4: Off-Chain Verification (Multi-Sig & EIP-712).
- [x] Phase 5: Stateful Invariant Fuzzing & O(1) Gas Optimizations.
- [x] Phase 6: Direct Admin Safe Governance & Deployment Scripts.
- [x] Phase 7: Dual-Treasury & Switchboard Refactoring.
- [x] Phase 8: Immutable cNGN Settlement Token (single-asset invariant).
- [ ] Phase 9: External Independent Audit.
- [ ] Phase 10: Base Mainnet Launch.

## License

MIT License
