# LAWP Treasury Contracts v1.0.0

## Protocol Summary

The Libertas Alpha Water Project (LAWP) is the foundational pilot Micro Venture Initiative (MVI) for the Libertas Alpha Network. It is engineered to transform local water consumption by establishing a profitable, scalable, and decentralized economic system bound to a non-profit mandate (aligned with SDGs 1, 6, 9, 12, and 17). The smart contracts establish a Multi-Signature Community Treasury that pools liquidity to fund real-world assets (water dispenser infrastructure). The protocol hard-codes financial flows to ensure transparent capital recovery (RoC) and continuous impact operational grants, issuing ERC721 Impact Tokens as receipts for measurable social achievement.

Additional documentation: [LAWP_WHITEPAPER](./LAWP_WHITEPAPER.md)

### Key Features

- **Real-World Asset (RWA) Liquidity Pooling**: Transparent aggregation of operational liquidity (cNGN) to fund physical water infrastructure.
- **Automated Yield Segregation**: Split-vault architecture that algorithmically routes pool settlements to fund capital recovery (RoC) and distribute operational surplus (e.g., to LA2, MVI1, and Human Nodes) as defined by the protocol's financial model.
- **Impact Equity System**: Issuance of ERC721 Impact Tokens that serve as immutable receipts for contributions and grant continuous yield rights.
- **Threshold-Gated Security**: Multi-signature consensus required to route operational surplus, ensuring decentralized treasury management.

---

## System Architecture

### Core Components

- **LAWPContributionPool**
  - Responsibility: Handles user contributions, campaign lifecycles (ACTIVE, SETTLED, CANCELLED), and refund logic.
  - Key Functions: `contribute()`, `settle()`, `claimRefund()`, `createPool()`

- **LAWPComplianceEngine**
  - Responsibility: Acts as the central orchestration and accounting hub, managing yield distributions, operational routing, and token integrations.
  - Key Functions: `processPoolDeposit()`, `claimYield()`, `routeOperationalAllocation()`

- **LAWPOperationalVault & LAWPYieldVault**
  - Responsibility: "Dumb" vaults that securely segregate operational funds from yield funds, isolated from direct user interaction.
  - Key Functions: `executeTransfer()`

- **LAWPImpactToken (ERC721)**
  - Responsibility: Tracks fractional pool ownership and cumulative Return of Capital (RoC) for each contributor.
  - Key Functions: `mint()`, `updateRocReturned()`

- **LAWPMultiSigController**
  - Responsibility: Validates threshold signatures from authorized operators to execute operational grants.
  - Key Functions: `executeProposal()`

---

## Component Interaction Flow

1. User -> `LAWPContributionPool`
   - Calls `contribute()` with a defined cNGN amount to fund an active campaign.

2. Campaign Manager -> `LAWPContributionPool`
   - Calls `settle()` once the pool timeframe completes successfully.

3. `LAWPContributionPool` -> `LAWPComplianceEngine`
   - Triggers `processPoolDeposit()` to segregate the funds.
   - Funds are routed to `LAWPOperationalVault` and `LAWPYieldVault` strictly according to the protocol's predefined surplus distribution model.

4. `LAWPComplianceEngine` -> `LAWPImpactToken`
   - Mints an ERC721 Impact Token to the contributor, entitling them to future yield.

5. Final State
   - The pool is SETTLED. Funds are secured in the vaults. Users hold Impact Tokens representing their capital recovery rights.

---

## Example Execution

### claimYield (Continuous Impact Grant)

1. User calls:

   ```solidity
   lawpComplianceEngine.claimYield(tokenId);
   ```

2. `LAWPComplianceEngine` processes request:
   - Validates that the caller is the owner of `tokenId`.
   - Calculates the accrued yield based on the token's fractional share of the pool and the total yield deposited since the last claim.
   - Updates `tokenYieldData` to prevent double-claiming.

3. Internal operations:
   - Calls `LAWPYieldVault.executeTransfer(user, amount)`.
   - Calls `LAWPImpactToken.updateRocReturned(tokenId, amount)`.

4. Result:
   - User receives cNGN yield directly to their wallet.
   - The token's accounting state is successfully updated without burning the ERC721 token.

---

## State & Data Model

- **Pool Struct**
  - Description: Tracks the lifecycle and financial state of a campaign.
  - Fields: `amountRaised`, `fundingGoal`, `startTime`, `endTime`, `state` (ACTIVE, SETTLED, CANCELLED).

- **TokenYieldData Mapping**
  - Description: Tracks yield accounting per ERC721 token.
  - Fields: `lastYieldAmount` (snapshot of global yield at last claim), `totalClaimed`.

---

## Invariants & Security Model

- Total amount raised in a pool perfectly matches the sum of all individual contributions (Conservation).
- Pool state strictly transitions from ACTIVE to SETTLED or CANCELLED, with no path backward (State Machine).
- Operational and Yield vault allocations always strictly respect the defined fractional split formula (Ratio).

### Failure Conditions

- Reverts when:
  - Contributing to a pool that is not `ACTIVE` or is outside its `endTime`.
  - Attempting to claim yield for an ERC721 token owned by another address.
  - Executing an operational proposal with fewer signatures than the MultiSig `threshold`.
  - The `LAWPComplianceEngine` is paused by Governance during an emergency.

---

## External Dependencies

- **cNGN (ERC20)**
  - Purpose: The underlying fiat-pegged stablecoin providing operational liquidity and representing real-world capital.

---

## Configuration

- **rocFeeBPS**
  - Description: Risk Fee deducted during capital recovery to fund system sustainability.
  - Default: `1000` (10%)

- **Threshold**
  - Description: Minimum number of authorized Operator signatures required to route operational funds.
  - Default: `3`

---

## Getting Started

### Requirements

- Foundry (Forge, Anvil, Cast)
- OpenZeppelin Contracts
- Solidity `0.8.30`
- Make

### Installation

```bash
git clone https://github.com/LibertasAlpha/lawp-treasury-contracts.git
cd lawp-treasury-contracts
forge install
```

### Environment Setup

Create `.env` file:

```bash
cp .env.sample .env
```

Ensure you configure your deployment private keys, RPC URLs, and wallet addresses as defined in the sample file.

---

## Build

```bash
make build
```

---

## Test

```bash
make test
```

---

## Coverage

```bash
forge coverage
```

---

## Deployment (Optional)

```bash
# Local Anvil deployment
make deploy-anvil

# Base Sepolia deployment
make deploy-base-sepolia
```

---

## Notes & Variants

- For operational treasury disbursements, use `executeProposal()` with valid EIP-712 threshold signatures.
- For emergency operations, Governance can use `emergencyPause()` on the Compliance Engine.

---

## License

MIT
