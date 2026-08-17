// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {LAWPOperationalVault} from "../../src/core/LAWPOperationalVault.sol";
import {ILAWPOperationalVault} from "../../src/interfaces/ILAWPOperationalVault.sol";
import {MockCNGN} from "../mocks/MockCNGN.sol";

contract LAWPOperationalVaultTest is Test {
    LAWPOperationalVault public vault;
    MockCNGN public token;

    address public deployer = address(this);
    address public engine = address(0x123);
    address public hacker = address(0x666);
    address public receiver = address(0x999);

    event ComplianceEngineUpdated(address indexed engine);
    event OperationalTransferExecuted(address indexed to, uint256 amount);

    function setUp() public {
        token = new MockCNGN();
        vault = new LAWPOperationalVault(address(token));
        vault.setComplianceEngine(engine);
    }

    /*//////////////////////////////////////////////////////////////
                            INITIALIZATION & CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    function test_RevertIf_ConstructorZeroAddressToken() public {
        vm.expectRevert(LAWPOperationalVault.LAWPOperationalVault_InvalidAddress.selector);
        new LAWPOperationalVault(address(0));
    }

    function test_RevertIf_SetComplianceEngineZeroAddress() public {
        LAWPOperationalVault newVault = new LAWPOperationalVault(address(token));
        vm.expectRevert(LAWPOperationalVault.LAWPOperationalVault_InvalidAddress.selector);
        newVault.setComplianceEngine(address(0));
    }

    function test_RevertIf_AlreadyInitialized() public {
        vm.expectRevert(LAWPOperationalVault.LAWPOperationalVault_AlreadyInitialized.selector);
        vault.setComplianceEngine(address(0x456));
    }

    function test_SetComplianceEngine_Success() public {
        LAWPOperationalVault newVault = new LAWPOperationalVault(address(token));

        // Setting it should succeed
        newVault.setComplianceEngine(engine);

        assertEq(newVault.complianceEngine(), engine);
    }

    /*//////////////////////////////////////////////////////////////
                            AUTHORIZATION (HACKER TESTS)
    //////////////////////////////////////////////////////////////*/

    function test_RevertIf_UnauthorizedCallerExecuteTransfer() public {
        // Hacker tries to drain the vault
        vm.prank(hacker);
        vm.expectRevert(LAWPOperationalVault.LAWPOperationalVault_UnauthorizedCaller.selector);
        vault.executeTransfer(hacker, 1000e6);
    }

    function test_RevertIf_DeployerCallsExecuteTransfer() public {
        // Even the deployer/owner of the fixture cannot call it
        vm.prank(deployer);
        vm.expectRevert(LAWPOperationalVault.LAWPOperationalVault_UnauthorizedCaller.selector);
        vault.executeTransfer(receiver, 1000e6);
    }

    /*//////////////////////////////////////////////////////////////
                            VALIDATION & EXECUTION
    //////////////////////////////////////////////////////////////*/

    function test_RevertIf_ExecuteTransferZeroAddress() public {
        vm.prank(engine);
        vm.expectRevert(LAWPOperationalVault.LAWPOperationalVault_InvalidAddress.selector);
        vault.executeTransfer(address(0), 1000e6);
    }

    function test_RevertIf_ExecuteTransferZeroAmount() public {
        vm.prank(engine);
        vm.expectRevert(LAWPOperationalVault.LAWPOperationalVault_InvalidAmount.selector);
        vault.executeTransfer(receiver, 0);
    }

    function test_ExecuteTransfer_Success() public {
        // Fund the vault
        uint256 amount = 5000e6;
        token.mint(address(vault), amount);

        assertEq(token.balanceOf(address(vault)), amount);
        assertEq(token.balanceOf(receiver), 0);

        // Execute transfer as the engine
        vm.prank(engine);

        vm.expectEmit(true, true, true, true);
        emit OperationalTransferExecuted(receiver, amount);

        vault.executeTransfer(receiver, amount);

        // Verify balances
        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(token.balanceOf(receiver), amount);
    }

    // Test that if the underlying token transfer fails, the transaction reverts.
    // In our MockCNGN, it reverts automatically when balance is insufficient.
    function test_RevertIf_ExecuteTransferInsufficientBalance() public {
        // Vault is empty
        uint256 amount = 1000e6;

        vm.prank(engine);
        // Standard ERC20 revert from the token itself
        vm.expectRevert();
        vault.executeTransfer(receiver, amount);
    }
}
