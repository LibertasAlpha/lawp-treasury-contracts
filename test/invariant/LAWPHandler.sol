// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { LAWPComplianceEngine } from "../../src/core/LAWPComplianceEngine.sol";
import { LAWPTreasury } from "../../src/core/LAWPTreasury.sol";
import { LAWPImpactToken } from "../../src/core/LAWPImpactToken.sol";
import { MockMultiSig } from "../mocks/MockMultiSig.sol";
import { MockCngn3 } from "../mocks/MockCngn3.sol";
import { LAWPStructs } from "../../src/libraries/LAWPStructs.sol";

contract LAWPHandler is Test {
    LAWPComplianceEngine public engine;
    LAWPTreasury public treasury;
    LAWPImpactToken public impactToken;
    MockMultiSig public multiSig;
    MockCngn3 public cngn;

    // Fuzzer State Tracking
    address[] public activeUsers;
    uint256[] public activeTokens;
    uint256[] public activePools;

    // Ghost Variables for Parallel Truth Verification
    mapping(uint256 => uint256) public ghost_poolGrossDeposits;
    mapping(uint256 => uint256) public ghost_poolNetDeposits;
    mapping(uint256 => uint256) public ghost_poolYieldRouted;
    mapping(uint256 => uint256) public ghost_poolRocRouted;

    uint256 public ghost_totalClaimedYield;
    uint256 public ghost_totalClaimedRoc;
    uint256 public ghost_totalRiskFees;

    // Explicit Treasury Flow Tracking
    uint256 public ghost_treasuryInflow;
    uint256 public ghost_treasuryOutflow;

    uint256 private nextPoolId = 1;

    constructor(
        LAWPComplianceEngine _engine,
        LAWPTreasury _treasury,
        LAWPImpactToken _impactToken,
        MockMultiSig _multiSig,
        MockCngn3 _cngn
    ) {
        engine = _engine;
        treasury = _treasury;
        impactToken = _impactToken;
        multiSig = _multiSig;
        cngn = _cngn;

        address cngnOwner = cngn.owner();

        // Seed 5 valid users
        for (uint160 i = 100; i < 105; i++) {
            address u = address(i);
            activeUsers.push(u);

            // Explicitly prank the token owner to bypass OwnableUnauthorizedAccount
            vm.prank(cngnOwner);
            cngn.mintTest(u, type(uint128).max);

            vm.prank(u);
            cngn.approve(address(engine), type(uint256).max);
        }

        vm.prank(cngnOwner);
        cngn.mintTest(address(treasury), type(uint128).max); // Prevent insolvency from mock external grants
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

    function processPoolDeposit(uint256 seedAmount, uint256 userCountSeed) external {
        uint256 amount = bound(seedAmount, 10_000e6, 10_000_000e6);
        uint256 userCount = bound(userCountSeed, 1, 5);

        address[] memory users = new address[](userCount);
        uint256[] memory bps = new uint256[](userCount);

        uint256 bpsRemaining = 10000;
        for (uint256 i = 0; i < userCount - 1; i++) {
            users[i] = activeUsers[i];
            uint256 share = bpsRemaining / 2; // Arbitrary split
            bps[i] = share;
            bpsRemaining -= share;
        }
        users[userCount - 1] = activeUsers[userCount - 1];
        bps[userCount - 1] = bpsRemaining;

        uint256 poolId = nextPoolId++;

        vm.prank(activeUsers[0]); // Payer
        engine.processPoolDeposit(poolId, amount, users, bps);

        activePools.push(poolId);
        ghost_poolGrossDeposits[poolId] += amount;

        // Track absolute treasury inflow
        ghost_treasuryInflow += amount;

        uint256 riskFee = (amount * 1000) / 10000;
        ghost_poolNetDeposits[poolId] += (amount - riskFee);
        ghost_totalRiskFees += riskFee;

        // Track minted tokens safely
        uint256 startingToken = activeTokens.length + 1;
        for (uint256 i = 0; i < userCount; i++) {
            uint256 expectedTokenId = startingToken + i;
            // Explicitly assert existence instead of blindly assuming sequential logic holds
            require(
                impactToken.ownerOf(expectedTokenId) != address(0),
                "Handler: Ghost Token Assumption Failed"
            );
            activeTokens.push(expectedTokenId);
        }
    }

    function routeRevenue(uint256 poolSeed, uint256 amountSeed, uint8 flowSeed) external {
        if (activePools.length == 0) return;

        uint256 poolId = activePools[poolSeed % activePools.length];
        uint256 amount = bound(amountSeed, 100e6, 1_000_000e6);
        LAWPStructs.FlowType flow = LAWPStructs.FlowType(flowSeed % 3);

        multiSig.execute(poolId, amount, flow);

        if (flow == LAWPStructs.FlowType.RoC) {
            ghost_poolRocRouted[poolId] += amount;
        } else if (flow == LAWPStructs.FlowType.GRANT_INITIAL) {
            uint256 colSplit = (amount * 3000) / 10000; // 30% Collective
            ghost_poolYieldRouted[poolId] += colSplit;
            // The remaining 70% leaves the treasury immediately to operational wallets
            ghost_treasuryOutflow += (amount - colSplit);
        } else if (flow == LAWPStructs.FlowType.GRANT_CONTINUOUS) {
            uint256 colSplit = (amount * 1000) / 10000; // 10% Collective
            ghost_poolYieldRouted[poolId] += colSplit;
            // The remaining 90% leaves the treasury immediately to operational wallets
            ghost_treasuryOutflow += (amount - colSplit);
        }
    }

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

        // Track absolute treasury outflow to users
        ghost_treasuryOutflow += (newlyClaimedRoc + newlyClaimedYield);

        // =================================================================
        // INVARIANT F: CLAIM IDEMPOTENCY
        // =================================================================
        // Calling claim twice without new revenue must instantly evaluate to 0.
        uint256 claimableAfter = engine.calculateProportionalYield(tokenId);
        assertEq(claimableAfter, 0, "Invariant F: Idempotency Failed");
    }

    function transferToken(uint256 tokenSeed, uint256 receiverSeed) external {
        if (activeTokens.length == 0) return;
        uint256 tokenId = activeTokens[tokenSeed % activeTokens.length];
        address from = impactToken.ownerOf(tokenId);
        address to = activeUsers[receiverSeed % activeUsers.length];

        if (from == to) return;

        uint256 claimableBefore = engine.calculateProportionalYield(tokenId);
        LAWPStructs.TokenData memory dataBefore = impactToken.getTokenData(tokenId);
        uint256 yieldClaimedBefore = engine.yieldClaimed(tokenId);

        uint256 senderBalBefore = cngn.balanceOf(from);

        vm.prank(from);
        impactToken.transferFrom(from, to, tokenId);

        // Track global claims flushed forcefully during transfer
        LAWPStructs.TokenData memory dataAfter = impactToken.getTokenData(tokenId);
        uint256 yieldClaimedAfter = engine.yieldClaimed(tokenId);

        uint256 flushedRoc = dataAfter.rocReturned - dataBefore.rocReturned;
        uint256 flushedYield = yieldClaimedAfter - yieldClaimedBefore;

        ghost_totalClaimedRoc += flushedRoc;
        ghost_totalClaimedYield += flushedYield;

        // Track absolute treasury outflow triggered by the hook
        ghost_treasuryOutflow += (flushedRoc + flushedYield);

        // =================================================================
        // INVARIANT D: TRANSFER HOOK (DOUBLE SPEND PREVENTION)
        // =================================================================
        // D1 - Sender Correctness: Sender wallet must explicitly increase by flushed amount.
        assertEq(
            cngn.balanceOf(from),
            senderBalBefore + flushedYield + flushedRoc,
            "Invariant D1: Sender not compensated"
        );

        // D2 - Receiver Correctness: Receiver pending yield MUST be exactly 0.
        uint256 claimableAfter = engine.calculateProportionalYield(tokenId);
        assertEq(claimableAfter, 0, "Invariant D2: Receiver inherited false yield");

        // D3 - No Duplication: The total yield claimable globally across the transfer remains constant.
        assertEq(
            flushedYield + flushedRoc,
            claimableBefore,
            "Invariant D3: Yield duplicated during transfer"
        );
    }
}
