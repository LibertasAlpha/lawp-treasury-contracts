# Libertas Alpha Water Project (LAWP) v1.0.0

## Protocol Summary

The Libertas Alpha Water Project (LAWP) is an institutional-grade hybrid routing protocol designed to bridge real-world fiat revenue (via the Planbok system) with on-chain fractional Impact Equity. By separating asset custody from routing logic, the protocol translates strict non-profit (LTD/GTE) legal mandates into impassable, immutable math. It features an O(1) continuous yield engine, a 48-hour Timelock governance layer, and cryptographically verified off-chain reporting to ensure transparency, solvency, and decentralized accountability.

**Additional documentation:**

- [Threat Model]("https://github.com/LibertasAlpha/lawp-treasury-contracts/blob/main/docs/threat_model.md")
- [Testing Invariants]("https://github.com/LibertasAlpha/lawp-treasury-contracts/blob/main/docs/invariants.md")
- [Rekt Test Answers]("https://github.com/LibertasAlpha/lawp-treasury-contracts/blob/main/docs/rekt_test_answers.md")

## Key Features

- **Trustless Revenue Routing:** Enforces strict mathematical splits for Initial Grants (30/50/20) and Continuous Grants (10/55/25/10) without manual intervention.
- **O(1) Yield Claiming (Pull-over-Push):** Completely eliminates gas-limit DoS vulnerabilities; claiming gas costs remain constant regardless of protocol scale or age.
- **Atomic Transfer Hook (Double-Spend Protection):** Forcefully flushes pending yields upon ERC-721 token transfer, ensuring secondary market buyers receive a clean state.
- **Emergency Guardian Pattern:** The Operational Multi-Sig can instantly pause the system to stop exploits, but cannot unpause or extract funds (unpausing requires a 48-hour Timelock vote).
- **Fractional Dust Conservation:** Absorbs all wei rounding errors natively, mathematically guaranteeing 100% protocol solvency.

## System Architecture

### Core Components

- **LAWPComplianceEngine (The Brain)**
  - **Responsibility:** Calculates proportional equity, deducts systemic risk fees, and executes the mathematical routing splits for all revenue flows.
  - **Key Functions:** `processPoolDeposit()`, `validateAndRoute()`, `claimYield()`, `claimYieldBatch()`

- **LAWPTreasury (The Vault)**
  - **Responsibility:** Subordinate "Dumb Vault" that custodies all cNGN assets. Reverts any transaction not explicitly commanded by the Compliance Engine.
  - **Key Functions:** `deposit()`, `executeTransfer()`, `routeRiskFee()`

- **LAWPImpactToken (The Equity)**
  - **Responsibility:** ERC-721 implementation representing fractional ownership of a deployment pool. Houses the state-desync interception hook.
  - **Key Functions:** `mint()`, `updateRocReturned()`, `getTokenData()`, `_update()`

- **LAWPMultiSigController (The Bridge)**
  - **Responsibility:** An EIP-712 ECDSA verification engine. Validates off-chain signatures from the Operational Board to confirm real-world fiat generation before triggering the Compliance Engine.
  - **Key Functions:** `executeProposal()`, `getProposalDigest()`, `addSigner()`

- **LAWPActorRegistry (The Directory)**
  - **Responsibility:** Centralized registry for dynamic operational wallets (LA2, MVI1, Risk Pool, Dev Team) to allow updatability without migrating the Engine.
  - **Key Functions:** `setLA2Wallet()`, `setMVI1Wallet()`

- **TimelockController (The Governor)**
  - **Responsibility:** OpenZeppelin v5 48-hour delay queue. Owns all protocol contracts and protects the community from malicious admin upgrades.
  - **Key Functions:** `scheduleBatch()`, `executeBatch()`

## Component Interaction Flow

1. **User (Community Board) → LAWPMultiSigController**
   - Calls `executeProposal` with an EIP-712 payload containing signatures, the `poolId`, the generated `totalAmount`, and the `flowType`.

2. **LAWPMultiSigController → LAWPMultiSigController (Internal)**
   - Validates the digest, checks the 3-of-5 signature threshold, and verifies cryptographic replay protection (nonce mapping).

3. **LAWPMultiSigController → LAWPComplianceEngine**
   - Calls `validateAndRoute()` with the validated revenue parameters.

4. **LAWPComplianceEngine → LAWPTreasury & Internal Ledgers**
   - Updates the O(1) `poolYieldTracker` or `poolRocTracker` for the given pool.
   - Instructs the `LAWPTreasury` to physically transfer the operational splits (LA2, MVI1, Dev) directly to their respective wallets.

5. **Final State**
   - Operational wallets receive their immediate capital.
   - Impact Token holders' `calculateProportionalYield()` instantly reflects their new pending balances, ready to be pulled permissionlessly.

## Example Execution

### Yield Claim Process (Pull-over-Push)

1. User calls:

   ```solidity
   engine.claimYield(tokenId);
   ```

2. `LAWPComplianceEngine` processes request:
   - Queries `LAWPImpactToken` for the token's `poolId`, `poolShareBPS`, and `rocReturned`.
   - Computes total historical yield for the pool: `(poolYieldTracker[poolId] * poolShareBPS) / 10000`.
   - Subtracts the user's previously claimed yield: `totalHistorical - yieldClaimed[tokenId]`.

3. **Internal operations:**
   - Updates the user's `yieldClaimed` and `rocReturned` state to prevent re-entrancy and idempotency failures.
   - Executes cross-contract call to `LAWPTreasury`.

4. Result:
   - `LAWPTreasury` pushes the exact cNGN amount to the user's wallet.
   - `YieldClaimed` event is emitted.

## State & Data Model

- `LAWPStructs.TokenData` (Struct)
  - **Description:** Tracks the exact fractional equity and RoC state of a contributor.
  - **Fields:** `uint256 netPrincipal`, `uint256 rocReturned`, `uint256 poolShareBPS`, `uint256 poolId`

- `LAWPStructs.Proposal` (Struct - EIP-712)
  - **Description:** Gas-optimized proposal structure for off-chain Multi-Sig payloads.
  - **Fields:** `uint96 totalRevenue`, `FlowType flowType`, `bool executed`, `uint40 submittedAt`

- `poolYieldTracker` & `poolRocTracker` (Mappings)
  - **Description:** The core of the O(1) Math Engine. Tracks the cumulative, all-time revenue routed to a specific `poolId`.

## Invariants & Security Model

The protocol is mathematically secured by a Stateful Invariant Fuzzing suite (`LAWPInvariants.t.sol`) tested across 10,000+ depths per run.

- **Invariant A (RoC Ceiling):** A user's `rocReturned` can never exceed their `netPrincipal`.
- **Invariant B (Solvency Law):** The Treasury balance will always equal or exceed the total outstanding un-claimed yield + total remaining RoC buffers.
- **Invariant C (Dust Conservation):** Fractional math must never leak a single wei. `Sum(netPrincipal) == GrossDeposit - RiskFee`.
- **Invariant D (The Transfer Hook):** Receiver's pending yield MUST evaluate to exactly 0 immediately post-transfer. Yield is not duplicated.

### Failure Conditions

Reverts when:

- `LAWPImpactToken._update()`: The token transfer attempts to execute while the Compliance Engine is paused.
- `LAWPMultiSigController.executeProposal()`: Signatures are unordered (duplicate submission) or `v, r, s` malleability is detected.
- `LAWPComplianceEngine.processPoolDeposit()`: Basis points (`bpsShares`) array does not sum to exactly 10,000.
- `LAWPTreasury.executeTransfer()`: The caller is anyone other than the registered Compliance Engine.

## External Dependencies

- **OpenZeppelin Contracts v5.0.2**
  - **Purpose:** Provides highly audited foundational logic: `TimelockController`, `Ownable2Step`, `Pausable`, `ReentrancyGuard`, `ERC20`, `SafeERC20`, and `EIP712`.
- **cNGN Token (ERC20)**
  - **Usage:** The primary fiat-backed stablecoin utilized for all capital formation, risk fees, and yield distribution.

## Configuration

- **TIMELOCK_MIN_DELAY**
  - **Description:** The minimum delay before a queued governance proposal can be executed.
  - **Default:** 2 days (172,800 seconds)
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
PRIVATE_KEY=your_private_key
BASE_SEPOLIA_RPC=https://sepolia.base.org
BASESCAN_API_KEY=your_basescan_api_key

CNGN_TOKEN_ADDRESS=0x...
BASE_URI=ipfs://your-base-uri/

ADMIN_SAFE_ADDRESS=0x...
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

We utilize an Atomic Bootstrap Pattern to secure the deployment, instantly accepting `Ownable2Step` transitions and locking out the deployer in a single block.

**Dry-Run / Simulate Deployments:**

```bash
make simulate-deploy-mocks
make simulate-deploy-core
make simulate-configure
```

**Live Testnet Broadcasts:**

```bash
make deploy-mocks-testnet
make deploy-core-testnet
make configure-protocol-testnet
```

## Notes & Variants

- For Emergency Pausing, use `engine.emergencyPause()` (Callable by the Multi-Sig).
- For Unpausing, use `engine.unpause()` (Callable only by the Timelock).
- For Governance Upgrades, use `timelock.scheduleBatch()` followed by `timelock.executeBatch()` 48 hours later.

## Roadmap

- [x] Phase 1-3: Engine, Treasury, Equity Tokens, fractional math.
- [x] Phase 4: Off-Chain Verification (Multi-Sig & EIP-712).
- [x] Phase 5: Stateful Invariant Fuzzing & O(1) Gas Optimizations.
- [x] Phase 6: Institutional Timelock Governance & Deployment Scripts.
- [ ] Phase 7: External Independent Audit.
- [ ] Phase 8: Base Mainnet Launch.

## License

MIT License
