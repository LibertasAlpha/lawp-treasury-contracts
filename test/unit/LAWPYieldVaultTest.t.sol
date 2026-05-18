// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { LAWPYieldVault } from "../../src/core/LAWPYieldVault.sol";
import { MockCngn3, MockAdminOperations } from "../mocks/MockCngn3.sol";

/// @title LAWPYieldVaultTest
/// @notice Unit tests for LAWPYieldVault — investor capital isolation layer.
/// @dev Tests: constructor guards, compliance engine linking, executeTransfer authorization,
///      zero-address guards, amount guards, reentrancy resistance, and ownership protection.
contract LAWPYieldVaultTest is Test {
    LAWPYieldVault public vault;
    MockCngn3 public cngn;
    MockAdminOperations public adminOps;

    address public admin = address(1);
    address public engine = address(2); // Authorized compliance engine
    address public recipient = address(3);
    address public nobody = address(99);

    event ComplianceEngineUpdated(address indexed oldEngine, address indexed newEngine);
    event YieldTransferExecuted(address indexed to, uint256 amount);

    function setUp() public {
        adminOps = new MockAdminOperations();
        cngn = new MockCngn3(address(adminOps));
        vault = new LAWPYieldVault(address(cngn), admin);

        vm.prank(admin);
        vault.setComplianceEngine(engine);

        // Fund the vault with tokens for transfer tests
        cngn.mintTest(address(vault), 1_000_000e6);
    }

    /*//////////////////////////////////////////////////////////////
                          CONSTRUCTOR TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Constructor_SetsTokenAndOwner() public view {
        assertEq(address(vault.cngnToken()), address(cngn));
        assertEq(vault.owner(), admin);
    }

    function test_Constructor_RevertIf_ZeroCngn() public {
        vm.expectRevert(LAWPYieldVault.LAWPYieldVault_InvalidAddress.selector);
        new LAWPYieldVault(address(0), admin);
    }

    function test_Constructor_RevertIf_ZeroAdmin() public {
        vm.expectRevert(LAWPYieldVault.LAWPYieldVault_InvalidAddress.selector);
        new LAWPYieldVault(address(cngn), address(0));
    }

    /*//////////////////////////////////////////////////////////////
                      COMPLIANCE ENGINE LINKING
    //////////////////////////////////////////////////////////////*/

    function test_SetComplianceEngine_Success() public {
        LAWPYieldVault freshVault = new LAWPYieldVault(address(cngn), admin);
        vm.prank(admin);
        freshVault.setComplianceEngine(engine);
        assertEq(freshVault.complianceEngine(), engine);
    }

    function test_SetComplianceEngine_EmitsEvent() public {
        LAWPYieldVault freshVault = new LAWPYieldVault(address(cngn), admin);
        vm.prank(admin);
        vm.expectEmit(true, true, false, false);
        emit ComplianceEngineUpdated(address(0), engine);
        freshVault.setComplianceEngine(engine);
    }

    function test_SetComplianceEngine_EmitsPreviousAddress() public {
        address newEngine = address(77);
        vm.prank(admin);
        vm.expectEmit(true, true, false, false);
        emit ComplianceEngineUpdated(engine, newEngine);
        vault.setComplianceEngine(newEngine);
    }

    function test_SetComplianceEngine_RevertIf_ZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(LAWPYieldVault.LAWPYieldVault_InvalidAddress.selector);
        vault.setComplianceEngine(address(0));
    }

    function test_SetComplianceEngine_RevertIf_NotOwner() public {
        vm.prank(nobody);
        vm.expectRevert();
        vault.setComplianceEngine(engine);
    }

    /*//////////////////////////////////////////////////////////////
                       EXECUTE TRANSFER TESTS
    //////////////////////////////////////////////////////////////*/

    function test_ExecuteTransfer_Success() public {
        uint256 amount = 50_000e6;
        uint256 recipientBalBefore = cngn.balanceOf(recipient);

        vm.prank(engine);
        vault.executeTransfer(recipient, amount);

        assertEq(cngn.balanceOf(recipient), recipientBalBefore + amount);
        assertEq(cngn.balanceOf(address(vault)), 1_000_000e6 - amount);
    }

    function test_ExecuteTransfer_EmitsEvent() public {
        vm.prank(engine);
        vm.expectEmit(true, false, false, true);
        emit YieldTransferExecuted(recipient, 1_000e6);
        vault.executeTransfer(recipient, 1_000e6);
    }

    function test_ExecuteTransfer_RevertIf_NotEngine() public {
        vm.prank(nobody);
        vm.expectRevert(LAWPYieldVault.LAWPYieldVault_UnauthorizedCaller.selector);
        vault.executeTransfer(recipient, 1_000e6);
    }

    function test_ExecuteTransfer_RevertIf_ZeroAddress() public {
        vm.prank(engine);
        vm.expectRevert(LAWPYieldVault.LAWPYieldVault_InvalidAddress.selector);
        vault.executeTransfer(address(0), 1_000e6);
    }

    function test_ExecuteTransfer_RevertIf_ZeroAmount() public {
        vm.prank(engine);
        vm.expectRevert(LAWPYieldVault.LAWPYieldVault_InvalidAmount.selector);
        vault.executeTransfer(recipient, 0);
    }

    function test_ExecuteTransfer_RevertIf_InsufficientBalance() public {
        uint256 excessiveAmount = 2_000_000e6; // More than vault holds
        vm.prank(engine);
        vm.expectRevert(); // SafeERC20 / ERC20 insufficient balance
        vault.executeTransfer(recipient, excessiveAmount);
    }

    function test_ExecuteTransfer_RevertIf_AdminCallsDirectly() public {
        // Admin is NOT the compliance engine — must revert
        vm.prank(admin);
        vm.expectRevert(LAWPYieldVault.LAWPYieldVault_UnauthorizedCaller.selector);
        vault.executeTransfer(recipient, 1_000e6);
    }

    /*//////////////////////////////////////////////////////////////
                      OWNERSHIP PROTECTION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_RenounceOwnership_IsDisabled() public {
        vm.prank(admin);
        vm.expectRevert("LAWPYieldVault: renounceOwnership is disabled");
        vault.renounceOwnership();
    }

    function test_TwoStepOwnershipTransfer_Success() public {
        address newAdmin = address(88);
        vm.prank(admin);
        vault.transferOwnership(newAdmin);
        assertEq(vault.owner(), admin);

        vm.prank(newAdmin);
        vault.acceptOwnership();
        assertEq(vault.owner(), newAdmin);
    }

    /*//////////////////////////////////////////////////////////////
                          FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_ExecuteTransfer_ArbitraryAmounts(uint256 amount) public {
        vm.assume(amount > 0);
        vm.assume(amount <= 1_000_000e6); // Within vault balance

        uint256 balBefore = cngn.balanceOf(recipient);
        vm.prank(engine);
        vault.executeTransfer(recipient, amount);

        assertEq(cngn.balanceOf(recipient), balBefore + amount);
    }
}
