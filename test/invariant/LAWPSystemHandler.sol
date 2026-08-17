// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {LAWPContributionPool} from "../../src/core/LAWPContributionPool.sol";
import {LAWPComplianceEngine} from "../../src/core/LAWPComplianceEngine.sol";
import {LAWPMultiSigController} from "../../src/core/LAWPMultiSigController.sol";
import {LAWPImpactToken} from "../../src/core/LAWPImpactToken.sol";
import {MockCNGN} from "../mocks/MockCNGN.sol";
import {LAWPStructs} from "../../src/libraries/LAWPStructs.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ILAWPContributionPool} from "../../src/interfaces/ILAWPContributionPool.sol";

contract LAWPSystemHandler is Test {
    MockCNGN public token;
    LAWPComplianceEngine public engine;
    LAWPContributionPool public pool;
    LAWPMultiSigController public multisig;
    LAWPImpactToken public impactToken;

    // Fixed actors to restrict search space but allow multi-actor interactions
    address[5] public users;
    address public manager;
    address public operator;

    // Track active pools and minted tokens
    uint256[] public activePools;
    uint256 public nextPoolId = 1;

    uint256[] public mintedTokens;
    uint256 public expectedNextTokenId = 1;

    // Ghost Accounting Model
    // Yield and RoC tracking
    uint256 public ghost_sumYieldRouted;
    uint256 public ghost_sumRoCRouted;
    uint256 public ghost_sumYieldClaimed;
    uint256 public ghost_sumRoCClaimed;

    // Operational tracking
    uint256 public ghost_sumOperationalRouted;

    // Total Principal
    mapping(uint256 => uint256) public ghost_poolPrincipal;

    // Dust Tracking
    uint256 public ghost_cumulativeDustYield;
    uint256 public ghost_cumulativeDustRoC;

    constructor(
        MockCNGN _token,
        LAWPComplianceEngine _engine,
        LAWPContributionPool _pool,
        LAWPMultiSigController _multisig,
        LAWPImpactToken _impactToken,
        address _manager,
        address _operator
    ) {
        token = _token;
        engine = _engine;
        pool = _pool;
        multisig = _multisig;
        impactToken = _impactToken;
        manager = _manager;
        operator = _operator;

        for (uint256 i = 0; i < 5; i++) {
            users[i] = address(uint160(0x1000 + i));
            // Mint huge supply to users so they can contribute endlessly
            token.mint(users[i], 1_000_000_000e6);
            vm.prank(users[i]);
            token.approve(address(pool), type(uint256).max);
        }

        // Mint huge supply to operator so they can route funds endlessly
        token.mint(operator, 1_000_000_000e6);
        vm.prank(operator);
        token.approve(address(engine), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                           CONTRIBUTION POOL
    //////////////////////////////////////////////////////////////*/

    function createPool(uint256 _goal, uint256 _window) public {
        _goal = bound(_goal, 1e6, 1_000_000e6); // 1 cNGN to 1M cNGN
        _window = bound(_window, 1 days, 30 days);

        vm.prank(manager);
        pool.createPool(nextPoolId, _goal, block.timestamp, block.timestamp + _window);
        activePools.push(nextPoolId);
        nextPoolId++;
    }

    function contribute(uint256 _poolIndex, uint256 _userIndex, uint256 _amount) public {
        if (activePools.length == 0) return;
        uint256 poolId = activePools[_poolIndex % activePools.length];
        address user = users[_userIndex % users.length];

        ILAWPContributionPool.PoolConfig memory p = pool.getPool(poolId);
        if (p.status != ILAWPContributionPool.PoolStatus.Open) return;
        if (block.timestamp >= p.endTime) return;

        // Protocol enforces minimum contribution
        _amount = bound(_amount, pool.MIN_CONTRIBUTION(), 1_000_000e6);

        vm.prank(user);
        pool.contribute(poolId, _amount);
    }

    function settlePool(uint256 _poolIndex) public {
        if (activePools.length == 0) return;
        uint256 poolId = activePools[_poolIndex % activePools.length];

        ILAWPContributionPool.PoolConfig memory p = pool.getPool(poolId);
        if (p.status != ILAWPContributionPool.PoolStatus.Open) return;

        bool goalMet = p.totalRaised >= p.goal;
        if (!goalMet) return; // Cannot settle unless goal is met

        // Capture token index before settlement
        uint256 startTokenId = expectedNextTokenId;
        uint256 newTokens = p.contributorCount;

        vm.prank(manager);
        pool.settle(poolId);

        // State update
        for (uint256 i = 0; i < newTokens; i++) {
            mintedTokens.push(startTokenId + i);
        }
        expectedNextTokenId += newTokens;

        // Ghost update
        ghost_poolPrincipal[poolId] = engine.poolTotalPrincipal(poolId);
        ghost_sumOperationalRouted += p.totalRaised; // ALL raised capital goes to OperationalVault
    }

    function cancelPool(uint256 _poolIndex) public {
        if (activePools.length == 0) return;
        uint256 poolId = activePools[_poolIndex % activePools.length];

        ILAWPContributionPool.PoolConfig memory p = pool.getPool(poolId);
        if (p.status != ILAWPContributionPool.PoolStatus.Open) return;
        if (p.totalRaised > 0) return;

        vm.prank(manager);
        pool.cancelPool(poolId);
    }

    /*//////////////////////////////////////////////////////////////
                           MULTISIG ROUTING
    //////////////////////////////////////////////////////////////*/

    function executeGrant(uint256 _poolIndex, uint256 _amount, uint8 _flowTypeInt) public {
        if (activePools.length == 0) return;
        uint256 poolId = activePools[_poolIndex % activePools.length];
        if (!engine.isPoolActive(poolId)) return;

        LAWPStructs.FlowType flowType = LAWPStructs.FlowType(_flowTypeInt % 3);
        _amount = bound(_amount, 1e6, 50_000e6); // Max 50k grant per run

        if (flowType == LAWPStructs.FlowType.RoC) {
            // Cap to prevent reverts (we're fuzzing valid executions)
            uint256 principal = ghost_poolPrincipal[poolId];
            uint256 rocTracker = engine.poolRocTracker(poolId);
            if (rocTracker >= principal) return;
            uint256 remainingRoc = principal - rocTracker;
            _amount = bound(_amount, 1e6, remainingRoc);
        }

        // Mock Multisig Operator Execution
        vm.startPrank(operator);
        token.approve(address(engine), _amount);
        vm.stopPrank();

        vm.prank(address(multisig)); // Mocking the multisig approval
        engine.routeOperationalAllocation(poolId, _amount, operator, flowType);

        // Update Ghost State
        if (flowType == LAWPStructs.FlowType.GRANT_INITIAL) {
            uint256 yieldPortion = (_amount * 3000) / 10000;
            uint256 opPortion = _amount - yieldPortion;
            ghost_sumOperationalRouted += opPortion;
            ghost_sumYieldRouted += yieldPortion;
            ghost_cumulativeDustYield += expectedNextTokenId; // Max dust bound
        } else if (flowType == LAWPStructs.FlowType.GRANT_CONTINUOUS) {
            uint256 yieldPortion = _amount / 10;
            uint256 opPortion = _amount - yieldPortion;
            ghost_sumOperationalRouted += opPortion;
            ghost_sumYieldRouted += yieldPortion;
            ghost_cumulativeDustYield += expectedNextTokenId; // Max dust bound
        } else if (flowType == LAWPStructs.FlowType.RoC) {
            ghost_sumRoCRouted += _amount;
            ghost_cumulativeDustRoC += expectedNextTokenId; // Max dust bound
        }
    }

    /*//////////////////////////////////////////////////////////////
                           YIELD CLAIMING & TRANSFERS
    //////////////////////////////////////////////////////////////*/

    function claimYield(uint256 _tokenIndex) public {
        if (mintedTokens.length == 0) return;
        uint256 tokenId = mintedTokens[_tokenIndex % mintedTokens.length];

        address owner = impactToken.ownerOf(tokenId);

        // Capture state before
        uint256 claimedYieldBefore = engine.yieldClaimed(tokenId);
        uint256 claimedRocBefore = impactToken.getTokenData(tokenId).rocReturned;

        vm.prank(owner);
        try engine.claimYield(tokenId) {
            uint256 claimedYieldAfter = engine.yieldClaimed(tokenId);
            uint256 claimedRocAfter = impactToken.getTokenData(tokenId).rocReturned;

            ghost_sumYieldClaimed += (claimedYieldAfter - claimedYieldBefore);
            ghost_sumRoCClaimed += (claimedRocAfter - claimedRocBefore);
        } catch {}
    }

    function transferNFT(uint256 _tokenIndex, uint256 _toIndex) public {
        if (mintedTokens.length == 0) return;
        uint256 tokenId = mintedTokens[_tokenIndex % mintedTokens.length];

        address from = impactToken.ownerOf(tokenId);
        address to = users[_toIndex % users.length];
        if (from == to) return;

        // Capture state before
        uint256 claimedYieldBefore = engine.yieldClaimed(tokenId);
        uint256 claimedRocBefore = impactToken.getTokenData(tokenId).rocReturned;

        vm.prank(from);
        try impactToken.transferFrom(from, to, tokenId) {
            uint256 claimedYieldAfter = engine.yieldClaimed(tokenId);
            uint256 claimedRocAfter = impactToken.getTokenData(tokenId).rocReturned;

            ghost_sumYieldClaimed += (claimedYieldAfter - claimedYieldBefore);
            ghost_sumRoCClaimed += (claimedRocAfter - claimedRocBefore);
        } catch {}
    }

    function warpTime(uint256 _seconds) public {
        _seconds = bound(_seconds, 1, 365 days);
        vm.warp(block.timestamp + _seconds);
    }
}
