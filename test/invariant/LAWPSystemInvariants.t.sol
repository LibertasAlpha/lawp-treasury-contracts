// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {LAWPSystemHandler} from "./LAWPSystemHandler.sol";
import {LAWPFixture} from "../base/LAWPFixture.t.sol";

contract LAWPSystemInvariantsTest is LAWPFixture {
    LAWPSystemHandler public handler;

    function setUp() public override {
        super.setUp();
        handler = new LAWPSystemHandler(token, engine, pool, multisig, impactToken, campaignManager, operator);
        targetContract(address(handler));
    }

    /// @notice YieldVault Conservation:
    /// Tracks max dust and asserts exact bounded equality.
    function invariant_YieldVault_Precision_Conservation() public view {
        uint256 expectedYield = handler.ghost_sumYieldRouted() - handler.ghost_sumYieldClaimed();
        uint256 expectedRoC = handler.ghost_sumRoCRouted() - handler.ghost_sumRoCClaimed();
        uint256 expectedBalance = expectedYield + expectedRoC;

        uint256 actualBalance = token.balanceOf(address(yieldVault));
        uint256 maxDust = handler.ghost_cumulativeDustYield() + handler.ghost_cumulativeDustRoC();

        assertGe(actualBalance, expectedBalance, "YieldVault underfunded");
        assertLe(actualBalance - expectedBalance, maxDust, "YieldVault dust bound breached");
    }

    /// @notice OperationalVault Conservation
    function invariant_OperationalVault_Precision_Conservation() public view {
        uint256 expectedBalance = handler.ghost_sumOperationalRouted();
        uint256 actualBalance = token.balanceOf(address(opVault));
        assertEq(actualBalance, expectedBalance, "OpVault mismatch");
    }

    /// @notice RoC Global Integrity
    function invariant_RoC_Global_Integrity() public view {
        assertGe(handler.ghost_sumRoCRouted(), handler.ghost_sumRoCClaimed(), "RoC over-drained");
    }
}
