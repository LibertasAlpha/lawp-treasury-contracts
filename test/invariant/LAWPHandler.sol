// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { LAWPComplianceEngine } from "../../src/core/LAWPComplianceEngine.sol";
import { LAWPYieldVault } from "../../src/core/LAWPYieldVault.sol";
import { LAWPOperationalVault } from "../../src/core/LAWPOperationalVault.sol";
import { LAWPImpactToken } from "../../src/core/LAWPImpactToken.sol";
import { MockMultiSig } from "../mocks/MockMultiSig.sol";
import { MockCngn3 } from "../mocks/MockCngn3.sol";
import { LAWPStructs } from "../../src/libraries/LAWPStructs.sol";

/*//////////////////////////////////////////////////////////////
                     LAWPHANDLER FUZZER ENTRY POINT
//////////////////////////////////////////////////////////////*/

/**
 * @notice This contract serves as the "handler" for Foundry's invariant testing framework.
 *         It provides fuzz targets that simulate realistic user interactions
 *         with the LAWP protocol, including pool deposits, revenue routing, yield claiming, NFT
 *         transfers, and operational claims.
 *         The handler maintains "ghost variables" to track expected state changes
 *         and enforce micro-invariants immediately after each fuzz target execution.
 *
 *        These micro-invariants catch issues early and make debugging easier.
 *        The main invariant test (LAWPInvariantTest) will call these targets with random inputs
 *        and then check global invariants after each call.
 *        By structuring the tests this way, we can achieve broad coverage of complex interactions
 *        while still having precise assertions about the protocol's behavior.
 */
contract LAWPHandler is Test {
    /*//////////////////////////////////////////////////////////////
                           PROTOCOL CONTRACTS
    //////////////////////////////////////////////////////////////*/

    LAWPOperationalVault public operationalVault;
    LAWPYieldVault public yieldVault;

    LAWPComplianceEngine public engine;
    LAWPImpactToken public impactToken;
    MockMultiSig public multiSig;
    MockCngn3 public cngn;

    /*//////////////////////////////////////////////////////////////
                            TRACKING ARRAYS
    //////////////////////////////////////////////////////////////*/

    /// @notice Addresses that have been seeded with cNGN and have approved the engine.
    address[] public activeUsers;

    /// @notice Token IDs that have been minted (sequentially starting at 1).
    uint256[] public activeTokens;

    /// @notice Pool IDs that have been successfully created via processPoolDeposit.
    uint256[] public activePools;

    /*//////////////////////////////////////////////////////////////
                            GHOST VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Total gross cNGN deposited into a pool (before risk fee).
    mapping(uint256 poolId => uint256 gross) public ghost_poolGrossDeposits;

    /// @notice Net capital assigned to token holders per pool (gross minus risk fee).
    mapping(uint256 poolId => uint256 net) public ghost_poolNetDeposits;

    /// @notice Cumulative collective yield routed to a pool (from GRANT flows).
    ///         Mirrors engine.poolYieldTracker - used for sync invariant G.
    mapping(uint256 poolId => uint256 yield) public ghost_poolYieldRouted;

    /// @notice Cumulative RoC routed to a pool.
    ///         Mirrors engine.poolRocTracker - used for sync invariant G.
    mapping(uint256 poolId => uint256 roc) public ghost_poolRocRouted;

    /// @notice Snapshots of poolYieldTracker BEFORE each routeRevenue call.
    ///         Used to enforce Invariant K (monotonicity - tracker only increases).
    mapping(uint256 poolId => uint256 prev) public ghost_prevPoolYieldTracker;

    /// @notice Snapshots of poolRocTracker BEFORE each routeRevenue call.
    mapping(uint256 poolId => uint256 prev) public ghost_prevPoolRocTracker;

    /*//////////////////////////////////////////////////////////////
        GHOST VARIABLES - TOKEN LEVEL (snapshots at mint time)
    //////////////////////////////////////////////////////////////*/

    /// @notice Records each token's netPrincipal at the moment of minting.
    ///         Used by Invariant L to verify that principal is immutable post-mint.
    mapping(uint256 tokenId => uint256 principal) public ghost_tokenPrincipalSnapshot;

    /// @notice Records each token's poolShareBPS at the moment of minting.
    ///         Used by Invariant L to verify that BPS is immutable post-mint.
    mapping(uint256 tokenId => uint256 bps) public ghost_tokenBPSSnapshot;

    /// @notice Snapshots of rocReturned BEFORE each claimYield/transfer call.
    ///         Used to enforce Invariant P (RoC can only increase, never decrease).
    mapping(uint256 tokenId => uint256 roc) public ghost_prevRocReturned;

    /*//////////////////////////////////////////////////////////////
                 GHOST VARIABLES - GLOBAL CLAIM TOTALS
    //////////////////////////////////////////////////////////////*/

    /// @notice Total cNGN paid out from yieldVault via yield claims.
    uint256 public ghost_totalClaimedYield;

    /// @notice Total cNGN paid out from yieldVault via RoC claims.
    uint256 public ghost_totalClaimedRoc;

    /*//////////////////////////////////////////////////////////////
        GHOST VARIABLES - VAULT CASH-FLOW (used for Conservation Invariant M)
    //////////////////////////////////////////////////////////////*/

    /// @notice Total cNGN ever deposited INTO yieldVault from any source.
    uint256 public ghost_yieldVaultInflow;

    /// @notice Total cNGN ever paid OUT of yieldVault to claimants.
    uint256 public ghost_yieldVaultOutflow;

    /// @notice Total cNGN ever deposited INTO operationalVault from any source.
    uint256 public ghost_opVaultInflow;

    /// @notice Total cNGN ever paid OUT of operationalVault to operational actors.
    uint256 public ghost_opVaultOutflow;

    /*//////////////////////////////////////////////////////////////
                           INTERNAL COUNTERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Auto-incrementing pool ID. Starts at 1, never reuses IDs.
    uint256 private nextPoolId = 1;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Stores contract references and seeds 5 relayer addresses.
    /// @dev Each relayer gets max uint128 cNGN and approves the ENGINE (not multiSig).
    ///      One approval covers BOTH deposit and routing flows:
    ///       - processPoolDeposit: engine pulls from relayer directly.
    ///       - routeRevenue: multiSig forwards relayer -> engine pulls from relayer.
    constructor(
        LAWPComplianceEngine _engine,
        LAWPYieldVault _yieldVault,
        LAWPOperationalVault _operationalVault,
        LAWPImpactToken _impactToken,
        MockMultiSig _multiSig,
        MockCngn3 _cngn
    ) {
        engine = _engine;
        yieldVault = _yieldVault;
        operationalVault = _operationalVault;
        impactToken = _impactToken;
        multiSig = _multiSig;
        cngn = _cngn;

        address cngnOwner = cngn.owner();

        // Seed 5 stable relayer addresses. Using address(100)–address(104) gives
        // deterministic, non-overlapping addresses that won't collide with test actors.
        for (uint160 i = 100; i < 105; i++) {
            address u = address(i);
            activeUsers.push(u);

            // Give unlimited cNGN so balance is never the bottleneck in fuzzing.
            vm.prank(cngnOwner);
            cngn.mintTest(u, type(uint128).max);

            // Approve ENGINE (not multiSig!) for both deposit + routing.
            vm.prank(u);
            cngn.approve(address(engine), type(uint256).max);
        }
    }

    /*//////////////////////////////////////////////////////////////
                             LENGTH GETTERS
    Public getters for array lengths so the invariant test can iterate safely.
    //////////////////////////////////////////////////////////////*/

    function activeTokensLength() external view returns (uint256) {
        return activeTokens.length;
    }

    function activePoolsLength() external view returns (uint256) {
        return activePools.length;
    }

    function activeUsersLength() external view returns (uint256) {
        return activeUsers.length;
    }

    /// TARGET 1: processPoolDeposit
    /// @notice Simulates an investor pool deposit by the relayer.
    ///
    /// @dev WHAT HAPPENS ON-CHAIN:
    ///      engine.processPoolDeposit(poolId, grossAmount, contributors, bps)
    ///        - Validates BPS array sums to 10_000
    ///        - Computes riskFee = grossAmount * 10% -> operationalVault
    ///        - Transfers netCapital (grossAmount - riskFee) -> yieldVault
    ///        - Mints one ERC-721 token per contributor
    ///
    ///      NOTE: The riskFee goes to opVault and netCapital goes to yieldVault.
    ///      Total cNGN pulled from the relayer = grossAmount (riskFee + netCapital).
    ///
    /// @dev GHOST UPDATES:
    ///      Records gross, net, and vault inflows for Conservation Invariant M.
    ///      Snapshots each new token's principal and BPS for Immutability Invariant L.
    ///
    /// @param seedAmount    Raw fuzz input - clamped to [10_000e6, 1_000_000e6].
    /// @param userCountSeed Raw fuzz input - clamped to [1, 5] contributors.
    function processPoolDeposit(uint256 seedAmount, uint256 userCountSeed) external {
        // 1. Constrain fuzz inputs to valid ranges
        uint256 amount = bound(seedAmount, 10_000e6, 1_000_000e6);
        uint256 userCount = bound(userCountSeed, 1, 5);

        // 2. Build valid contributor + BPS arrays
        // Strategy: halve the remaining BPS for each contributor; the last one
        // gets all remainder. This guarantees sum == 10_000 regardless of count.
        address[] memory users = new address[](userCount);
        uint256[] memory bps = new uint256[](userCount);

        uint256 bpsRemaining = 10_000;
        for (uint256 i = 0; i < userCount - 1; i++) {
            users[i] = activeUsers[i];
            uint256 share = bpsRemaining / 2;
            bps[i] = share;
            bpsRemaining -= share;
        }
        users[userCount - 1] = activeUsers[userCount - 1];
        bps[userCount - 1] = bpsRemaining; // Dust assignment - guaranteed sum == 10_000

        // 3. Assign unique pool ID and call the protocol
        uint256 poolId = nextPoolId++;
        address relayer = activeUsers[0]; // Stable relayer - pre-approved in constructor

        vm.prank(relayer);
        engine.processPoolDeposit(poolId, amount, users, bps);

        // 4. Update tracking arrays
        activePools.push(poolId);

        // 5. Compute and record ghost variables
        uint256 riskFee = (amount * 1000) / 10_000;
        uint256 netCapital = amount - riskFee;

        ghost_poolGrossDeposits[poolId] = amount;
        ghost_poolNetDeposits[poolId] = netCapital;

        // yieldVault receives the net capital; opVault receives only the risk fee.
        ghost_yieldVaultInflow += netCapital;
        ghost_opVaultInflow += riskFee;

        // 6. Snapshot minted token data for Invariant L (Immutability)
        // Token IDs are sequential starting at 1. The next batch of IDs starts
        // immediately after the last known token.
        uint256 startingTokenId = activeTokens.length + 1;
        for (uint256 i = 0; i < userCount; i++) {
            uint256 tokenId = startingTokenId + i;

            // Verify the token actually exists before tracking it
            require(
                impactToken.ownerOf(tokenId) != address(0),
                "Handler: Token not minted - sequential ID assumption violated"
            );

            // Snapshot the token's principal and BPS at the moment of creation.
            // Invariant L will compare current state to these snapshots.
            LAWPStructs.TokenData memory data = impactToken.getTokenData(tokenId);
            ghost_tokenPrincipalSnapshot[tokenId] = data.netPrincipal;
            ghost_tokenBPSSnapshot[tokenId] = data.poolShareBPS;

            activeTokens.push(tokenId);
        }

        // 7. Micro-invariant: Zero-custody check
        // The MockMultiSig must still hold zero after deposit (it's not involved
        // in deposit flows, but we assert it here for belt-and-suspenders).
        assertEq(
            cngn.balanceOf(address(multiSig)),
            0,
            "Handler post-deposit: MockMultiSig balance leaked"
        );
    }

    // TARGET 2: routeRevenue
    /// @notice Simulates off-chain revenue being routed through the MockMultiSig.
    ///
    /// @dev WHAT HAPPENS ON-CHAIN:
    ///      relayer -> multiSig.execute(poolId, amount, flow)
    ///        - multiSig -> engine.routeOperationalAllocation(poolId, amount, relayer, flow)
    ///              - RoC:              safeTransferFrom(relayer -> yieldVault, amount)
    ///              - GRANT_INITIAL:    safeTransferFrom(relayer -> yieldVault,  30%)
    ///                                 safeTransferFrom(relayer -> opVault,     70%)
    ///              - GRANT_CONTINUOUS: safeTransferFrom(relayer -> yieldVault,  10%)
    ///                                  safeTransferFrom(relayer -> opVault,     90%)
    ///
    ///      MockMultiSig forwards msg.sender as _fundProvider -> engine pulls
    ///      cNGN DIRECTLY from the relayer. The multiSig never holds any tokens.
    ///
    /// @dev GHOST UPDATES:
    ///      Records yield/RoC splits per pool. Checks monotonicity of trackers.
    ///      Updates global inflow tracking for Conservation Invariant M.
    ///
    /// @param poolSeed   Selects a random existing pool from activePools[].
    /// @param amountSeed Clamped to [100e6, 500_000e6].
    /// @param flowSeed   Selects FlowType: 0=RoC, 1=GRANT_INITIAL, 2=GRANT_CONTINUOUS.
    function routeRevenue(uint256 poolSeed, uint256 amountSeed, uint8 flowSeed) external {
        // Guard: cannot route revenue if no pools exist yet.
        if (activePools.length == 0) return;

        // 1. Constrain random inputs
        uint256 poolId = activePools[poolSeed % activePools.length];
        uint256 amount = bound(amountSeed, 100e6, 500_000e6);
        LAWPStructs.FlowType flow = LAWPStructs.FlowType(flowSeed % 3);
        address relayer = activeUsers[0];

        // 2. Snapshot on-chain tracker values BEFORE the call
        // These are used to enforce Invariant K (monotonicity):
        // the trackers can only ever increase, never decrease.
        ghost_prevPoolYieldTracker[poolId] = engine.poolYieldTracker(poolId);
        ghost_prevPoolRocTracker[poolId] = engine.poolRocTracker(poolId);

        // 3. Execute via MockMultiSig (pass-through only)
        // relayer becomes msg.sender inside multiSig.execute(),
        // so the engine receives _fundProvider = relayer.
        vm.prank(relayer);
        multiSig.execute(poolId, amount, flow);

        // 4. Update ghost variables based on flow type
        if (flow == LAWPStructs.FlowType.RoC) {
            // 100% goes into yieldVault as Return of Contribution
            ghost_poolRocRouted[poolId] += amount;
            ghost_yieldVaultInflow += amount;
        } else if (flow == LAWPStructs.FlowType.GRANT_INITIAL) {
            // System 1: 30% collective -> yieldVault | 70% operational -> opVault
            // (50% LA2 + 20% MVI1 = 70% operational)
            uint256 colSplit = (amount * 3000) / 10_000;
            uint256 opSplit = amount - colSplit;
            ghost_poolYieldRouted[poolId] += colSplit;
            ghost_yieldVaultInflow += colSplit;
            ghost_opVaultInflow += opSplit;
        } else if (flow == LAWPStructs.FlowType.GRANT_CONTINUOUS) {
            // System 2: 10% collective -> yieldVault | 90% operational -> opVault
            // (55% LA2 + 25% MVI1 + 10% Dev = 90% operational)
            uint256 colSplit = (amount * 1000) / 10_000;
            uint256 opSplit = amount - colSplit;
            ghost_poolYieldRouted[poolId] += colSplit;
            ghost_yieldVaultInflow += colSplit;
            ghost_opVaultInflow += opSplit;
        }

        // 5. Micro-invariants: Monotonicity (Invariant K enforced locally) -
        // The on-chain tracker must now be >= its value before this call.
        assertGe(
            engine.poolYieldTracker(poolId),
            ghost_prevPoolYieldTracker[poolId],
            "Handler routeRevenue: poolYieldTracker decreased (monotonicity violated)"
        );
        assertGe(
            engine.poolRocTracker(poolId),
            ghost_prevPoolRocTracker[poolId],
            "Handler routeRevenue: poolRocTracker decreased (monotonicity violated)"
        );

        // 6. Zero-custody micro-invariants
        assertEq(
            cngn.balanceOf(address(multiSig)),
            0,
            "Handler routeRevenue: MockMultiSig holds cNGN (custody violation)"
        );
        assertEq(
            cngn.balanceOf(address(engine)),
            0,
            "Handler routeRevenue: Engine holds cNGN (custody violation)"
        );
    }

    // TARGET 3: claimYield
    /// @notice Simulates a token owner pulling their accrued yield and/or RoC.
    ///
    /// @dev WHAT HAPPENS ON-CHAIN:
    ///      engine.claimYield(_tokenId)
    ///        - Computes claimable yield: (poolYieldTracker * BPS / 10_000) - yieldClaimed
    ///        - Computes claimable RoC:   (poolRocTracker * BPS / 10_000) - rocReturned,
    ///          capped at principal
    ///        - Effects: updates yieldClaimed and rocReturned BEFORE transfer (CEI)
    ///        - Interaction: yieldVault.executeTransfer(owner, totalClaim)
    ///
    /// @dev GHOST UPDATES:
    ///      Tracks total claimed yield and RoC globally. Records yieldVault outflow.
    ///      Snapshots rocReturned before claim for Invariant P (RoC monotonicity).
    ///
    /// @param tokenSeed Selects a random token from activeTokens[].
    function claimYield(uint256 tokenSeed) external {
        // Guard: cannot claim if no tokens exist.
        if (activeTokens.length == 0) return;

        uint256 tokenId = activeTokens[tokenSeed % activeTokens.length];
        address owner = impactToken.ownerOf(tokenId);

        // Skip silently if nothing is claimable - allows fuzzer to call this freely.
        uint256 claimable = engine.calculateProportionalYield(tokenId);
        if (claimable == 0) return;

        // Snapshot state BEFORE the claim
        LAWPStructs.TokenData memory dataBefore = impactToken.getTokenData(tokenId);
        uint256 yieldClaimedBefore = engine.yieldClaimed(tokenId);
        ghost_prevRocReturned[tokenId] = dataBefore.rocReturned;

        // Execute the claim as the token owner (msg.sender = owner) to satisfy access control.
        vm.prank(owner);
        engine.claimYield(tokenId);

        // Measure what actually changed
        LAWPStructs.TokenData memory dataAfter = impactToken.getTokenData(tokenId);
        uint256 yieldClaimedAfter = engine.yieldClaimed(tokenId);

        uint256 newlyClaimedRoc = dataAfter.rocReturned - dataBefore.rocReturned;
        uint256 newlyClaimedYield = yieldClaimedAfter - yieldClaimedBefore;

        // Update global ghost accounting
        ghost_totalClaimedRoc += newlyClaimedRoc;
        ghost_totalClaimedYield += newlyClaimedYield;
        ghost_yieldVaultOutflow += (newlyClaimedRoc + newlyClaimedYield);

        // Micro-invariant F: Claim idempotency
        // Immediately after a successful claim, calculateProportionalYield must
        // return 0. This proves the CEI pattern works (state updated before transfer).
        assertEq(
            engine.calculateProportionalYield(tokenId),
            0,
            "Handler claimYield (Invariant F): Claim not idempotent - double-claim possible"
        );

        // Micro-invariant P: RoC monotonicity
        // rocReturned can only ever increase. A bug that decreases it would
        // allow claiming more principal than was invested.
        assertGe(
            dataAfter.rocReturned,
            ghost_prevRocReturned[tokenId],
            "Handler claimYield (Invariant P): rocReturned decreased - monotonicity violated"
        );
    }

    // TARGET 4: transferToken
    /// @notice Simulates an NFT secondary market transfer that triggers the CEI yield flush.
    ///
    /// @dev WHAT HAPPENS ON-CHAIN:
    ///      impactToken.transferFrom(from, to, tokenId)
    ///        - _update hook fires -> engine.claimYield(tokenId) for `from`
    ///              (pending yield is flushed to seller before ownership changes)
    ///
    ///      This prevents the buyer from inheriting yield that was earned by the
    ///      seller before the transfer. After the hook fires, the new owner starts
    ///      with a clean slate (zero pending yield).
    ///
    /// @dev GHOST UPDATES:
    ///      Same as claimYield - the hook performs an implicit claim.
    ///
    /// @param tokenSeed    Selects a random token from activeTokens[].
    /// @param receiverSeed Selects a random receiver from activeUsers[].
    function transferToken(uint256 tokenSeed, uint256 receiverSeed) external {
        if (activeTokens.length == 0) return;

        uint256 tokenId = activeTokens[tokenSeed % activeTokens.length];
        address from = impactToken.ownerOf(tokenId);
        address to = activeUsers[receiverSeed % activeUsers.length];

        // Skip self-transfers - they're a no-op in ERC-721 and unhelpful here.
        if (from == to) return;

        // Snapshot state BEFORE the transfer -
        uint256 claimableBefore = engine.calculateProportionalYield(tokenId);
        LAWPStructs.TokenData memory dataBefore = impactToken.getTokenData(tokenId);
        uint256 yieldClaimedBefore = engine.yieldClaimed(tokenId);
        uint256 fromBalBefore = cngn.balanceOf(from);
        ghost_prevRocReturned[tokenId] = dataBefore.rocReturned;

        // Execute the transfer
        vm.prank(from);
        impactToken.transferFrom(from, to, tokenId);

        // Measure the flush
        LAWPStructs.TokenData memory dataAfter = impactToken.getTokenData(tokenId);
        uint256 yieldClaimedAfter = engine.yieldClaimed(tokenId);

        uint256 flushedRoc = dataAfter.rocReturned - dataBefore.rocReturned;
        uint256 flushedYield = yieldClaimedAfter - yieldClaimedBefore;

        // Update global ghost accounting --
        ghost_totalClaimedRoc += flushedRoc;
        ghost_totalClaimedYield += flushedYield;
        ghost_yieldVaultOutflow += (flushedRoc + flushedYield);

        // Micro-invariant D1: Seller compensated in full
        // The seller's cNGN balance must increase by exactly the flushed amount.
        assertEq(
            cngn.balanceOf(from),
            fromBalBefore + flushedYield + flushedRoc,
            "Handler transferToken (Invariant D1): Seller not fully compensated for flushed yield"
        );

        // Micro-invariant D2: Buyer inherits zero pending yield
        // The new owner must start with a clean slate. If the hook didn't fire,
        // the buyer would inherit the seller's pending yield (double-dipping bug).
        assertEq(
            engine.calculateProportionalYield(tokenId),
            0,
            "Handler transferToken (Invariant D2): Buyer inherited seller's pending yield"
        );

        // Micro-invariant D3: No yield duplication
        // The total flushed must equal exactly what was claimable before.
        // If flushed > claimableBefore, the hook created yield from nothing.
        assertEq(
            flushedYield + flushedRoc,
            claimableBefore,
            "Handler transferToken (Invariant D3): Yield duplicated during transfer hook"
        );

        // Micro-invariant P: RoC monotonicity
        assertGe(
            dataAfter.rocReturned,
            ghost_prevRocReturned[tokenId],
            "Handler transferToken (Invariant P): rocReturned decreased after hook"
        );
    }

    // TARGET 5: claimOperational
    /// @notice Simulates an operational actor (LA2, MVI1, Dev, etc.) pulling
    ///         their allocated share from the OperationalVault.
    ///
    /// @dev WHAT HAPPENS ON-CHAIN:
    ///      engine.claimOperationalFunds(_wallet)
    ///        - Reads operationalBalances[_wallet]
    ///        - Zeroes the ledger entry (CEI - state before interaction)
    ///        - operationalVault.executeTransfer(_wallet, amount)
    ///
    /// @dev GHOST UPDATES:
    ///      Records the outflow from operationalVault for Conservation Invariant M.
    ///
    /// @param userSeed Selects a random user from activeUsers[].
    function claimOperational(uint256 userSeed) external {
        address wallet = activeUsers[userSeed % activeUsers.length];

        // Skip if no operational balance exists - avoids reverting.
        uint256 balance = engine.operationalBalances(wallet);
        if (balance == 0) return;

        uint256 walletBalBefore = cngn.balanceOf(wallet);

        // Execute the claim - note engine.claimOperationalFunds takes _wallet param.
        engine.claimOperationalFunds(wallet);

        // Update ghost: opVault outflow
        ghost_opVaultOutflow += balance;

        // Micro-invariant: Exact withdrawal --
        // The wallet must receive exactly the amount that was in the ledger.
        assertEq(
            cngn.balanceOf(wallet),
            walletBalBefore + balance,
            "Handler claimOperational: Wallet received wrong amount"
        );

        // Micro-invariant: Ledger zeroed (CEI confirmed)
        assertEq(
            engine.operationalBalances(wallet),
            0,
            "Handler claimOperational: Ledger not zeroed after claim (CEI violated)"
        );
    }
}
