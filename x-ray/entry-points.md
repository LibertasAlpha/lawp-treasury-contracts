# Entry Point Map

> LAWP Treasury Contracts | 13 entry points | 4 permissionless | 4 role-gated | 5 admin-only

---

## Protocol Flow Paths

### Setup (Admin)

`DeployLAWPSystem` → `LAWPComplianceEngine.set*Wallet()`
`LAWPContributionPool.createPool()` ◄── Must be CAMPAIGN_MANAGER

### Contribution Flow (User)

`LAWPContributionPool.contribute()` ◄── Pool must be active and within timeframe
├─→ `cNGN.transferFrom()`

### Settlement Flow (Campaign Manager)

`[contributions exist]` → `LAWPContributionPool.settle()` ◄── Timeframe ended
├─→ `LAWPComplianceEngine.processPoolDeposit()`
├─→ `LAWPImpactToken.mint()`
└─→ `cNGN.transfer()` (to vaults)

### Yield Claim Flow (User)

`[yield deposited to Vault]` → `LAWPComplianceEngine.claimYield()` ◄── Caller owns Impact Token
├─→ `LAWPYieldVault.executeTransfer()`
├─→ `cNGN.transfer()` (to user)
└─→ `LAWPImpactToken.burn()`

---

## Permissionless

### `LAWPContributionPool.contribute()`

| Aspect           | Detail                                                 |
| ---------------- | ------------------------------------------------------ |
| Visibility       | external, nonReentrant                                 |
| Caller           | User                                                   |
| Parameters       | \_poolId (user-controlled), \_amount (user-controlled) |
| Call chain       | `→ cNGN.transferFrom()`                                |
| State modified   | `pool.amountRaised`, `contributions[user]`             |
| Value flow       | User → Pool                                            |
| Reentrancy guard | yes                                                    |

### `LAWPContributionPool.claimRefund()`

| Aspect           | Detail                                     |
| ---------------- | ------------------------------------------ |
| Visibility       | external, nonReentrant                     |
| Caller           | User                                       |
| Parameters       | \_poolId (user-controlled)                 |
| Call chain       | `→ cNGN.transfer()`                        |
| State modified   | `pool.amountRaised`, `contributions[user]` |
| Value flow       | Pool → User                                |
| Reentrancy guard | yes                                        |

### `LAWPComplianceEngine.claimYield()`

| Aspect           | Detail                                                 |
| ---------------- | ------------------------------------------------------ |
| Visibility       | external, nonReentrant                                 |
| Caller           | User                                                   |
| Parameters       | \_tokenId (user-controlled)                            |
| Call chain       | `→ LAWPYieldVault.executeTransfer() → cNGN.transfer()` |
| State modified   | `tokenYieldData`, `yieldAllocations`                   |
| Value flow       | Yield Vault → User                                     |
| Reentrancy guard | yes                                                    |

### `LAWPComplianceEngine.claimYieldBatch()`

| Aspect           | Detail                                                 |
| ---------------- | ------------------------------------------------------ |
| Visibility       | external, nonReentrant                                 |
| Caller           | User                                                   |
| Parameters       | \_tokenIds (user-controlled)                           |
| Call chain       | `→ LAWPYieldVault.executeTransfer() → cNGN.transfer()` |
| State modified   | `tokenYieldData`, `yieldAllocations`                   |
| Value flow       | Yield Vault → User                                     |
| Reentrancy guard | yes                                                    |

---

## Role-Gated

### `CAMPAIGN_MANAGER_ROLE`

#### `LAWPContributionPool.settle()`

| Aspect           | Detail                                        |
| ---------------- | --------------------------------------------- |
| Visibility       | external, nonReentrant                        |
| Caller           | Campaign Manager                              |
| Parameters       | \_poolId (user-controlled)                    |
| Call chain       | `→ LAWPComplianceEngine.processPoolDeposit()` |
| State modified   | `pool.state`                                  |
| Value flow       | Pool → Vaults                                 |
| Reentrancy guard | yes                                           |

#### `LAWPContributionPool.cancelPool()`

| Aspect           | Detail                     |
| ---------------- | -------------------------- |
| Visibility       | external                   |
| Caller           | Campaign Manager           |
| Parameters       | \_poolId (user-controlled) |
| Call chain       | none                       |
| State modified   | `pool.state`               |
| Value flow       | None                       |
| Reentrancy guard | no                         |

### `OPERATOR_ROLE`

#### `LAWPComplianceEngine.routeOperationalAllocation()`

| Aspect           | Detail                                                                    |
| ---------------- | ------------------------------------------------------------------------- |
| Visibility       | external, nonReentrant                                                    |
| Caller           | Operator (MultiSig)                                                       |
| Parameters       | \_poolId, \_totalAmount, \_fundProvider, \_flowType (all user-controlled) |
| Call chain       | `→ LAWPOperationalVault.executeTransfer() → cNGN.transfer()`              |
| State modified   | `operationalBalance`                                                      |
| Value flow       | Operational Vault → Destination                                           |
| Reentrancy guard | yes                                                                       |

#### `LAWPMultiSigController.executeProposal()`

| Aspect           | Detail                                                                      |
| ---------------- | --------------------------------------------------------------------------- |
| Visibility       | external, nonReentrant                                                      |
| Caller           | Anyone with valid signatures                                                |
| Parameters       | \_proposalId, \_poolId, \_totalAmount, \_flowType, \_deadline, \_signatures |
| Call chain       | `→ LAWPComplianceEngine.routeOperationalAllocation()`                       |
| State modified   | `isExecuted`                                                                |
| Value flow       | Operational Vault → Destination                                             |
| Reentrancy guard | yes                                                                         |

---

## Admin-Only

| Contract               | Function            | Parameters     | State Modified |
| ---------------------- | ------------------- | -------------- | -------------- |
| LAWPComplianceEngine   | `setLA2Wallet()`    | \_la2Wallet    | `la2Wallet`    |
| LAWPComplianceEngine   | `updateRiskFee()`   | \_newFeeBPS    | `rocFeeBPS`    |
| LAWPComplianceEngine   | `emergencyPause()`  | none           | `_paused`      |
| LAWPMultiSigController | `updateThreshold()` | \_newThreshold | `threshold`    |
| LAWPImpactToken        | `setBaseURI()`      | \_uri          | `baseURI`      |
