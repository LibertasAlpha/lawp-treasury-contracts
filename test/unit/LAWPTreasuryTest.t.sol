// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { LAWPTreasury } from "../../src/core/LAWPTreasury.sol";
import { LAWPErrors } from "../../src/libraries/LAWPErrors.sol";
import { MockCngn3, MockAdminOperations } from "../mocks/MockCngn3.sol";

contract LAWPTreasuryTest is Test, LAWPErrors {
    LAWPTreasury public treasury;
    MockCngn3 public cngn;
    MockAdminOperations public adminOps;

    address public admin = address(1);
    address public engine = address(2);
    address public riskPool = address(3);
    address public user = address(4);

    function setUp() public {
        adminOps = new MockAdminOperations();
        cngn = new MockCngn3(address(adminOps));
        treasury = new LAWPTreasury(address(cngn), admin);

        vm.startPrank(admin);
        treasury.setComplianceEngine(engine);
        treasury.setRiskPoolWallet(riskPool);
        vm.stopPrank();
    }

    function test_DepositPullsFunds() public {
        uint256 amount = 50000e6; // Using 6 decimals

        // As owner of the MockCngn3 contract, we can safely seed funds via mintTest
        cngn.mintTest(user, amount);

        vm.startPrank(user);
        cngn.approve(address(treasury), amount);
        treasury.deposit(amount);
        vm.stopPrank();

        assertEq(treasury.getVaultBalance(), amount);
    }

    function test_ExecuteTransfer_OnlyComplianceEngine() public {
        cngn.mintTest(address(treasury), 1000e6); // Fund vault

        vm.prank(engine);
        treasury.executeTransfer(user, 500e6);
        assertEq(cngn.balanceOf(user), 500e6);
        assertEq(cngn.balanceOf(address(treasury)), 500e6);
    }

    function test_RouteRiskFee_OnlyComplianceEngine() public {
        cngn.mintTest(address(treasury), 1000e6); // Fund vault

        vm.prank(engine);
        treasury.routeRiskFee(100e6);
        assertEq(cngn.balanceOf(riskPool), 100e6);
        assertEq(cngn.balanceOf(address(treasury)), 900e6);
    }

    function test_RevertIf_UnauthorizedTransfer() public {
        cngn.mintTest(address(treasury), 1000e6);

        vm.prank(user);
        vm.expectRevert(LAWPTreasury_UnauthorizedCommand.selector);
        treasury.executeTransfer(user, 500e6);
    }

    function test_RevertIf_InsufficientVaultFunds() public {
        vm.prank(engine);
        vm.expectRevert(LAWPTreasury_InsufficientVaultFunds.selector);
        treasury.executeTransfer(user, 500e6);
    }

    function test_RevertIf_RenounceOwnership() public {
        vm.prank(admin);
        vm.expectRevert("LAWPTreasury: renounceOwnership is disabled");
        treasury.renounceOwnership();
    }

    function test_TwoStepOwnershipTransfer() public {
        address newAdmin = address(5);

        // Step 1: Admin proposes new owner
        vm.prank(admin);
        treasury.transferOwnership(newAdmin);

        // Ownership shouldn't change yet
        assertEq(treasury.owner(), admin);

        // Step 2: New owner accepts
        vm.prank(newAdmin);
        treasury.acceptOwnership();

        // Ownership is officially transferred
        assertEq(treasury.owner(), newAdmin);
    }
}
