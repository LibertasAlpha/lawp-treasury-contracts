// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { LAWPOperationalVault } from "../../src/core/LAWPOperationalVault.sol";
import { MockCngn3, MockAdminOperations } from "../mocks/MockCngn3.sol";

/// @title LAWPOperationalVaultTest
/// @notice Unit tests for LAWPOperationalVault - protocol/payroll capital isolation layer.
/// @dev Mirrors YieldVaultTest structure but verifies OperationalVault-specific error selectors
///      and events ensuring the two vaults remain independently auditable.
contract LAWPOperationalVaultTest is Test {
    LAWPOperationalVault public vault;
    MockCngn3 public cngn;
    MockAdminOperations public adminOps;

    address public admin = address(1);
    address public engine = address(2);
    address public recipient = address(3);
    address public nobody = address(99);

    event ComplianceEngineUpdated(address indexed oldEngine, address indexed newEngine);
    event OperationalTransferExecuted(address indexed to, uint256 amount);

    function setUp() public {
        adminOps = new MockAdminOperations();
        cngn = new MockCngn3(address(adminOps));
        vault = new LAWPOperationalVault(address(cngn), admin);

        vm.prank(admin);
        vault.setComplianceEngine(engine);

        // Mock the engine's cNGNToken() to return our test cNGN.
        // The vault delegates to ILAWPComplianceEngine(complianceEngine).cNGNToken().
        vm.mockCall(engine, abi.encodeWithSignature("cNGNToken()"), abi.encode(address(cngn)));

        cngn.mintTest(address(vault), 1_000_000e6);
    }

    /*//////////////////////////////////////////////////////////////
                          CONSTRUCTOR TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Constructor_SetsOwner() public view {
        assertEq(vault.owner(), admin);
    }

    function test_Constructor_RevertIf_ZeroAdmin() public {
        vm.expectRevert();
        new LAWPOperationalVault(address(cngn), address(0));
    }

    /*//////////////////////////////////////////////////////////////
                     CNGN TOKEN DELEGATION
    //////////////////////////////////////////////////////////////*/

    function test_CNGNToken_DelegatesToEngine() public view {
        assertEq(address(vault.cNGNToken()), address(cngn));
    }

    /*//////////////////////////////////////////////////////////////
                      COMPLIANCE ENGINE LINKING
    //////////////////////////////////////////////////////////////*/

    function test_SetComplianceEngine_Success() public {
        LAWPOperationalVault freshVault = new LAWPOperationalVault(address(cngn), admin);
        vm.prank(admin);
        freshVault.setComplianceEngine(engine);
        assertEq(freshVault.complianceEngine(), engine);
    }

    function test_SetComplianceEngine_EmitsEvent() public {
        LAWPOperationalVault freshVault = new LAWPOperationalVault(address(cngn), admin);
        vm.prank(admin);
        vm.expectEmit(true, true, false, false);
        emit ComplianceEngineUpdated(address(0), engine);
        freshVault.setComplianceEngine(engine);
    }

    function test_SetComplianceEngine_RevertIf_ZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(LAWPOperationalVault.LAWPOperationalVault_InvalidAddress.selector);
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
        uint256 amount = 25_000e6;
        uint256 recipientBalBefore = cngn.balanceOf(recipient);

        vm.prank(engine);
        vault.executeTransfer(recipient, amount);

        assertEq(cngn.balanceOf(recipient), recipientBalBefore + amount);
    }

    function test_ExecuteTransfer_EmitsEvent() public {
        vm.prank(engine);
        vm.expectEmit(true, false, false, true);
        emit OperationalTransferExecuted(recipient, 500e6);
        vault.executeTransfer(recipient, 500e6);
    }

    function test_ExecuteTransfer_RevertIf_NotEngine() public {
        vm.prank(nobody);
        vm.expectRevert(LAWPOperationalVault.LAWPOperationalVault_UnauthorizedCaller.selector);
        vault.executeTransfer(recipient, 1_000e6);
    }

    function test_ExecuteTransfer_RevertIf_ZeroAddress() public {
        vm.prank(engine);
        vm.expectRevert(LAWPOperationalVault.LAWPOperationalVault_InvalidAddress.selector);
        vault.executeTransfer(address(0), 1_000e6);
    }

    function test_ExecuteTransfer_RevertIf_ZeroAmount() public {
        vm.prank(engine);
        vm.expectRevert(LAWPOperationalVault.LAWPOperationalVault_InvalidAmount.selector);
        vault.executeTransfer(recipient, 0);
    }

    function test_ExecuteTransfer_RevertIf_InsufficientBalance() public {
        vm.prank(engine);
        vm.expectRevert();
        vault.executeTransfer(recipient, 2_000_000e6);
    }

    /*//////////////////////////////////////////////////////////////
                     VAULT ISOLATION TEST
    //////////////////////////////////////////////////////////////*/

    /// @notice Validates that the two vaults are independent - funding one does not
    ///         affect the other's balance or access control.
    function test_VaultIsolation_IndependentEngines() public {
        LAWPOperationalVault vault2 = new LAWPOperationalVault(address(cngn), admin);
        address engine2 = address(77);
        vm.prank(admin);
        vault2.setComplianceEngine(engine2);

        // Mock engine2's cNGNToken() so vault2 can resolve the token
        vm.mockCall(engine2, abi.encodeWithSignature("cNGNToken()"), abi.encode(address(cngn)));

        // engine2 cannot withdraw from vault (different engine)
        cngn.mintTest(address(vault), 1000e6);
        vm.prank(engine2);
        vm.expectRevert(LAWPOperationalVault.LAWPOperationalVault_UnauthorizedCaller.selector);
        vault.executeTransfer(recipient, 1000e6);

        // engine cannot withdraw from vault2
        cngn.mintTest(address(vault2), 1000e6);
        vm.prank(engine);
        vm.expectRevert(LAWPOperationalVault.LAWPOperationalVault_UnauthorizedCaller.selector);
        vault2.executeTransfer(recipient, 1000e6);
    }

    /*//////////////////////////////////////////////////////////////
                      OWNERSHIP PROTECTION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_RenounceOwnership_IsDisabled() public {
        vm.prank(admin);
        vm.expectRevert("LAWPOperationalVault: renounceOwnership is disabled");
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
        vm.assume(amount <= 1_000_000e6);

        uint256 balBefore = cngn.balanceOf(recipient);
        vm.prank(engine);
        vault.executeTransfer(recipient, amount);
        assertEq(cngn.balanceOf(recipient), balBefore + amount);
    }
}
