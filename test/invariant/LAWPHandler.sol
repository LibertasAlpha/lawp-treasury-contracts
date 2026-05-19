// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { LAWPComplianceEngine } from "../../src/core/LAWPComplianceEngine.sol";
import { LAWPYieldVault } from "../../src/core/LAWPYieldVault.sol";
import { LAWPOperationalVault } from "../../src/core/LAWPOperationalVault.sol";
import { LAWPImpactToken } from "../../src/core/LAWPImpactToken.sol";
import { MockMultiSig } from "../mocks/MockMultiSig.sol";
import { MockCngn3 } from "../mocks/MockCngn3.sol";
import { LAWPStructs } from "../../src/libraries/LAWPStructs.sol";

/// @title LAWPHandler
/// @notice Fuzzer entry point for invariant testing.
/// @dev The handler is the relayer for all flows:
///        - processPoolDeposit: handler approves engine, calls engine directly.
///        - routeRevenue: handler calls mockMultiSig.execute(poolId, amount, flow).
///          MockMultiSig forwards msg.sender=handler as fundProvider.
///          Engine does safeTransferFrom(handler, vault, amount).
///          -> handler must approve ENGINE (not mockMultiSig).
///        - MockMultiSig holds ZERO cNGN at all times.
///        - Only yieldVault and operationalVault hold protocol cNGN.
contract LAWPHandler is Test {
    LAWPComplianceEngine public engine;
    LAWPYieldVault public yieldVault;
    LAWPOperationalVault public operationalVault;
    LAWPImpactToken public impactToken;
    MockMultiSig public multiSig;
    MockCngn3 public cngn;

    // Active tracking arrays
    address[] public activeUsers;
    uint256[] public activeTokens;
    uint256[] public activePools;

    // Ghost Variables (off-chain parallel truth for invariant verification)
    mapping(uint256 => uint256) public ghost_poolGrossDeposits;
    mapping(uint256 => uint256) public ghost_poolNetDeposits;
    mapping(uint256 => uint256) public ghost_poolYieldRouted;
    mapping(uint256 => uint256) public ghost_poolRocRouted;

    uint256 public ghost_totalClaimedYield;
    uint256 public ghost_totalClaimedRoc;

    // Accumulated inflows to each vault (for solvency checks)
    uint256 public ghost_yieldVaultInflow;
    uint256 public ghost_yieldVaultOutflow;
    uint256 public ghost_opVaultInflow;
    uint256 public ghost_opVaultOutflow;

    uint256 private nextPoolId = 1;

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

        // Seed 5 relayer/depositor addresses
        for (uint160 i = 100; i < 105; i++) {
            address u = address(i);
            activeUsers.push(u);

            vm.prank(cngnOwner);
            cngn.mintTest(u, type(uint128).max);

            // Each user approves the ENGINE - this covers both deposit and routing flows
            vm.prank(u);
            cngn.approve(address(engine), type(uint256).max);
        }
    }

    /*//////////////////////////////////////////////////////////////
                           LENGTH GETTERS
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

    /*//////////////////////////////////////////////////////////////
                           FUZZ TARGETS
    //////////////////////////////////////////////////////////////*/

    /// @notice Simulates a multi-contributor pool deposit by a relayer.
    function processPoolDeposit(uint256 seedAmount, uint256 userCountSeed) external {
        uint256 amount = bound(seedAmount, 10_000e6, 1_000_000e6);
        uint256 userCount = bound(userCountSeed, 1, 5);

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
        bps[userCount - 1] = bpsRemaining;

        uint256 poolId = nextPoolId++;
        address relayer = activeUsers[0];

        // Handler itself is the relayer - has approved engine in constructor
        vm.prank(relayer);
        engine.processPoolDeposit(poolId, amount, users, bps);

        activePools.push(poolId);
        ghost_poolGrossDeposits[poolId] = amount;

        uint256 riskFee = (amount * 1000) / 10_000;
        uint256 netCapital = amount - riskFee;
        ghost_poolNetDeposits[poolId] = netCapital;

        // Vault inflow tracking
        ghost_yieldVaultInflow += amount; // gross goes to yieldVault per source
        ghost_opVaultInflow += riskFee;

        // Track minted token IDs (sequential)
        uint256 startingToken = activeTokens.length + 1;
        for (uint256 i = 0; i < userCount; i++) {
            uint256 expectedTokenId = startingToken + i;
            require(impactToken.ownerOf(expectedTokenId) != address(0), "Handler: Token not minted");
            activeTokens.push(expectedTokenId);
        }

        // INVARIANT: multiSig holds zero cNGN after every operation
        assertEq(cngn.balanceOf(address(multiSig)), 0, "Handler: MockMultiSig balance leaked");
    }

    /// @notice Simulates off-chain revenue routing through the MockMultiSig pass-through.
    ///         The HANDLER is the relayer/fund-provider (msg.sender of multiSig.execute).
    function routeRevenue(uint256 poolSeed, uint256 amountSeed, uint8 flowSeed) external {
        if (activePools.length == 0) return;

        uint256 poolId = activePools[poolSeed % activePools.length];
        uint256 amount = bound(amountSeed, 100e6, 500_000e6);
        LAWPStructs.FlowType flow = LAWPStructs.FlowType(flowSeed % 3);
        address relayer = activeUsers[0];

        // MockMultiSig.execute: relayer calls -> multiSig forwards relayer as fundProvider
        // Engine pulls from relayer. Relayer has approved engine in constructor.
        vm.prank(relayer);
        multiSig.execute(poolId, amount, flow);

        // Update ghost variables per flow type
        if (flow == LAWPStructs.FlowType.RoC) {
            ghost_poolRocRouted[poolId] += amount;
            ghost_yieldVaultInflow += amount;
        } else if (flow == LAWPStructs.FlowType.GRANT_INITIAL) {
            // 30% collective -> yieldVault, 70% -> operationalVault
            uint256 colSplit = (amount * 3000) / 10_000;
            uint256 opSplit = amount - colSplit;
            ghost_poolYieldRouted[poolId] += colSplit;
            ghost_yieldVaultInflow += colSplit;
            ghost_opVaultInflow += opSplit;
        } else if (flow == LAWPStructs.FlowType.GRANT_CONTINUOUS) {
            // 10% collective -> yieldVault, 90% -> operationalVault
            uint256 colSplit = (amount * 1000) / 10_000;
            uint256 opSplit = amount - colSplit;
            ghost_poolYieldRouted[poolId] += colSplit;
            ghost_yieldVaultInflow += colSplit;
            ghost_opVaultInflow += opSplit;
        }

        // INVARIANT: multiSig holds zero cNGN after every operation
        assertEq(cngn.balanceOf(address(multiSig)), 0, "Handler: MockMultiSig balance leaked");
        assertEq(cngn.balanceOf(address(engine)), 0, "Handler: Engine balance leaked");
    }

    /// @notice Simulates a yield claim by a token owner.
    function claimYield(uint256 tokenSeed) external {
        if (activeTokens.length == 0) return;
        uint256 tokenId = activeTokens[tokenSeed % activeTokens.length];
        address owner = impactToken.ownerOf(tokenId);

        uint256 claimable = engine.calculateProportionalYield(tokenId);
        if (claimable == 0) return;

        LAWPStructs.TokenData memory dataBefore = impactToken.getTokenData(tokenId);
        uint256 yieldClaimedBefore = engine.yieldClaimed(tokenId);

        vm.prank(owner);
        engine.claimYield(tokenId);

        LAWPStructs.TokenData memory dataAfter = impactToken.getTokenData(tokenId);
        uint256 yieldClaimedAfter = engine.yieldClaimed(tokenId);

        uint256 newlyClaimedRoc = dataAfter.rocReturned - dataBefore.rocReturned;
        uint256 newlyClaimedYield = yieldClaimedAfter - yieldClaimedBefore;

        ghost_totalClaimedRoc += newlyClaimedRoc;
        ghost_totalClaimedYield += newlyClaimedYield;

        ghost_yieldVaultOutflow += (newlyClaimedRoc + newlyClaimedYield);

        // INVARIANT F: Claim idempotency - second claim must return 0
        assertEq(engine.calculateProportionalYield(tokenId), 0, "Invariant F: Claim not idempotent");
    }

    /// @notice Simulates an NFT transfer that triggers the CEI yield flush hook.
    function transferToken(uint256 tokenSeed, uint256 receiverSeed) external {
        if (activeTokens.length == 0) return;
        uint256 tokenId = activeTokens[tokenSeed % activeTokens.length];
        address from = impactToken.ownerOf(tokenId);
        address to = activeUsers[receiverSeed % activeUsers.length];
        if (from == to) return;

        uint256 claimableBefore = engine.calculateProportionalYield(tokenId);
        LAWPStructs.TokenData memory dataBefore = impactToken.getTokenData(tokenId);
        uint256 yieldClaimedBefore = engine.yieldClaimed(tokenId);
        uint256 fromBalBefore = cngn.balanceOf(from);

        vm.prank(from);
        impactToken.transferFrom(from, to, tokenId);

        LAWPStructs.TokenData memory dataAfter = impactToken.getTokenData(tokenId);
        uint256 yieldClaimedAfter = engine.yieldClaimed(tokenId);

        uint256 flushedRoc = dataAfter.rocReturned - dataBefore.rocReturned;
        uint256 flushedYield = yieldClaimedAfter - yieldClaimedBefore;

        ghost_totalClaimedRoc += flushedRoc;
        ghost_totalClaimedYield += flushedYield;
        ghost_yieldVaultOutflow += (flushedRoc + flushedYield);

        // INVARIANT D1: Sender received exactly the flushed yield
        assertEq(
            cngn.balanceOf(from),
            fromBalBefore + flushedYield + flushedRoc,
            "Invariant D1: Sender not compensated"
        );

        // INVARIANT D2: Receiver inherits zero pending yield
        assertEq(
            engine.calculateProportionalYield(tokenId),
            0,
            "Invariant D2: Receiver inherited false yield"
        );

        // INVARIANT D3: No yield duplication
        assertEq(
            flushedYield + flushedRoc, claimableBefore, "Invariant D3: Yield duplicated in transfer"
        );
    }
}
