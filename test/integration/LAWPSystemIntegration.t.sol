// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {LAWPFixture} from "../base/LAWPFixture.t.sol";
import {LAWPStructs} from "../../src/libraries/LAWPStructs.sol";
import {LAWPMultiSigController} from "../../src/core/LAWPMultiSigController.sol";
import {LAWPComplianceEngine} from "../../src/core/LAWPComplianceEngine.sol";
import {LAWPContributionPool} from "../../src/core/LAWPContributionPool.sol";

contract LAWPSystemIntegrationTest is LAWPFixture {
    struct Signer {
        uint256 privateKey;
        address addr;
    }

    Signer[] public board;

    uint256 public constant POOL_ID = 1;
    uint256 public constant POOL_GOAL = 1000e6;
    uint256 public constant RISK_FEE_BPS = 500; // 5%

    // To prevent stack-too-deep in integration tests, cache initial balances
    uint256 initialAliceBalance;
    uint256 initialBobBalance;

    function setUp() public override {
        super.setUp();

        // 1. Engine setup parameters
        vm.startPrank(governance);
        engine.updateRiskFee(RISK_FEE_BPS);
        vm.stopPrank();

        // 2. Fund users
        token.mint(alice, 10000e6);
        token.mint(bob, 10000e6);

        initialAliceBalance = token.balanceOf(alice);
        initialBobBalance = token.balanceOf(bob);

        // 3. Setup Multisig Board and Pool/Multisig Roles
        vm.startPrank(governance);
        engine.grantRole(engine.CAMPAIGN_MANAGER_ROLE(), address(pool));
        engine.grantRole(engine.OPERATOR_ROLE(), address(multisig));
        for (uint256 i = 1; i <= 5; i++) {
            uint256 pk = 0x1000 + i;
            address addr = vm.addr(pk);
            board.push(Signer({privateKey: pk, addr: addr}));
            engine.grantRole(multisig.SIGNER_ROLE(), addr);
        }
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                     FLOW 1: E2E POOL SETTLEMENT
    //////////////////////////////////////////////////////////////*/

    function test_Integration_E2E_PoolLifecycle_Success() public {
        // 1. Create Pool
        uint256 duration = 7 days;
        vm.prank(campaignManager);
        uint256 newPoolId = pool.createPool(POOL_ID, POOL_GOAL, block.timestamp, block.timestamp + duration);
        assertEq(newPoolId, POOL_ID);

        // 2. Alice contributes 60%
        vm.startPrank(alice);
        token.approve(address(pool), 600e6);
        pool.contribute(POOL_ID, 600e6);
        vm.stopPrank();

        // 3. Bob contributes 40%
        vm.startPrank(bob);
        token.approve(address(pool), 400e6);
        pool.contribute(POOL_ID, 400e6);
        vm.stopPrank();

        assertEq(token.balanceOf(address(pool)), POOL_GOAL);

        // 4. Settle Pool
        vm.warp(block.timestamp + duration + 1);
        vm.prank(campaignManager);
        pool.settle(POOL_ID);

        // Follow the Money
        // Total Goal = 1000e6
        // Operational Vault funded fully (1000e6)
        // Internal balance tracked for opTreasury (operator) = 1000e6

        assertEq(token.balanceOf(address(pool)), 0); // Pool empty
        assertEq(token.balanceOf(la2Wallet), 0); // Fee not directly pushed to la2Wallet
        assertEq(token.balanceOf(address(opVault)), 1000e6); // Operational Vault funded
        assertEq(engine.operationalBalances(opTreasuryWallet), 1000e6); // tracked for opTreasuryWallet

        // 6. Verify Equity (Impact Tokens)
        // Alice should have Token 1 (60% WAD = 0.6e18)
        assertEq(impactToken.ownerOf(1), alice);
        LAWPStructs.TokenData memory token1 = impactToken.getTokenData(1);
        assertEq(token1.poolShareWAD, 0.6e18);
        assertEq(token1.netPrincipal, 570e6); // 950e6 * 0.6

        // Bob should have Token 2 (40% WAD = 0.4e18)
        assertEq(impactToken.ownerOf(2), bob);
        LAWPStructs.TokenData memory token2 = impactToken.getTokenData(2);
        assertEq(token2.poolShareWAD, 0.4e18);
        assertEq(token2.netPrincipal, 380e6); // 950e6 * 0.4

        // Exact WAD check
        assertEq(token1.poolShareWAD + token2.poolShareWAD, impactToken.TOTAL_SHARES());
    }

    /*//////////////////////////////////////////////////////////////
                   FLOW 2: MULTISIG E2E EXECUTION
    //////////////////////////////////////////////////////////////*/

    function _executeMultisigProposal(uint256 proposalId, uint256 amount, LAWPStructs.FlowType flow) internal {
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = multisig.getProposalDigest(proposalId, POOL_ID, amount, flow, deadline);

        // Generate Signatures
        Signer[] memory selected = new Signer[](2);
        selected[0] = board[0];
        selected[1] = board[1];
        _sortSignersAscending(selected);

        bytes memory sigs = _generateSignatures(digest, selected);

        vm.startPrank(operator); // Operator triggers the multisig execution
        multisig.executeProposal(proposalId, POOL_ID, amount, flow, deadline, sigs);
        vm.stopPrank();
    }

    function test_Integration_MultiSig_GrantExecution() public {
        test_Integration_E2E_PoolLifecycle_Success(); // Sets up a settled pool with 950e6 in OpVault

        // Operator wallet is the target for operational allocations, grant initials, grant continuous
        token.mint(operator, 150e6);
        vm.startPrank(operator);
        token.approve(address(engine), 150e6);
        vm.stopPrank();

        uint256 initialOpBalance = token.balanceOf(operator);
        uint256 opVaultBalanceBefore = token.balanceOf(address(opVault));

        // 1. Grant Initial (100e6)
        // 30% -> YieldVault (30e6)
        // 70% -> OpVault (70e6, split into 50% LA2, 20% MVI)
        _executeMultisigProposal(1, 100e6, LAWPStructs.FlowType.GRANT_INITIAL);
        assertEq(token.balanceOf(operator), initialOpBalance - 100e6);
        assertEq(token.balanceOf(address(opVault)), opVaultBalanceBefore + 70e6);
        assertEq(token.balanceOf(address(yieldVault)), 30e6);

        // 2. Grant Continuous (50e6)
        // 10% -> YieldVault (5e6)
        // 90% -> OpVault (45e6, split into 55% LA2, 25% MVI, 10% DEV)
        _executeMultisigProposal(2, 50e6, LAWPStructs.FlowType.GRANT_CONTINUOUS);
        assertEq(token.balanceOf(operator), initialOpBalance - 150e6);
        assertEq(token.balanceOf(address(opVault)), opVaultBalanceBefore + 70e6 + 45e6);
        assertEq(token.balanceOf(address(yieldVault)), 30e6 + 5e6);

        // 3. Replay Attack (Should fail!)
        // Create the exact same parameters to get the same digest
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = multisig.getProposalDigest(2, POOL_ID, 50e6, LAWPStructs.FlowType.GRANT_CONTINUOUS, deadline);
        Signer[] memory selected = new Signer[](2);
        selected[0] = board[0];
        selected[1] = board[1];
        _sortSignersAscending(selected);
        bytes memory sigs = _generateSignatures(digest, selected);

        vm.prank(operator);
        vm.expectRevert(LAWPMultiSigController.LAWPMultiSigController_ProposalAlreadyExecuted.selector);
        multisig.executeProposal(2, POOL_ID, 50e6, LAWPStructs.FlowType.GRANT_CONTINUOUS, deadline, sigs);
    }

    /*//////////////////////////////////////////////////////////////
                   FLOW 3: RETURN OF CAPITAL & YIELD
    //////////////////////////////////////////////////////////////*/

    function test_Integration_Yield_And_RoC_Lifecycle() public {
        // Sets up settled pool
        test_Integration_E2E_PoolLifecycle_Success();

        // 950e6 total principal. Let's assume project yields 300e6 in RoC, 100e6 in Yield.

        // First we must fund the operator to send RoC/Yield back to the engine
        token.mint(operator, 400e6);

        vm.startPrank(operator);
        token.approve(address(engine), 400e6);
        vm.stopPrank();

        // 1. Route RoC via Multisig (300e6)
        // RoC goes 100% to Yield Vault
        _executeMultisigProposal(3, 300e6, LAWPStructs.FlowType.RoC);

        // Follow the Money: Engine routes RoC to Yield Vault
        assertEq(token.balanceOf(address(yieldVault)), 300e6); // just the 300e6 RoC

        // 2. Claiming RoC
        // Alice has 60% (Token 1), Bob has 40% (Token 2).
        // 300e6 RoC -> Alice gets 180e6, Bob gets 120e6.

        uint256 aliceBalBefore = token.balanceOf(alice);
        vm.prank(alice);
        engine.claimYield(1);

        // Alice gets 60% of RoC (300e6 * 0.6 = 180e6). There is no Yield yet.
        // Total = 180e6
        assertEq(token.balanceOf(alice), aliceBalBefore + 180e6);

        // 3. Distribute Pure Yield (100e6 Yield means 1000e6 Continuous Grant since Yield gets 10%)
        token.mint(operator, 1000e6);
        vm.startPrank(operator);
        token.approve(address(engine), 1000e6);
        vm.stopPrank();
        _executeMultisigProposal(4, 1000e6, LAWPStructs.FlowType.GRANT_CONTINUOUS);
        // Yield is WAD distributed. Alice has 60%.
        // Alice's share of 100e6 = 60e6.

        aliceBalBefore = token.balanceOf(alice);
        vm.prank(alice);
        engine.claimYield(1); // Call the dedicated function

        assertEq(token.balanceOf(alice), aliceBalBefore + 60e6);

        // Bob claims his batch (RoC + Yield)
        uint256 bobBalBefore = token.balanceOf(bob);

        uint256[] memory tokens = new uint256[](1);
        tokens[0] = 2;

        vm.prank(bob);
        engine.claimYieldBatch(tokens);

        // Bob gets 40% of previous RoC (300e6 * 0.4 = 120e6)
        // + 40% of new Yield (100e6 * 0.4 = 40e6)
        // Total = 160e6
        assertEq(token.balanceOf(bob), bobBalBefore + 160e6);

        // Bob tries to claim manually again, should revert
        vm.prank(bob);
        vm.expectRevert(LAWPComplianceEngine.LAWPComplianceEngine_NothingToClaim.selector);
        engine.claimYield(2);
    }

    /*//////////////////////////////////////////////////////////////
              FLOW 4: SECONDARY MARKET YIELD INTERCEPTION
    //////////////////////////////////////////////////////////////*/

    function test_Integration_SecondaryMarket_Intercept() public {
        // Setup Pool
        test_Integration_E2E_PoolLifecycle_Success();

        // Send 10e6 Yield into the yield vault via Continuous Grant (100e6 total)
        token.mint(operator, 100e6);
        vm.startPrank(operator);
        token.approve(address(engine), 100e6);
        vm.stopPrank();
        _executeMultisigProposal(5, 100e6, LAWPStructs.FlowType.GRANT_CONTINUOUS);

        // Alice (Token 1) has 60% = 6e6 Yield waiting for her.
        // Instead of claiming it, she transfers the NFT to Carol on the secondary market.
        address carol = makeAddr("carol");
        uint256 aliceBalBefore = token.balanceOf(alice);

        vm.prank(alice);
        impactToken.transferFrom(alice, carol, 1);

        assertEq(token.balanceOf(alice), aliceBalBefore + 6e6); // Hook flushed her yield!

        // The NFT now belongs to Carol.
        assertEq(impactToken.ownerOf(1), carol);

        // Carol tries to claim yield immediately after buying.
        // Since Alice was already flushed, Carol's claim should be 0.
        uint256 carolBalBefore = token.balanceOf(carol);

        vm.startPrank(carol);
        vm.expectRevert(LAWPComplianceEngine.LAWPComplianceEngine_NothingToClaim.selector);
        engine.claimYield(1);
        vm.stopPrank();

        assertEq(token.balanceOf(carol), carolBalBefore);
    }

    /*//////////////////////////////////////////////////////////////
                   ADVERSARIAL & MULTI-STEP ATTACKS
    //////////////////////////////////////////////////////////////*/

    function test_Integration_Attack_DoubleSettle() public {
        uint256 duration = 7 days;
        vm.prank(campaignManager);
        pool.createPool(POOL_ID, POOL_GOAL, block.timestamp, block.timestamp + duration);

        vm.startPrank(alice);
        token.approve(address(pool), POOL_GOAL);
        pool.contribute(POOL_ID, POOL_GOAL);
        vm.stopPrank();

        vm.warp(block.timestamp + duration + 1);

        vm.prank(campaignManager);
        pool.settle(POOL_ID);

        // Attack: Double settle
        vm.prank(campaignManager);
        vm.expectRevert(LAWPContributionPool.LAWPContributionPool__AlreadySettled.selector);
        pool.settle(POOL_ID);
    }

    function test_Integration_Attack_RoC_ExceedsCap() public {
        test_Integration_E2E_PoolLifecycle_Success();

        // Add funds to operator so it can attempt a massive RoC
        token.mint(operator, 1000e6);
        vm.startPrank(operator);
        token.approve(address(engine), 1000e6);
        vm.stopPrank();

        // The engine tracks net capital as 950e6 for this pool.
        // An attacker/board attempts to route 1000e6 in RoC, which is > 950e6.
        uint256 deadline = block.timestamp + 1 hours;
        // Nonce 4 since previous test flows might have used up to 3
        bytes32 digest = multisig.getProposalDigest(4, POOL_ID, 1000e6, LAWPStructs.FlowType.RoC, deadline);

        Signer[] memory selected = new Signer[](2);
        selected[0] = board[0];
        selected[1] = board[1];
        _sortSignersAscending(selected);

        bytes memory sigs = _generateSignatures(digest, selected);

        vm.prank(operator);
        vm.expectRevert(LAWPComplianceEngine.LAWPComplianceEngine_ExceedsPrincipalCap.selector);
        multisig.executeProposal(4, POOL_ID, 1000e6, LAWPStructs.FlowType.RoC, deadline, sigs);
    }

    function test_Integration_Attack_YieldStealByTransfer() public {
        test_Integration_E2E_PoolLifecycle_Success();

        // Yield arrives via Continuous Grant (100e6 yield means 1000e6 grant)
        token.mint(operator, 1000e6);
        vm.startPrank(operator);
        token.approve(address(engine), 1000e6);
        vm.stopPrank();
        _executeMultisigProposal(6, 1000e6, LAWPStructs.FlowType.GRANT_CONTINUOUS);

        // Bob notices yield has arrived. He quickly transfers his token to his alt wallet
        // hoping to double-claim or bypass the hook.

        address carol = makeAddr("carol");
        uint256 bobBalBefore = token.balanceOf(bob);

        vm.prank(bob);
        impactToken.transferFrom(bob, carol, 2);

        // The hook intercepted and gave Bob his 40e6.
        assertEq(token.balanceOf(bob), bobBalBefore + 40e6);

        // Alt wallet (Carol) tries to claim Yield
        vm.startPrank(carol);
        vm.expectRevert(LAWPComplianceEngine.LAWPComplianceEngine_NothingToClaim.selector);
        engine.claimYield(2);

        // Alt wallet tries to claim RoC. There is no RoC.
        vm.expectRevert(LAWPComplianceEngine.LAWPComplianceEngine_NothingToClaim.selector);
        engine.claimYield(2);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                            HELPERS
    //////////////////////////////////////////////////////////////*/

    function _generateSignatures(bytes32 digest, Signer[] memory signers) internal pure returns (bytes memory) {
        bytes memory sigs = new bytes(signers.length * 65);
        for (uint256 i = 0; i < signers.length; i++) {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(signers[i].privateKey, digest);

            // Encode r, s, v into the `sigs` byte array
            uint256 offset = i * 65;

            assembly {
                let sigData := add(sigs, add(32, offset))
                mstore(sigData, r)
                mstore(add(sigData, 32), s)
            }
            // Add v at the 64th byte offset
            sigs[offset + 64] = bytes1(v);
        }
        return sigs;
    }

    function _sortSignersAscending(Signer[] memory arr) internal pure {
        uint256 l = arr.length;
        for (uint256 i = 0; i < l; i++) {
            for (uint256 j = i + 1; j < l; j++) {
                if (uint160(arr[i].addr) > uint160(arr[j].addr)) {
                    Signer memory temp = arr[i];
                    arr[i] = arr[j];
                    arr[j] = temp;
                }
            }
        }
    }
}
