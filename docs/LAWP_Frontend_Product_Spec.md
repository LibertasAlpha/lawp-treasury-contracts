# LAWP Frontend Product Specification

## Libertas Alpha Water Project v1.0.0

**Audience:** Frontend Engineers & UI/UX Designers  
**Status:** Implementation-Ready  
**Blockchain:** Base (EVM-compatible, ERC-20 settlement via cNGN)  
**Last Updated:** June 2026

---

> [!IMPORTANT]
> This document is the single source of truth for all UI decisions in the LAWP ecosystem. Every screen, action, and data point described here maps directly to a verified smart contract function or on-chain state. Do not invent assumptions beyond what is documented - every user action that touches the blockchain must match the contract signatures exactly.

---

## Table of Contents

1. [Protocol Overview for Frontend Engineers](#1-protocol-overview-for-frontend-engineers)
2. [User Personas & Stakeholder Roles](#2-user-personas--stakeholder-roles)
3. [Application Surfaces (Apps)](#3-application-surfaces-apps)
4. [Navigation Structure & Information Architecture](#4-navigation-structure--information-architecture)
5. [Screens & Pages](#5-screens--pages)
   - [5A. Investor Portal](#5a-investor-portal)
   - [5B. Operational Board Portal](#5b-operational-board-portal)
   - [5C. Admin / Protocol Governance Panel](#5c-admin--protocol-governance-panel)
6. [UI Modules & Reusable Components](#6-ui-modules--reusable-components)
7. [Wallet & Transaction Interactions](#7-wallet--transaction-interactions)
8. [Deposit, Yield, RoC & Claiming Experiences](#8-deposit-yield-roc--claiming-experiences)
9. [Operational Actor Workflows](#9-operational-actor-workflows)
10. [Admin / MultiSig / Governance Interactions](#10-admin--multisig--governance-interactions)
11. [Data Displayed Per Screen](#11-data-displayed-per-screen)
12. [Permissions & Access Boundaries](#12-permissions--access-boundaries)
13. [System States](#13-system-states)
14. [Notifications, Edge Cases & Error Handling](#14-notifications-edge-cases--error-handling)
15. [Mobile & Desktop Responsiveness](#15-mobile--desktop-responsiveness)
16. [Security & Trust Indicators](#16-security--trust-indicators)
17. [Recommended Frontend Architecture](#17-recommended-frontend-architecture)
18. [Contract Reference Quick-Map](#18-contract-reference-quick-map)

---

## 1. Protocol Overview for Frontend Engineers

LAWP is a **hybrid on-chain/off-chain treasury protocol** for a real-world water infrastructure project. It bridges fiat NGN revenue (processed through a system called Planbok) into on-chain yield distributions for contributors.

### The Mental Model

Think of LAWP as a **legally-constrained revenue vending machine**:

1. **Investors contribute cNGN** (a fiat-backed Nigerian Naira stablecoin) into a named "pool" that funds a physical water deployment (e.g., a campus borehole project).
2. In return they receive an **ERC-721 Impact Token** - a non-fungible bearer asset encoding their fractional ownership percentage (`poolShareBPS`) and original contribution (`netPrincipal`).
3. The physical deployment generates **real-world fiat revenue**. The Operational Board (5 members) observes this off-chain, signs an EIP-712 payload, and a relayer submits it on-chain.
4. The **Compliance Engine** mathematically splits and routes this revenue into two isolated treasury vaults:
   - **Yield Vault** -> receives the "collective" investor share
   - **Operational Vault** -> receives payroll shares for LA2, MVI1, Dev
5. Investors **pull** their accrued yield + Return of Contribution (RoC) by calling `claimYield(tokenId)`.

### Key Terms Glossary

| Term                      | Definition                                                                                                                                     |
| ------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| **cNGN**                  | The immutable ERC-20 settlement token (fiat-backed Nigerian Naira). All values are in cNGN.                                                    |
| **Pool**                  | A deployment project (e.g., FUTO Campus Borehole). Has a unique integer `poolId`. Created once; never deleted.                                 |
| **Impact Token**          | ERC-721 NFT representing fractional equity in a pool. Holds `netPrincipal`, `poolShareBPS`, `poolId`, `rocReturned`.                           |
| **netPrincipal**          | The investor's gross deposit minus the 10% risk fee. This is the RoC ceiling - they can never receive more RoC than this.                      |
| **poolShareBPS**          | Basis points (0–10000) encoding the token holder's fractional share of the pool's yield. E.g., 2000 BPS = 20%.                                 |
| **poolYieldTracker**      | Global cumulative yield routed to a pool. Used in O(1) math to compute each token's claimable amount.                                          |
| **poolRocTracker**        | Global cumulative RoC routed to a pool.                                                                                                        |
| **Yield**                 | Continuous income from revenue routing that the investor earns indefinitely beyond their principal recovery.                                   |
| **RoC**                   | Return of Contribution - the investor's original principal being returned. Hard-capped at `netPrincipal`.                                      |
| **GRANT_INITIAL**         | First fiat-to-cNGN routing event. Split: 30% Collective (Yield Vault), 50% LA2 (Operational Vault), 20% MVI1 (Operational Vault).              |
| **GRANT_CONTINUOUS**      | Recurring fiat-to-cNGN routing event. Split: 10% Collective, 55% LA2, 25% MVI1, 10% Dev.                                                       |
| **RoC Flow**              | 100% routes to Yield Vault as return of principal. Cannot exceed pool's `poolTotalPrincipal`.                                                  |
| **Risk Fee**              | 10% deducted from gross deposits at deposit time. Credited to Operational Treasury.                                                            |
| **Pull-over-Push**        | Investors and operational actors must actively call `claimYield` / `claimOperationalFunds` - funds are never pushed automatically.             |
| **Interception Hook**     | Automatic yield flush that fires when an Impact Token is transferred (sold/gifted). Prevents secondary buyers from stealing accumulated yield. |
| **Admin Safe**            | A Gnosis Safe multisig wallet that owns all 6 protocol contracts. Only entity that can pause/unpause, update fees, manage signers.             |
| **Operational Board**     | 5 EOA signers who co-sign EIP-712 revenue proposals. Threshold: 3-of-5.                                                                        |
| **Relayer / Coordinator** | The entity that submits signed proposals on-chain and holds the cNGN being routed.                                                             |

---

## 2. User Personas & Stakeholder Roles

### 2.1 Personas

#### Persona A - The Investor / Contributor

- **Who:** An individual or institution that has deposited cNGN into a LAWP pool.
- **Access level:** Holds at least one Impact Token (ERC-721) in their wallet.
- **Primary goals:** View their token portfolio, track pending yield and RoC, claim earnings.
- **Technical comfort:** May be non-technical. Familiar with crypto wallets (MetaMask, WalletConnect). Does NOT need to understand BPS math - the UI must translate it into plain language.
- **Primary app:** Investor Portal.

#### Persona B - The Board Member / Signer

- **Who:** One of the 5 Operational Board members registered in `LAWPMultiSigController.isSigner`.
- **Access level:** Their wallet address returns `true` for `isSigner(address)`.
- **Primary goals:** Review pending revenue routing proposals, sign them via EIP-712 typed data.
- **Technical comfort:** Understands crypto wallets and governance workflows. Does NOT write code.
- **Primary app:** Operational Board Portal.

#### Persona C - The Coordinator / Relayer

- **Who:** A protocol coordinator (often also a board member). Creates proposals and executes them once the threshold is met. Must hold the cNGN to be routed and approve the Compliance Engine as a spender.
- **Access level:** Same as board member (registered `isSigner`). Identifiable via role metadata in the backend.
- **Primary goals:** Create proposals, track signature collection, execute proposals on-chain, manage cNGN approvals.
- **Primary app:** Operational Board Portal (with extended Coordinator tab).

#### Persona D - The Admin / Protocol Owner

- **Who:** The Admin Safe (Gnosis Safe multisig). In practice, 3–5 senior team members holding the Safe's keys.
- **Access level:** Contract owner (`Ownable2Step`). Only entity that can call `onlyOwner` functions.
- **Primary goals:** Emergency pause/unpause, update risk fee, manage Actor Registry wallets, add/remove board signers, update MultiSig threshold.
- **Technical comfort:** High. Comfortable with Gnosis Safe UI and direct contract interactions.
- **Primary app:** Admin Panel (or Gnosis Safe UI directly, augmented by a read-only monitoring dashboard).

#### Persona E - The Operational Actor (LA2 / MVI1 / Dev / Operational Treasury)

- **Who:** Wallets registered in `LAWPActorRegistry`. Receive splits from revenue routing.
- **Access level:** Their wallet address has a non-zero `operationalBalances[address]` in the Compliance Engine.
- **Primary goals:** View their claimable operational balance, trigger `claimOperationalFunds()`.
- **Primary app:** Investor Portal (dedicated "Operational Claim" section accessible to registered wallets) or a separate lightweight page within the Admin Panel.

### 2.2 Role-Permission Matrix

| Capability                  |    Investor    | Board Member | Coordinator | Operational Actor | Admin Safe |
| --------------------------- | :------------: | :----------: | :---------: | :---------------: | :--------: |
| View pool data              |       ✓        |      ✓       |      ✓      |         ✓         |     ✓      |
| View Impact Token portfolio |    ✓ (own)     |   ✓ (own)    |   ✓ (own)   |      ✓ (own)      |  ✓ (any)   |
| Claim yield / RoC           | ✓ (own tokens) |      ✓       |      ✓      |         -         |     -      |
| View operational balance    |       -        |      -       |      -      |      ✓ (own)      |     ✓      |
| Claim operational funds     |       -        |      -       |      -      |      ✓ (own)      |     -      |
| Transfer Impact Token       |    ✓ (own)     |      ✓       |      ✓      |         -         |     -      |
| Create proposal             |       -        |      -       |      ✓      |         -         |     -      |
| Sign proposal (EIP-712)     |       -        |      ✓       |      ✓      |         -         |     -      |
| Execute proposal            |       -        |      -       |      ✓      |         -         |     -      |
| Emergency Pause             |       -        |      -       |      -      |         -         |     ✓      |
| Unpause                     |       -        |      -       |      -      |         -         |     ✓      |
| Update Risk Fee             |       -        |      -       |      -      |         -         |     ✓      |
| Update Actor Registry       |       -        |      -       |      -      |         -         |     ✓      |
| Add / Remove Signer         |       -        |      -       |      -      |         -         |     ✓      |
| Update MultiSig Threshold   |       -        |      -       |      -      |         -         |     ✓      |
| View `isSigner` status      |    ✓ (read)    |      ✓       |      ✓      |         ✓         |     ✓      |

---

## 3. Application Surfaces (Apps)

The LAWP frontend is split into **three distinct application surfaces** with separate URL routes or subdomains. They share a common component library and design system.

```bash
app.lawp.io/           -> Investor Portal        (Public + wallet-gated features)
board.lawp.io/         -> Operational Board Portal  (isSigner-gated)
admin.lawp.io/         -> Admin / Protocol Panel    (Admin Safe–gated, read-only monitoring + Gnosis Safe integration)
```

> [!NOTE]
> Authentication across all surfaces uses **wallet connection only** - no email/password. Role detection happens via on-chain reads immediately after wallet connection.

---

## 4. Navigation Structure & Information Architecture

### 4.1 Investor Portal (`app.lawp.io`)

```bash
app.lawp.io
├── / (Home / Protocol Dashboard)
│   ├── Protocol health overview
│   ├── Active pools listing
│   └── Connect Wallet CTA
│
├── /portfolio
│   ├── Impact Token list (owned)
│   ├── Aggregate claimable yield + RoC
│   └── Batch claim button
│
├── /token/:tokenId
│   ├── Token detail
│   ├── Pool association
│   ├── Yield & RoC breakdown
│   └── Claim / Transfer actions
│
├── /pools
│   ├── All pools index
│   └── /pools/:poolId (Pool detail page)
│
├── /claim (Operational Actor Claim - wallet-gated)
│   └── Visible only if operationalBalances[wallet] > 0
│
└── /connect (Wallet connection page)
```

### 4.2 Operational Board Portal (`board.lawp.io`)

```bash
board.lawp.io
├── / -> redirects to /dashboard
│
├── /dashboard
│   ├── Pending Proposals (unsigned by me)
│   ├── Signed Proposals (awaiting execution)
│   └── Executed Proposals (history)
│
├── /proposals/new  [Coordinator only]
│   └── Create Proposal form
│
├── /proposals/:proposalId
│   ├── Full proposal details
│   ├── Signature progress (X / threshold)
│   ├── Sign button [Board Members]
│   └── Execute button [Coordinator, threshold met]
│
└── /settings  [Coordinator view]
    ├── Connected wallet
    ├── cNGN balance
    └── Approval status for Compliance Engine
```

### 4.3 Admin Panel (`admin.lawp.io`)

```bash
admin.lawp.io
├── /dashboard
│   ├── System health (paused / active)
│   ├── Vault balances
│   └── Key contract addresses
│
├── /pools
│   └── All pools with RoC status
│
├── /registry
│   └── Actor Registry wallet management
│
├── /multisig-config
│   ├── Signer list
│   ├── Threshold
│   └── Add/Remove signer actions
│
├── /risk-fee
│   └── Current fee + update form
│
└── /emergency
    ├── Pause/Unpause engine
    └── System status log
```

---

## 5. Screens & Pages

### 5A. Investor Portal

---

#### Screen: Home / Protocol Dashboard

**URL:** `app.lawp.io/`  
**Access:** Public (no wallet required for read-only view)  
**Purpose:** Protocol-level overview and entry point for new visitors.

**Data displayed:**

- Protocol status badge: **Active** / **⚠ Paused** (reads `Pausable.paused()` from Compliance Engine)
- Total pools created (count of `PoolCreated` events or enumerated `pools` mapping)
- Active pools listed as cards with: Pool ID, Pool Name (off-chain metadata), creation date
- Settlement token address (`cNGNToken`) with Basescan link
- Protocol contract addresses (Compliance Engine, Yield Vault, Operational Vault, Impact Token) - each with verified Basescan link
- Risk Fee current value: display as a percentage (e.g., "10%") - reads `riskFeeBPS` from engine

**Actions available:**

- Connect Wallet -> triggers wallet modal
- Browse Pools -> navigates to `/pools`
- View My Portfolio -> navigates to `/portfolio` (requires connected wallet)

**Empty state:** No pools created yet - show "Protocol launching soon" placeholder.  
**Paused state:** Full-width alert banner: "⚠️ Protocol is currently paused. Deposits and claims are disabled. Monitor official channels for updates." Banner persists on all pages while paused.

---

#### Screen: Portfolio

**URL:** `app.lawp.io/portfolio`  
**Access:** Wallet-gated (must connect wallet)  
**Purpose:** Shows all Impact Tokens owned by the connected wallet and aggregate financials.

**Data displayed:**

- Connected wallet address (truncated: `0x1234...abcd`)
- Network badge: "Base Mainnet" or "Base Sepolia (Testnet)"
- **Aggregate Summary Cards:**
  - Total Tokens Held: count of ERC-721 tokens owned
  - Total Net Principal: sum of `netPrincipal` across all owned tokens (in cNGN)
  - Total Claimable (Yield + RoC): sum of `calculateProportionalYield(tokenId)` across all tokens
  - Total RoC Already Returned: sum of `rocReturned` across all tokens
- **Token List:** One card per token (see Token Card component §6)
  - If wallet holds 0 tokens: show Empty State (§13)
- **Batch Claim Button:** "Claim All (X tokens)" - disabled if no claimable yield; triggers `claimYieldBatch([...tokenIds])`. Max 20 tokens per batch per contract limit.

**Actions available:**

- Claim All (batch) -> triggers `engine.claimYieldBatch(tokenIds[])`
- View individual token -> navigates to `/token/:tokenId`
- Transfer token -> opens Transfer Modal

**Loading state:** Skeleton cards while fetching token data.  
**Error state:** "Failed to load portfolio. Check your connection and refresh." with retry button.

---

#### Screen: Token Detail

**URL:** `app.lawp.io/token/:tokenId`  
**Access:** Public read; actions require wallet owner  
**Purpose:** Full breakdown of a single Impact Token's equity, yield, and RoC status.

**Data displayed:**

- **Token Identity:**
  - Token ID (#123)
  - Pool Name + Pool ID badge
  - Owner address (with Basescan link)
  - Minted date (from `ImpactTokenMinted` event `block.timestamp`)
  - Token metadata link (IPFS URI from `tokenURI(tokenId)`)

- **Equity Breakdown:**
  - Net Principal: `netPrincipal` in cNGN (human-readable, 2 decimal places)
  - Ownership Share: `poolShareBPS / 100`% (e.g., "20.00%")
  - Pool: `poolId` - link to pool detail page

- **Financial Position:**
  - RoC Returned: `rocReturned` in cNGN
  - RoC Remaining: `netPrincipal - rocReturned` in cNGN
  - RoC Progress Bar: `rocReturned / netPrincipal * 100%`
  - Claimable Yield: `calculateProportionalYield(tokenId)` - yield component only (display separately from RoC)
  - Claimable RoC: separately computed from view function
  - Total Claimable: sum of both
  - Total Claimed (lifetime yield): `yieldClaimed[tokenId]` from engine

- **Pool Context:**
  - Pool cumulative yield: `poolYieldTracker[poolId]`
  - Pool cumulative RoC: `poolRocTracker[poolId]`
  - Pool RoC settled: `getPoolRocStatus(poolId).settled` boolean - show "✓ Fully Settled" badge if true

**Actions available (owner-only):**

- **Claim Yield & RoC** -> calls `engine.claimYield(tokenId)` - disabled if `calculateProportionalYield(tokenId) == 0`
- **Transfer Token** -> opens Transfer Modal -> calls ERC-721 `transferFrom` (triggers interception hook automatically)
- **Approve for Marketplace** -> `impactToken.approve(marketplaceAddress, tokenId)` (future feature, mark as "Coming Soon" for v1)

**Interception Hook Notice:** Display an info callout when the user initiates a transfer: "⚠️ Transferring this token will automatically claim all pending yield (X cNGN) to your wallet before the transfer completes."

**Edge cases:**

- Token not owned by connected wallet -> show read-only view with "Not your token" notice; hide action buttons
- Token transferred mid-session -> show stale data warning + refresh prompt
- `calculateProportionalYield` returns 0 -> disable Claim button with tooltip: "No claimable yield yet. Revenue routing events fund this balance."

---

#### Screen: Pool Detail

**URL:** `app.lawp.io/pools/:poolId`  
**Access:** Public  
**Purpose:** Shows all data associated with a specific deployment pool.

**Data displayed:**

- Pool Name (off-chain metadata: location name, project type)
- Pool ID (integer)
- Status: Active / RoC Settled (from `getPoolRocStatus`)
- Pool Creation Date (from `PoolCreated` event)
- Gross Deposit: (off-chain + `RiskFeeAssessed` event: `grossAmount`)
- Risk Fee Deducted: (`RiskFeeAssessed.feeAmount`)
- Net Campaign Capital: `poolTotalPrincipal[poolId]` (the RoC ceiling)
- **RoC Status Panel:**
  - RoC Ceiling: `netCapital` (= `poolTotalPrincipal[poolId]`)
  - RoC Already Routed: `routedRoc` (= `poolRocTracker[poolId]`)
  - RoC Remaining: `remainingRoc`
  - Settled Badge: shown when `settled == true`
  - Progress bar for RoC completion
- **Yield History:**
  - Cumulative Yield Distributed: `poolYieldTracker[poolId]`
  - (Timeline from `OperationalAllocationRouted` events)
- **Contributors table:**
  - Token ID | Owner Address (truncated) | Share % | Net Principal | Claimed (lifetime)
  - Data sourced from `ImpactTokenMinted` events filtered by `poolId`

**Actions:** None (read-only pool detail)

---

#### Screen: Operational Actor Claim

**URL:** `app.lawp.io/claim`  
**Access:** Wallet-gated. Only visible/meaningful if `operationalBalances[wallet] > 0`.  
**Purpose:** Allows LA2, MVI1, Dev, or Operational Treasury wallets to claim their allocated operational revenue.

**Data displayed:**

- Connected wallet address
- Role Label (detected off-chain or by matching actor registry: "LA2 Wallet", "Dev Wallet", etc.)
- **Claimable Balance:** `operationalBalances[connectedWallet]` in cNGN
- Claim history (from `OperationalFundsClaimed` events filtered by wallet address)

**Actions:**

- **Claim Funds** -> calls `engine.claimOperationalFunds(connectedWallet)` - disabled if balance is 0

**Empty state:** "Your operational balance is currently 0 cNGN. Balances are credited during revenue routing events."  
**Success:** Display claimed amount + transaction hash link.

> [!NOTE]
> `claimOperationalFunds(address _wallet)` accepts any wallet address. The UI should default to `msg.sender` (connected wallet). The function is permissionless - anyone can trigger it for any wallet, but funds only flow to `_wallet`. The UI should only show this screen when the connected wallet has a non-zero balance.

---

### 5B. Operational Board Portal

---

#### Screen: Dashboard (Board Member View)

**URL:** `board.lawp.io/dashboard`  
**Access:** `isSigner(connectedWallet) == true`. Non-signers see Access Denied page.  
**Purpose:** Central command view for board members to see, sign, and track proposals.

**Data displayed:**

- Connected wallet address + "Board Member" role badge
- Signer status: green dot "Active Signer" (reads `isSigner(address)`)
- Current threshold: "3 of 5 signatures required" (reads `threshold` and `signerCount`)
- **Proposal Tabs:**
  - **Pending (Unsigned by Me):** proposals where my signature hasn't been collected
  - **Awaiting Execution:** signed by ≥ threshold, not yet executed on-chain
  - **History (Executed):** completed proposals
- Each proposal card (see Proposal Card component §6)

**Actions:**

- Click proposal card -> navigate to `/proposals/:proposalId`
- "Create Proposal" button visible only to Coordinators (see Coordinator check in §12)

---

#### Screen: Proposal Detail

**URL:** `board.lawp.io/proposals/:proposalId`  
**Access:** `isSigner(connectedWallet) == true`  
**Purpose:** Full proposal detail with signing and execution capability.

**Data displayed:**

- **Proposal Metadata:**
  - Proposal ID (integer, auto-generated or manually set)
  - Pool ID -> linked to pool detail page
  - Pool Name (off-chain metadata)
  - Flow Type: "Grant Initial (30/50/20)" | "Grant Continuous (10/55/25/10)" | "Return of Contribution (100%)"
  - Total Amount: formatted cNGN (e.g., "1,000,000 cNGN")
  - Deadline: human-readable datetime + countdown timer (e.g., "Expires in 2h 34m")
  - Status: Pending / Ready to Execute / Executed / Expired

- **Revenue Split Preview** (computed from flow type and amount):

  For GRANT_INITIAL:

  ```bash
  -> Collective (Yield Vault):  30%  = X cNGN
  -> LA2 (Operational Vault):   50%  = X cNGN
  -> MVI1 (Operational Vault):  20%  = X cNGN
  ```

  For GRANT_CONTINUOUS:

  ```bash
  -> Collective (Yield Vault):  10%  = X cNGN
  -> LA2 (Operational Vault):   55%  = X cNGN
  -> MVI1 (Operational Vault):  25%  = X cNGN
  -> Dev (Operational Vault):   10%  = X cNGN
  ```

  For RoC:

  ```bash
  -> Yield Vault (RoC):        100%  = X cNGN
  Remaining RoC Capacity: Y cNGN (from getRemainingRocCapacity)
  ```

- **Signature Progress:**
  - Progress bar: "2 / 3 signed"
  - List of collected signers (addresses, truncated) - each with "✓ Signed" badge
  - Empty slots for missing signatures ("\_ Awaiting signature")
  - Countdown to deadline

- **EIP-712 Digest Preview (expandable):**
  - Shows the structured data that will be signed (proposal parameters)
  - Technical users can verify independently

**Actions:**

- **Sign** (Board Member): calls `signTypedData` with the EIP-712 payload. Disabled if: already signed, deadline expired, proposal already executed.
- **Execute** (Coordinator only): enabled when `collectedSignatures.length >= threshold` AND `deadline > now` AND `!executed`. Opens confirmation modal before submitting.
- **View on Explorer** (post-execution): links to `ProposalExecuted` event on Basescan.

---

#### Screen: Create Proposal

**URL:** `board.lawp.io/proposals/new`  
**Access:** Coordinator role only  
**Purpose:** Coordinator creates a new revenue routing proposal to be signed by the board.

**Form fields:**

| Field        | Type                                                                | Validation                            | Source             |
| ------------ | ------------------------------------------------------------------- | ------------------------------------- | ------------------ |
| Proposal ID  | Number (auto-suggested next available)                              | Must be unique integer > 0            | Off-chain / manual |
| Pool ID      | Dropdown (list of active pools)                                     | Must call `isPoolActive(poolId)`      | On-chain           |
| Total Amount | Number input (cNGN)                                                 | Must be > 0                           | Off-chain          |
| Flow Type    | Dropdown: Grant Initial / Grant Continuous / Return of Contribution | Required                              | Enum               |
| Deadline     | Date/time picker                                                    | Must be at least 1 hour in the future | Timestamp          |

**Validations before submit:**

- For RoC flow: fetch `getRemainingRocCapacity(poolId)`. If `totalAmount > remainingRocCapacity`, show error: "Amount exceeds the pool's remaining RoC capacity (Y cNGN). Reduce the amount."
- Pool must exist: `isPoolActive(poolId) == true`
- Amount > 0

**On submit:**

- Proposal is stored in the off-chain backend (or submitted on-chain via a `submitSignature` method - see §17 for backend architecture options)
- Coordinator is returned to dashboard with success toast
- Proposal is now visible to all board members for signing

---

#### Screen: Execution Confirmation Modal

**Trigger:** Coordinator clicks "Execute" on a proposal with threshold met.  
**Purpose:** Final review before submitting the on-chain transaction.

**Data displayed:**

- Summary of the proposal (Pool, Amount, Flow Type, Deadline)
- Signers to be used (exactly `threshold` lowest-address signers)
- cNGN required: `totalAmount`
- Coordinator wallet cNGN balance (live read)
- Approval status: "✓ Approved" / "⚠ Not Approved - approve first"

**Pre-execution checklist:**

1. **cNGN Balance Check:** Does coordinator wallet hold ≥ `totalAmount` cNGN?
   - If not: show "Insufficient cNGN balance. You need X cNGN to execute this proposal."
2. **Allowance Check:** Is `cNGNToken.allowance(coordinator, complianceEngine) >= totalAmount`?
   - If not: show "Approve cNGN Spend" button -> calls `cNGNToken.approve(complianceEngine, totalAmount)` -> wait for confirmation -> then show Execute button
3. **Deadline Check:** Is `deadline > block.timestamp`?
   - If expired: show error, disable Execute.

**Actions:**

- **Approve cNGN** (if not approved) -> `ERC20.approve(complianceEngine, amount)`
- **Execute Proposal** -> calls `controller.executeProposal(proposalId, poolId, totalAmount, flowType, deadline, signatures_bytes)`
- **Cancel** -> dismiss modal

**Transaction states during execution:**

1. "Constructing signature blob..." (frontend packs 65-byte signatures, sorts by signer address)
2. "Awaiting wallet confirmation..." (MetaMask popup)
3. "Transaction submitted - awaiting confirmation..." (spinner + tx hash)
4. "✓ Proposal executed successfully!" -> navigates to proposal detail with "Executed" status

---

### 5C. Admin / Protocol Governance Panel

---

#### Screen: Admin Dashboard

**URL:** `admin.lawp.io/dashboard`  
**Access:** Read-accessible to anyone; write actions require Admin Safe connection.  
**Purpose:** Protocol health monitoring and administrative control.

> [!IMPORTANT]
> Most admin write actions (pause, update fee, manage signers) **must be executed through the Gnosis Safe UI** because the Admin Safe is a multisig contract. The Admin Panel's role is primarily monitoring and composing transactions that are then submitted via the Safe.

**Data displayed:**

- System Status: **ACTIVE** (green) / **PAUSED** (red) - reads `engine.paused()`
- Risk Fee: `riskFeeBPS / 100`% (current value)
- MultiSig Threshold: `threshold` / `signerCount`
- Contract Addresses panel (all 6 contracts with Basescan links):
  - LAWPComplianceEngine
  - LAWPYieldVault
  - LAWPOperationalVault
  - LAWPImpactToken
  - LAWPMultiSigController
  - LAWPActorRegistry
- **Vault Balances:**
  - Yield Vault cNGN balance: `cNGNToken.balanceOf(yieldVaultAddress)`
  - Operational Vault cNGN balance: `cNGNToken.balanceOf(operationalVaultAddress)`
- **Outstanding Obligations (Investor):** Total unclaimed yield + RoC across all tokens (computed from events/subgraph)
- **Outstanding Obligations (Operational):** Sum of all `operationalBalances` (from events or subgraph)
- **Solvency Status Indicators:**
  - "✓ Yield Vault Solvent" if `vaultBalance >= totalInvestorObligations`
  - "⚠️ Solvency Warning" if not

---

#### Screen: Actor Registry Management

**URL:** `admin.lawp.io/registry`  
**Purpose:** View and propose updates to operational wallet addresses.

**Data displayed:**

- LA2 Wallet: current address from `registry.la2Wallet()`
- MVI1 Wallet: current address from `registry.mvi1Wallet()`
- Operational Treasury Wallet: `registry.operationalTreasuryWallet()`
- Dev Wallet: `registry.devWallet()`
- (Each with Basescan link and cNGN balance displayed)

**Actions (Admin Safe only - generates Safe tx):**

- Update each wallet -> calls `registry.setLA2Wallet(newAddress)`, etc.
- Shows preview of change before composing Safe transaction

---

#### Screen: MultiSig Configuration

**URL:** `admin.lawp.io/multisig-config`  
**Purpose:** Manage the Operational Board composition.

**Data displayed:**

- Threshold: `threshold` / `signerCount`
- Signer list: all addresses where `isSigner == true` (from `SignerAdded` / `SignerRemoved` events)

**Actions (Admin Safe only):**

- Add Signer -> `controller.addSigner(address)` (max 20 signers enforced by `MAX_SIGNERS`)
- Remove Signer -> `controller.removeSigner(address)` (blocked if removal would drop `signerCount < threshold`)
- Update Threshold -> `controller.updateThreshold(newThreshold)` (must be ≤ `signerCount` and > 0)

> [!WARNING]
> Removing a signer whose signature has already been collected for a pending proposal does NOT invalidate their signature - it remains valid for execution per the contract design. Communicate this clearly in the UI.

---

#### Screen: Emergency Controls

**URL:** `admin.lawp.io/emergency`  
**Purpose:** Pause / unpause the Compliance Engine in case of an active exploit or systemic risk.

**Data displayed:**

- Current status: ACTIVE / PAUSED
- Last paused by / last unpaused by (from `EnginePaused` / `EngineUnpaused` events)
- Pause history log

**Actions (Admin Safe only):**

- **Emergency Pause** -> calls `engine.emergencyPause()` via Safe - requires Safe threshold approvals
- **Unpause** -> calls `engine.unpause()` via Safe - requires Safe threshold approvals

**Paused state effects documented for user:** "When paused: deposits are blocked, yield claims are blocked, token transfers are blocked. Revenue routing proposals cannot be submitted. Pull claims for operational actors are NOT blocked."

> [!CAUTION]
> Token transfers revert while the engine is paused (enforced by `_update()` hook checking `engine.paused()`). Make sure this is prominently communicated in the pause warning on all portal surfaces.

---

## 6. UI Modules & Reusable Components

### 6.1 WalletConnectButton

- Supports: MetaMask, WalletConnect, Coinbase Wallet
- States: Disconnected | Connecting | Connected (shows truncated address + network badge)
- On connect: reads network -> if wrong chain, show "Switch to Base" modal with one-click chain switch
- On connect: immediately reads role (investor tokens, `isSigner`, operational balance) to determine gating

### 6.2 NetworkBanner

- Persistent top banner when connected to wrong network
- Text: "You are connected to [chainName]. Please switch to Base Mainnet to use LAWP."
- Button: "Switch Network" -> triggers `wallet_switchEthereumChain`

### 6.3 SystemPausedBanner

- Shown when `engine.paused() == true`
- Persistent, full-width, red/amber banner on all pages
- Text: "⚠️ Protocol is currently paused. Claims and deposits are disabled. Follow official announcements for updates."
- Non-dismissable

### 6.4 Token Card (Impact Token)

- **Token ID** badge (e.g., "#42")
- **Pool badge** with Pool ID + name
- **Ownership %:** `poolShareBPS / 100`%
- **Net Principal:** X cNGN
- **Claimable (Yield + RoC):** Y cNGN - highlighted in accent color if > 0
- **RoC Progress:** progress bar `rocReturned / netPrincipal`
- **Claim Button:** calls `claimYield(tokenId)` - disabled if claimable = 0 or system paused
- Loading state: skeleton shimmer

### 6.5 Proposal Card (Board Portal)

- **Proposal ID** + **Status badge** (Pending / Threshold Met / Executed / Expired)
- **Pool:** Pool ID + name
- **Flow Type:** human-readable label
- **Amount:** formatted cNGN
- **Signature Progress:** "2 / 3" with mini-progress bar
- **Deadline:** countdown or "Expired" badge
- Clickable -> navigates to proposal detail

### 6.6 Revenue Split Preview

- Renders a visual breakdown of a routing amount by flow type
- Color-coded bars for each recipient (Collective/Yield Vault, LA2, MVI1, Dev)
- Values shown in absolute cNGN and as percentage

### 6.7 RoC Progress Gauge

- Circular or linear gauge showing `routedRoc / netCapital` for a pool
- Displays: "X cNGN returned of Y cNGN total"
- Color: amber while in-progress, green when settled

### 6.8 TransactionStatusOverlay

- Full-screen overlay (or slide-up panel on mobile)
- States:
  1. **Building:** "Preparing transaction..."
  2. **Pending Signature:** "Please confirm in your wallet..." (spinner)
  3. **Submitted:** "Transaction submitted - tx: 0xabc...def" (spinner + Basescan link)
  4. **Confirmed:** "✓ Transaction confirmed!" (success icon + action)
  5. **Reverted:** "Transaction failed: [revert reason in human language]" (error icon + help text)

### 6.9 ApprovalGate (cNGN Allowance Component)

- Used before any action requiring cNGN spend (deposit, proposal execution)
- Reads `cNGNToken.allowance(wallet, complianceEngine)`
- If insufficient: shows "Approve cNGN" button
- Two-step visual flow: Approve -> Execute

### 6.10 AddressDisplay

- Renders an Ethereum address
- Always truncated in display (`0x1234...abcd`)
- Click to copy full address
- External link to Basescan

### 6.11 EmptyStateIllustration

- Context-specific: Portfolio Empty / No Proposals / No Pools / Access Denied
- Includes a short explanation + CTA action button

### 6.12 Skeleton Loaders

- Used for all async data fetches
- Match the exact shape of the target component (card, table row, stat)
- Pulse animation

### 6.13 ToastNotification

- Position: top-right (desktop), top-center (mobile)
- Types: success (green), error (red), warning (amber), info (blue)
- Auto-dismiss after 5s; can be pinned for error toasts

### 6.14 ConfirmationModal

- Used for destructive or high-stakes actions (Execute Proposal, Emergency Pause)
- Two-step: Review -> Confirm
- Shows a summary of the action and its irreversibility

---

## 7. Wallet & Transaction Interactions

### 7.1 Wallet Connection Flow

```bash
User clicks "Connect Wallet"
  └-> Wallet selection modal (MetaMask / WalletConnect / Coinbase)
       └-> User approves connection in wallet
            └-> Check network (chainId == Base Mainnet: 8453 / Sepolia: 84532)
                 ├-> Wrong network -> show "Switch to Base" modal
                 └-> Correct network -> resolve role
                      ├-> Read isSigner(address) -> if true: show Board Portal access
                      ├-> Read operationalBalances(address) -> if > 0: show Claim tab
                      ├-> Read owned tokens (ERC-721 balanceOf / events) -> populate portfolio
                      └-> Full UI unlocked for appropriate role
```

### 7.2 Transaction Signing Patterns

**Standard EVM Write (claim, transfer):**

- User clicks action button -> UI prepares calldata -> wallet popup -> confirmation -> polling until mined

**EIP-712 Typed Data Signing (board member signing a proposal):**

```typescript
const domain = {
  name: "LAWP MultiSig",
  version: "1",
  chainId: 8453, // Base Mainnet
  verifyingContract: "0x...", // LAWPMultiSigController address
};

const types = {
  Proposal: [
    { name: "proposalId", type: "uint256" },
    { name: "poolId", type: "uint256" },
    { name: "totalAmount", type: "uint256" },
    { name: "flowType", type: "uint8" },
    { name: "deadline", type: "uint256" },
  ],
};
```

- Calls `wallet.signTypedData(domain, types, proposalValues)`
- Returns 65-byte ECDSA signature (r + s + v)
- Signature is POSTed to backend (or emitted as on-chain event) for collection

**ERC-20 Approve:**

- Triggered by `ApprovalGate` component
- Calls `cNGNToken.approve(complianceEngineAddress, amount)`
- UI waits for confirmation before enabling dependent action

### 7.3 Transaction Error Decoding

Map on-chain revert reasons to user-friendly messages:

| Revert Error                                     | User-Facing Message                                                                       |
| ------------------------------------------------ | ----------------------------------------------------------------------------------------- |
| `LAWPComplianceEngine_SystemPaused`              | "The protocol is currently paused. Please check announcements."                           |
| `LAWPComplianceEngine_NothingToClaim`            | "No yield available to claim yet."                                                        |
| `LAWPComplianceEngine_NotTokenOwner`             | "You do not own this Impact Token."                                                       |
| `LAWPComplianceEngine_ExceedsPrincipalCap`       | "This RoC amount exceeds the pool's remaining RoC capacity."                              |
| `LAWPComplianceEngine_PoolAlreadyExists`         | "A pool with this ID already exists."                                                     |
| `LAWPComplianceEngine_InvalidBPS`                | "Contributor shares must add up to exactly 100%."                                         |
| `LAWPComplianceEngine_BatchTooLarge`             | "You can claim at most 20 tokens in a single batch."                                      |
| `LAWPMultiSigController_Expired`                 | "This proposal has expired. A new proposal must be created."                              |
| `LAWPMultiSigController_ProposalAlreadyExecuted` | "This proposal has already been executed."                                                |
| `LAWPMultiSigController_InvalidSignatureLength`  | "Invalid signature format. Ensure exactly 3 valid signatures are packed."                 |
| `LAWPMultiSigController_InvalidSignerOrder`      | "Signatures must be sorted by signer address (ascending). Duplicate signatures detected." |
| `LAWPMultiSigController_NotASigner`              | "Your wallet is not registered as a board member."                                        |
| `LAWPMultiSigController_BelowThreshold`          | "Insufficient signatures to execute."                                                     |
| `LAWPMultiSigController_InvalidPool`             | "The selected pool does not exist or is not active."                                      |
| `ERC20InsufficientAllowance`                     | "Insufficient cNGN allowance. Please approve the required amount first."                  |
| `ERC20InsufficientBalance`                       | "Insufficient cNGN balance in your wallet."                                               |

---

## 8. Deposit, Yield, RoC & Claiming Experiences

### 8.1 Pool Deposit Flow

> [!NOTE]
> Pool deposits (`processPoolDeposit`) are NOT a self-service user action. They are executed by a system administrator or coordinator with the list of contributors and their BPS allocations pre-computed off-chain. There is no public "deposit" button on the investor portal. Impact Tokens are received into investor wallets as a result of this admin action.

**Admin-side flow (for Admin Panel):**

1. Admin has: Pool ID, gross amount, list of contributor addresses + BPS shares (summing to 10,000)
2. Admin approves `grossAmount` cNGN to Compliance Engine
3. Admin calls `engine.processPoolDeposit(poolId, grossAmount, contributors[], bpsShares[])`
4. Contract validates: BPS sum = 10,000, pool ID is new, array lengths match, ≤ 20 contributors
5. Transfers gross amount to Operational Vault
6. Mints one ERC-721 Impact Token per contributor
7. Emits: `PoolCreated`, `RiskFeeAssessed`, `ImpactTokenMinted` (per contributor), `CapitalPooled`

**Investor experience:** They receive an ERC-721 token in their wallet (watch for `Transfer` event from the Impact Token contract). Their portfolio page updates to show the new token.

**What investors see post-deposit:**

- New token in portfolio
- Net Principal = gross contribution × 90% (after 10% risk fee)
- Ownership % = their BPS / 100
- Claimable Yield = 0 (no revenue routed yet)
- RoC Progress = 0 / netPrincipal

### 8.2 Yield Accumulation (No UI Action Required)

Yield accrues automatically in the background as the Operational Board routes revenue. Investors don't trigger this - they just watch their claimable balance grow. The UI should:

1. Poll or subscribe to `OperationalAllocationRouted` events on the Compliance Engine
2. Refresh `calculateProportionalYield(tokenId)` on any relevant event for the pool
3. Display the updated claimable amount on the portfolio card

> [!TIP]
> Use `poolYieldTracker[poolId]` as a lightweight dirty-check. When this value changes, recompute yield for all tokens in that pool using the O(1) formula: `(poolYieldTracker[poolId] * token.poolShareBPS) / 10000 - yieldClaimed[tokenId]`.

### 8.3 Yield Claim Flow

**Happy path:**

```bash
User clicks "Claim" on token card (or "Claim All")
  └-> UI reads calculateProportionalYield(tokenId) -> shows amount to receive
       └-> User confirms
            └-> UI calls engine.claimYield(tokenId)
                 └-> Engine: validates ownership -> computes yield + RoC -> updates state -> calls yieldVault.executeTransfer(owner, amount)
                      └-> Transaction confirmed -> toast: "Claimed X cNGN (Y yield + Z RoC)"
                           └-> Portfolio refreshed: claimable = 0, rocReturned updated
```

**Batch Claim:**

- Up to 20 tokens in one transaction (enforced by `MAX_BATCH_CLAIM`)
- UI checks: all tokens owned by connected wallet
- If wallet holds > 20 tokens: show pagination / "Claim first 20" option

**What the user receives:**

- cNGN transferred to their wallet from YieldVault
- Display breakdown: "X cNGN yield + Y cNGN RoC = Z cNGN total"

### 8.4 Return of Contribution (RoC)

RoC is included automatically in the `claimYield` / `claimYieldBatch` calls - it is NOT a separate action.

**How it works:**

- Each time revenue is routed with `FlowType.RoC`, `poolRocTracker[poolId]` increases
- On claim, the engine computes: `min(totalRocForToken - rocReturned, netPrincipal - rocReturned)`
- Once `rocReturned == netPrincipal`, the token has fully recovered its principal (RoC settled)
- The token CONTINUES earning yield after RoC is fully settled (yield earns indefinitely; RoC does not)

**UI distinctions:**

- Show yield and RoC as separate line items in the claim preview
- Show RoC progress bar on token card and detail page
- Display "Principal Fully Recovered ✓" badge once `rocReturned == netPrincipal`

### 8.5 Token Transfer (Secondary Market)

When an investor transfers their Impact Token:

**Before transfer (interception hook fires automatically):**

1. Contract checks: `calculateProportionalYield(tokenId) > 0`?
2. If yes: automatically calls `engine.claimYield(tokenId)` -> pending yield credited to the **sender**
3. Transfer completes with receiver getting a token with 0 pending yield

**UI requirement:**  
Before the user initiates a transfer, show the Transfer Modal with:

- "This transfer will automatically claim your pending yield of **X cNGN** to your wallet."
- "The recipient will receive a clean token with 0 pending yield."
- "Gas estimate includes the yield claim transaction."
- If pending yield = 0: "No pending yield to claim before transfer."
- Confirm / Cancel buttons

---

## 9. Operational Actor Workflows

### 9.1 LA2, MVI1, Dev, Operational Treasury - Claim Operational Funds

**Trigger:** After any revenue routing event, operational balances increase.

**UI Flow:**

```bash
Operational actor connects wallet
  └-> App reads operationalBalances[wallet] from Compliance Engine
       └-> If balance > 0: show "Claim Operational Funds" button
            └-> User clicks Claim
                 └-> App calls engine.claimOperationalFunds(wallet)
                      └-> Operational Vault transfers cNGN to wallet
                           └-> Toast: "Claimed X cNGN operational funds"
```

**Important:** `claimOperationalFunds(address _wallet)` is permissionless - any address can call it for any wallet. The UI should always pass the connected wallet's address to avoid confusion. The funds always go to `_wallet`, not `msg.sender`.

**Operational balance sources by role:**

| Actor                | Balance credited from                                                    |
| -------------------- | ------------------------------------------------------------------------ |
| Operational Treasury | `processPoolDeposit` (full gross deposit = risk fee + net capital)       |
| LA2                  | `routeOperationalAllocation` (GRANT_INITIAL: 50%, GRANT_CONTINUOUS: 55%) |
| MVI1                 | `routeOperationalAllocation` (GRANT_INITIAL: 20%, GRANT_CONTINUOUS: 25%) |
| Dev                  | `routeOperationalAllocation` (GRANT_CONTINUOUS only: 10%)                |

---

## 10. Admin / MultiSig / Governance Interactions

### 10.1 Revenue Routing Full Workflow (Coordinator + Board)

- Phase 1: Off-chain revenue observed
  - Board members observe fiat -> cNGN conversion in Injector Wallet (Planbok system)

- Phase 2: Coordinator creates proposal
  - Coordinator opens board.lawp.io/proposals/new
  - Fills form: proposalId, poolId, amount, flowType, deadline
  - Backend stores proposal (off-chain) -> visible to all board members

- Phase 3: Board members sign (parallel)
  - Each board member opens board.lawp.io/dashboard
  - Sees proposal in "Pending (Unsigned)" tab
  - Clicks proposal -> views details + revenue split preview
  - Clicks "Sign" -> wallet opens signTypedData popup
  - Signs -> 65-byte ECDSA signature stored in backend
  - UI updates signature count: "2 / 3"

- Phase 4: Coordinator executes
  - Coordinator sees "Threshold Met" badge on proposal
  - Clicks "Execute" -> Execution Confirmation Modal
  - UI checks: cNGN balance, allowance, deadline
  - UI packs signatures: sorts by signer address (ascending), concatenates r||s||v, total = threshold × 65 bytes
  - Coordinator approves cNGN spend if needed -> Approve tx confirmed
  - Coordinator clicks Execute -> calls controller.executeProposal(...)
  - Contract: validates digest, threshold, ordering, replay protection -> calls `engine.routeOperationalAllocation(...)`
  - Engine: splits funds -> moves to vaults -> credits ledgers
  - Event: ProposalExecuted emitted
  - UI: proposal moves to "Executed" status

### 10.2 Admin Safe Actions

All Admin Safe write actions follow this pattern:

1. Admin navigates to relevant section in Admin Panel
2. Admin inputs parameters (new fee, new address, etc.)
3. UI generates the calldata for the target contract function
4. UI presents a "Compose Safe Transaction" button -> deep-links to Gnosis Safe UI with pre-populated tx
5. Admin Safe co-signers review and approve in Gnosis Safe
6. Transaction executes -> Admin Panel reads updated state

Admin-safe-only functions:

| Function                                | Contract                                  | Admin Panel Section |
| --------------------------------------- | ----------------------------------------- | ------------------- |
| `emergencyPause()`                      | ComplianceEngine                          | Emergency Controls  |
| `unpause()`                             | ComplianceEngine                          | Emergency Controls  |
| `updateRiskFee(newFeeBPS)`              | ComplianceEngine                          | Risk Fee            |
| `setMultiSigController(address)`        | ComplianceEngine                          | System Config       |
| `addSigner(address)`                    | MultiSigController                        | MultiSig Config     |
| `removeSigner(address)`                 | MultiSigController                        | MultiSig Config     |
| `updateThreshold(newThreshold)`         | MultiSigController                        | MultiSig Config     |
| `setLA2Wallet(address)`                 | ActorRegistry                             | Registry            |
| `setMVI1Wallet(address)`                | ActorRegistry                             | Registry            |
| `setOperationalTreasuryWallet(address)` | ActorRegistry                             | Registry            |
| `setDevWallet(address)`                 | ActorRegistry                             | Registry            |
| `setComplianceEngine(address)`          | YieldVault, OperationalVault, ImpactToken | System Config       |

---

## 11. Data Displayed Per Screen

### On-Chain Data Sources Reference

| Data Field                                       | Source                 | Read Method                                  |
| ------------------------------------------------ | ---------------------- | -------------------------------------------- |
| Protocol paused state                            | LAWPComplianceEngine   | `engine.paused()`                            |
| Risk fee                                         | LAWPComplianceEngine   | `engine.riskFeeBPS()`                        |
| Pool exists                                      | LAWPComplianceEngine   | `engine.isPoolActive(poolId)`                |
| Pool cumulative yield                            | LAWPComplianceEngine   | `engine.poolYieldTracker(poolId)`            |
| Pool cumulative RoC                              | LAWPComplianceEngine   | `engine.poolRocTracker(poolId)`              |
| Pool net capital (RoC cap)                       | LAWPComplianceEngine   | `engine.poolTotalPrincipal(poolId)`          |
| Pool RoC status                                  | LAWPComplianceEngine   | `engine.getPoolRocStatus(poolId)`            |
| Remaining RoC capacity                           | LAWPComplianceEngine   | `engine.getRemainingRocCapacity(poolId)`     |
| Token's claimed yield                            | LAWPComplianceEngine   | `engine.yieldClaimed(tokenId)`               |
| Operational balance                              | LAWPComplianceEngine   | `engine.operationalBalances(wallet)`         |
| Claimable yield for token                        | LAWPComplianceEngine   | `engine.calculateProportionalYield(tokenId)` |
| Token data (principal, BPS, poolId, rocReturned) | LAWPImpactToken        | `impactToken.getTokenData(tokenId)`          |
| Token owner                                      | LAWPImpactToken        | `impactToken.ownerOf(tokenId)`               |
| Token count for wallet                           | LAWPImpactToken        | `impactToken.balanceOf(wallet)`              |
| Token URI / metadata                             | LAWPImpactToken        | `impactToken.tokenURI(tokenId)`              |
| Vault cNGN balance                               | cNGNToken              | `cNGN.balanceOf(vaultAddress)`               |
| isSigner                                         | LAWPMultiSigController | `controller.isSigner(wallet)`                |
| Signer count                                     | LAWPMultiSigController | `controller.signerCount()`                   |
| Threshold                                        | LAWPMultiSigController | `controller.threshold()`                     |
| Proposal executed                                | LAWPMultiSigController | `controller.executedProposals(digest)`       |
| EIP-712 digest                                   | LAWPMultiSigController | `controller.getProposalDigest(...)`          |
| LA2 wallet                                       | LAWPActorRegistry      | `registry.la2Wallet()`                       |
| MVI1 wallet                                      | LAWPActorRegistry      | `registry.mvi1Wallet()`                      |
| Op Treasury wallet                               | LAWPActorRegistry      | `registry.operationalTreasuryWallet()`       |
| Dev wallet                                       | LAWPActorRegistry      | `registry.devWallet()`                       |
| Wallet cNGN balance                              | cNGNToken              | `cNGN.balanceOf(wallet)`                     |
| cNGN allowance                                   | cNGNToken              | `cNGN.allowance(wallet, engineAddress)`      |

---

## 12. Permissions & Access Boundaries

### 12.1 Route Guards

- Investor Portal (/portfolio, /token/:id, /claim)
  - Guard: wallet connected -> otherwise redirect to /connect

- Board Portal (all routes)
  - Guard: wallet connected AND isSigner(wallet) == true
  - Fallback: "Access Denied" page with explanation

- Board Portal /proposals/new
  - Guard: isCoordinator(wallet) == true (determined by off-chain role or a specific admin-assigned flag)
  - Fallback: redirect to /dashboard

- Admin Panel (write actions)
  - Guard: connects to Gnosis Safe (Safe SDK integration)
  - Read-only views: accessible to any wallet

### 12.2 Smart Contract Permission Enforcement

The UI must **never** show action buttons that the user's wallet cannot authorize on-chain:

| UI Action               | Contract Permission                        | Guard Condition                            |
| ----------------------- | ------------------------------------------ | ------------------------------------------ |
| Claim Yield             | Anyone can call for any `tokenId` they own | `impactToken.ownerOf(tokenId) == wallet`   |
| Claim Operational Funds | Permissionless                             | `operationalBalances[wallet] > 0`          |
| Sign Proposal           | `isSigner` mapping                         | `controller.isSigner(wallet) == true`      |
| Execute Proposal        | Permissionless (but needs cNGN + approval) | Threshold met + deadline valid + approved  |
| Process Deposit         | Permissionless (caller provides cNGN)      | Admin action only - not shown to investors |
| Emergency Pause         | `onlyOwner` (Admin Safe)                   | Admin Safe only                            |
| Update Registry         | `onlyOwner`                                | Admin Safe only                            |
| Add/Remove Signer       | `onlyOwner`                                | Admin Safe only                            |
| Update Risk Fee         | `onlyOwner`                                | Admin Safe only                            |

### 12.3 Investor Token Ownership

- An investor can only claim yield for tokens they **currently own**
- Batch claim silently skips tokens not owned by the caller (contract reverts on non-ownership)
- After transfer, the token moves to new owner; original owner's claimable resets to 0
- Transferred-to wallet sees the token in their portfolio with clean yield state (0 pending)

---

## 13. System States

### 13.1 Empty States

| Context                       | Message                                                                                                                                   | CTA                             |
| ----------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------- |
| Portfolio - No tokens         | "You don't hold any LAWP Impact Tokens yet. Contact the project team to participate in a pool."                                           | "View Available Pools"          |
| Board - No proposals          | "No pending proposals. Create one to start the routing process." (Coordinator) / "No proposals to sign. Check back later." (Board Member) | [Coordinator] "Create Proposal" |
| Pool list - No pools          | "No deployment pools have been created yet."                                                                                              | -                               |
| Operational Claim - Balance 0 | "Your operational balance is currently 0 cNGN. Balances accumulate during revenue routing events."                                        | -                               |

### 13.2 Loading States

- All data fetches: display skeleton components matching content shape
- Transaction pending: `TransactionStatusOverlay` with step indicator
- Signature collection: live-updating progress bar

### 13.3 Error States

| Error Type            | Display                                                            | Action                |
| --------------------- | ------------------------------------------------------------------ | --------------------- |
| RPC / network failure | "Unable to connect to blockchain. Check your network and refresh." | Retry button          |
| Wallet not connected  | Prompt to connect wallet                                           | Connect Wallet button |
| Wrong network         | `NetworkBanner` with switch button                                 | Switch to Base button |
| Transaction revert    | Human-readable revert reason (see §7.3) + Basescan link            | Dismiss / Retry       |
| Data stale            | Soft warning + refresh timestamp                                   | Refresh button        |

### 13.4 Paused / Emergency States

When `engine.paused() == true`:

- `SystemPausedBanner` shown on all pages
- **Disabled actions:** Claim Yield, Batch Claim, Token Transfer, Execute Proposal, Process Deposit
- **Still enabled:** View portfolio, view pool data, sign proposals (signing is off-chain and not blocked), Claim Operational Funds (`claimOperationalFunds` is NOT behind `whenNotPaused`)
- All disabled buttons show tooltip: "Protocol is paused. Actions will be re-enabled when the system is unpaused."

> [!NOTE]
> `claimOperationalFunds` does NOT have `whenNotPaused`. Operational actors CAN claim during a pause event. Only investor yield claims and token transfers are blocked.

### 13.5 RoC Fully Settled State

When `getPoolRocStatus(poolId).settled == true`:

- Token cards for this pool show: "✓ Principal Fully Recovered"
- RoC progress bar is complete and green
- Token detail shows RoC section as complete
- Yield claim still works normally - RoC being settled does not stop yield earnings

### 13.6 Expired Proposal State

When `block.timestamp >= proposal.deadline`:

- Proposal card shows "Expired" red badge
- Sign and Execute buttons disabled
- No new signatures can be collected (frontend restriction; contract also enforces)
- Coordinator must create a new proposal with a future deadline

---

## 14. Notifications, Edge Cases & Error Handling

### 14.1 Real-Time Notifications (Event-Based)

Subscribe to the following contract events and notify users:

| Event                                                            | Who to notify          | Toast message                                                        |
| ---------------------------------------------------------------- | ---------------------- | -------------------------------------------------------------------- |
| `YieldClaimed(tokenId, claimer, yield, roc)`                     | Token owner            | "✓ Claimed X cNGN (Y yield + Z RoC)"                                 |
| `OperationalFundsClaimed(wallet, amount)`                        | Actor wallet           | "✓ Claimed X cNGN operational funds"                                 |
| `OperationalAllocationRouted(poolId, flowType, amount)`          | Investors in that pool | "New revenue routed to Pool #X - your claimable balance has updated" |
| `PoolCreated(poolId, timestamp)`                                 | Admin                  | "New pool #X created"                                                |
| `ProposalExecuted(digest, proposalId, poolId, amount, flowType)` | Board members          | "✓ Proposal #X executed - revenue routed"                            |
| `EnginePaused(by)`                                               | All connected users    | "⚠️ Protocol paused" (full banner)                                   |
| `EngineUnpaused(by)`                                             | All connected users    | "✓ Protocol resumed" (dismiss banner)                                |
| `SignerAdded/Removed`                                            | Board portal users     | "Board composition updated"                                          |
| `ThresholdUpdated`                                               | Board portal users     | "Signature threshold updated to X"                                   |

### 14.2 Edge Cases

**More than threshold signatures collected:**

- Frontend only packs exactly `threshold` signatures (the 3 with the lowest signer addresses)
- Display a note in the execution modal: "3 of 4 collected signatures will be used (lowest addresses selected)"
- This is by design - the contract only accepts exactly `threshold * 65` bytes

**Proposal signed by removed signer:**

- Their signature remains valid for execution (contract does not retroactively invalidate)
- UI may show their address with an "(ex-signer)" label if cross-referenced with the current `isSigner` state
- No user action needed

**Token transferred during claim process:**

- If the Impact Token is transferred after the user initiates a claim transaction but before it confirms, the transaction will revert with `NotTokenOwner`
- Error toast: "Claim failed - you no longer own this token."

**Gas estimation failures:**

- If `eth_estimateGas` fails (likely due to revert), catch the revert reason and display it instead of a generic error

**cNGN allowance race condition:**

- After approving, wait for confirmation before enabling Execute to avoid a double-transaction race

**Batch claim with zero-yield tokens:**

- Contract processes all tokens but only aggregates non-zero amounts. If ALL tokens have 0 claimable, the transaction reverts with `NothingToClaim`.
- Frontend should pre-filter: only include tokens where `calculateProportionalYield(tokenId) > 0` in the batch

**Impact Token with `rocReturned == netPrincipal` (RoC fully settled for that specific token):**

- RoC component of `calculateProportionalYield` returns 0 for this token
- Yield component can still be positive - user can still claim yield
- Do not show "Nothing to claim" if yield > 0 even if RoC = 0

---

## 15. Mobile & Desktop Responsiveness

### 15.1 Desktop (Primary)

- **Min width:** 1024px for Board Portal (signature management is complex)
- **Layout:** Sidebar navigation + main content area
- **Tables:** Full column width, horizontal scroll on overflow
- **Modals:** Centered, max-width 600px

### 15.2 Tablet (Secondary)

- **Min width:** 768px
- **Layout:** Collapsible sidebar or tab bar
- **Token cards:** 2-column grid

### 15.3 Mobile (Supported, limited)

- **Min width:** 375px
- **Layout:** Single column, bottom tab navigation
- **Investor Portal:** Full mobile support for viewing portfolio, claiming yield, viewing pool data
- **Board Portal:** Mobile viewing is supported; signing proposals via wallet apps (WalletConnect) is supported; creating/executing proposals is desktop-preferred due to complexity
- **Admin Panel:** Desktop only recommended; read-only monitoring is mobile-accessible

### 15.4 Specific Considerations

- All `AddressDisplay` components truncate to `0x1234...abcd` on all sizes
- Revenue split previews use horizontal bars on desktop, stacked bars on mobile
- Transaction overlays are full-screen on mobile, centered modal on desktop
- `SystemPausedBanner` stacks above navigation on mobile
- Signature progress bars collapse to numerical display on small screens ("2/3")

---

## 16. Security & Trust Indicators

### 16.1 Protocol Trust Signals

Display permanently visible on all pages:

- **Verified contract addresses** with direct Basescan links (show ✓ verified badge for each)
- **Open-source repository link** (GitHub) in footer
- **Audit status badge** ("Pending External Audit" until Phase 9 complete - do not fake this)
- **Protocol version** (v1.0.0) in footer

### 16.2 Transaction Trust Signals

Before every write transaction:

- Show exact function name being called (e.g., `claimYield(#42)`)
- Show contract address being called
- Show exact cNGN amount involved
- Basescan link to the contract for independent verification
- Never obscure what is happening under the hood

### 16.3 EIP-712 Signing Trust Signals

When a board member signs a proposal:

- Wallet popup will show human-readable structured data (MetaMask supports EIP-712 display)
- In the UI, show a preview panel matching exactly what will appear in the wallet: field names, types, and values
- Tell users: "Your wallet will display the exact proposal data. Verify it matches before signing."

### 16.4 Immutability Signals

Display these facts prominently where relevant:

- "Settlement token: cNGN - **immutable**, set at deployment and cannot be changed"
- "Protocol vaults: Zero custody - the Compliance Engine never holds funds"
- "Vault solvency: **Mathematically guaranteed** - YieldVault balance always ≥ total unclaimed obligations"
- "RoC ceiling: Your Return of Contribution is **hard-capped** at your original contribution and enforced by smart contract math"

### 16.5 Paused State Trust Signal

When paused:

- Banner must clearly distinguish between WHAT is paused (investor claims + transfers) and WHAT still works (operational claims)
- Include Admin Safe address so users can monitor the pause/unpause transactions

### 16.6 Anti-Phishing Indicators

- Display the official contract addresses on the home page so users can cross-reference
- On wallet connect, display the domain name prominently so users can verify they're on the real site
- "Never enter your seed phrase on any LAWP page"
- All external links open in a new tab with `rel="noopener noreferrer"`

---

## 17. Recommended Frontend Architecture

### 17.1 Technology Stack

```bash
Framework:      Next.js 16+ (App Router) or Vite + React 18
Styling:        Vanilla CSS or CSS Modules or Tailwindcss (matches project style guidelines)
Web3 Library:   wagmi v2 + viem v2 (type-safe contract reads/writes)
Wallet:         RainbowKit or ConnectKit (supports MetaMask, WalletConnect, Coinbase)
State:          React Query (TanStack) for server/chain state; Zustand for UI state
Indexing:       The Graph (subgraph indexing LAWP events) or Ponder for event history
Off-chain DB:   Firebase Firestore or Supabase (proposal + signature storage for Board Portal)
Auth:           SIWE (Sign-In With Ethereum) for Board Portal session management
Notifications:  ethers.js WebSocket provider or The Graph subscriptions for real-time event listening
```

### 17.2 Contract Interaction Layer

Define all contracts in a single `contracts.config.ts`:

```typescript
export const LAWP_CONTRACTS = {
  complianceEngine: { address: "0x...", abi: ComplianceEngineABI },
  yieldVault: { address: "0x...", abi: YieldVaultABI },
  operationalVault: { address: "0x...", abi: OperationalVaultABI },
  impactToken: { address: "0x...", abi: ImpactTokenABI },
  multiSigController: { address: "0x...", abi: MultiSigControllerABI },
  actorRegistry: { address: "0x...", abi: ActorRegistryABI },
  cNGN: { address: "0x...", abi: ERC20ABI },
  chainId: 8453, // Base Mainnet
};
```

### 17.3 Key React Hooks to Build

```typescript
// Role detection after wallet connect
useWalletRole(address) -> { isInvestor, isSigner, isCoordinator, isOperationalActor, isAdmin }

// Token portfolio
useImpactTokens(walletAddress) -> { tokens: TokenData[], isLoading, error }

// Per-token claimable
useClaimableYield(tokenId) -> { claimable: bigint, yield: bigint, roc: bigint, isLoading }

// Pool data
usePool(poolId) -> { pool: PoolData, rocStatus: RocStatus, isLoading }

// Proposal list
useProposals(status?: 'pending'|'executed') -> { proposals: Proposal[], isLoading }

// Signature collection
useProposalSignatures(proposalId) -> { signatures: Signature[], progress, thresholdMet }

// System status
useProtocolStatus() -> { paused: boolean, riskFeeBPS: number }

// cNGN allowance + balance
useCNGNState(wallet, spender) -> { balance, allowance, isLoading }
```

### 17.4 Off-chain Backend Architecture (Board Portal)

- Recommended: Firebase or lightweight Node.js + Postgres

API endpoints required:

```bash
POST   /api/proposals                    - Create proposal (Coordinator only)
GET    /api/proposals?status=pending     - List proposals
GET    /api/proposals/:id                - Proposal detail + signatures
POST   /api/proposals/:id/sign           - Submit signature (board member)
GET    /api/proposals/:id/digest         - Fetch EIP-712 digest (from contract)
```

Backend must:

- Verify each signature locally using `ecrecover` before storing
- Verify the signer is registered (`isSigner` mapping)
- Never store private keys
- Mark proposals as executed upon detecting `ProposalExecuted` event on-chain

### 17.5 Subgraph / Event Indexing

Index the following events for efficient historical queries:

```graphql
type Pool @entity {
  id: String! # poolId
  createdAt: BigInt!
  grossAmount: BigInt!
  riskFee: BigInt!
  netCapital: BigInt!
  tokens: [ImpactToken!]! @derivedFrom(field: "pool")
}

type ImpactToken @entity {
  id: String! # tokenId
  pool: Pool!
  owner: String!
  netPrincipal: BigInt!
  poolShareBPS: BigInt!
  rocReturned: BigInt!
  mintedAt: BigInt!
}

type YieldClaimEvent @entity {
  id: String!
  tokenId: String!
  claimer: String!
  yieldAmount: BigInt!
  rocAmount: BigInt!
  timestamp: BigInt!
}

type ProposalExecution @entity {
  id: String! # digest
  proposalId: BigInt!
  poolId: BigInt!
  totalAmount: BigInt!
  flowType: Int!
  timestamp: BigInt!
}
```

### 17.6 cNGN Value Display

All cNGN amounts should be displayed with proper decimal formatting:

- cNGN token decimals: check `cNGN.decimals()` at startup - likely 18 (standard ERC-20)
- Display to 2 decimal places in the UI (e.g., "1,000,000.00 cNGN")
- Use `formatUnits(amount, decimals)` from viem/ethers for conversion
- Never display raw `BigInt` values to end users

---

## 18. Contract Reference Quick-Map

### Function -> Screen Mapping

| Contract Function                             | Calling Surface        | Screen                                  |
| --------------------------------------------- | ---------------------- | --------------------------------------- |
| `engine.processPoolDeposit(...)`              | Admin                  | Admin Panel (Pool Creation)             |
| `engine.routeOperationalAllocation(...)`      | Relayer (via MultiSig) | Executed by `executeProposal`           |
| `engine.claimYield(tokenId)`                  | Investor               | Token Detail, Portfolio                 |
| `engine.claimYieldBatch(tokenIds[])`          | Investor               | Portfolio (Claim All)                   |
| `engine.claimOperationalFunds(wallet)`        | Operational Actor      | Operational Claim page                  |
| `engine.calculateProportionalYield(tokenId)`  | Read-only              | Portfolio, Token Detail                 |
| `engine.isPoolActive(poolId)`                 | Read-only              | Pool list, proposal creation validation |
| `engine.getPoolRocStatus(poolId)`             | Read-only              | Pool Detail, Token Detail               |
| `engine.getRemainingRocCapacity(poolId)`      | Read-only              | Create Proposal (RoC validation)        |
| `engine.emergencyPause()`                     | Admin Safe             | Admin Emergency Panel                   |
| `engine.unpause()`                            | Admin Safe             | Admin Emergency Panel                   |
| `engine.updateRiskFee(bps)`                   | Admin Safe             | Admin Risk Fee Panel                    |
| `impactToken.getTokenData(tokenId)`           | Read-only              | Portfolio, Token Detail                 |
| `impactToken.ownerOf(tokenId)`                | Read-only              | Token Detail (ownership check)          |
| `impactToken.balanceOf(wallet)`               | Read-only              | Portfolio                               |
| `impactToken.transferFrom(from, to, tokenId)` | Investor               | Token Detail (Transfer Modal)           |
| `controller.executeProposal(...)`             | Coordinator            | Proposal Detail (Execute action)        |
| `controller.getProposalDigest(...)`           | Board Member           | Proposal signing (digest verification)  |
| `controller.isSigner(address)`                | Auth Guard             | All Board Portal routes                 |
| `controller.addSigner(address)`               | Admin Safe             | Admin MultiSig Config                   |
| `controller.removeSigner(address)`            | Admin Safe             | Admin MultiSig Config                   |
| `controller.updateThreshold(n)`               | Admin Safe             | Admin MultiSig Config                   |
| `registry.la2Wallet()`                        | Read-only              | Admin Registry Panel                    |
| `registry.setLA2Wallet(address)`              | Admin Safe             | Admin Registry Panel                    |
| (same for mvi1, opTreasury, dev)              | Admin Safe             | Admin Registry Panel                    |
| `cNGN.approve(engine, amount)`                | Coordinator / Investor | ApprovalGate component                  |
| `cNGN.allowance(wallet, engine)`              | Read-only              | ApprovalGate component                  |
| `cNGN.balanceOf(address)`                     | Read-only              | Portfolio, Execution Modal              |

---

_Document end. For questions on specific contract behavior, consult the [BinnaDev](https://binnadev.vercel.app/contact) and inline NatSpec documentation._
