// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { LAWPActorRegistry } from "../../src/core/LAWPActorRegistry.sol";

/// @title LAWPActorRegistryTest
/// @notice Unit tests for LAWPActorRegistry - the centralized operational wallet directory.
/// @dev Tests: ownership model, wallet updates, zero-address guards, event emissions,
///      two-step ownership transfer, and renounce lockout.
contract LAWPActorRegistryTest is Test {
    LAWPActorRegistry public registry;

    address public admin = address(1);
    address public la2 = address(10);
    address public mvi1 = address(11);
    address public operationalTreasury = address(12);
    address public dev = address(13);
    address public newAdmin = address(99);
    address public nobody = address(50);

    event ActorUpdated(string role, address indexed oldAddress, address indexed newAddress);

    function setUp() public {
        registry = new LAWPActorRegistry(admin);
    }

    /*//////////////////////////////////////////////////////////////
                          CONSTRUCTOR TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Constructor_SetsOwner() public view {
        assertEq(registry.owner(), admin);
    }

    function test_Constructor_WalletsInitiallyZero() public view {
        assertEq(registry.la2Wallet(), address(0));
        assertEq(registry.mvi1Wallet(), address(0));
        assertEq(registry.operationalTreasuryWallet(), address(0));
        assertEq(registry.devWallet(), address(0));
    }

    /*//////////////////////////////////////////////////////////////
                         WALLET SETTER TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SetLA2Wallet_Success() public {
        vm.prank(admin);
        registry.setLA2Wallet(la2);
        assertEq(registry.la2Wallet(), la2);
    }

    function test_SetMVI1Wallet_Success() public {
        vm.prank(admin);
        registry.setMVI1Wallet(mvi1);
        assertEq(registry.mvi1Wallet(), mvi1);
    }

    function test_SetOperationalTreasuryWallet_Success() public {
        vm.prank(admin);
        registry.setOperationalTreasuryWallet(operationalTreasury);
        assertEq(registry.operationalTreasuryWallet(), operationalTreasury);
    }

    function test_SetDevWallet_Success() public {
        vm.prank(admin);
        registry.setDevWallet(dev);
        assertEq(registry.devWallet(), dev);
    }

    /*//////////////////////////////////////////////////////////////
                       EVENT EMISSION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SetLA2Wallet_EmitsActorUpdated() public {
        vm.prank(admin);
        vm.expectEmit(false, true, true, true);
        emit ActorUpdated("LA2", address(0), la2);
        registry.setLA2Wallet(la2);
    }

    function test_SetMVI1Wallet_EmitsActorUpdated() public {
        vm.prank(admin);
        vm.expectEmit(false, true, true, true);
        emit ActorUpdated("MVI1", address(0), mvi1);
        registry.setMVI1Wallet(mvi1);
    }

    function test_SetOperationalTreasuryWallet_EmitsActorUpdated() public {
        vm.prank(admin);
        vm.expectEmit(false, true, true, true);
        emit ActorUpdated("OPERATIONAL_TREASURY", address(0), operationalTreasury);
        registry.setOperationalTreasuryWallet(operationalTreasury);
    }

    function test_SetDevWallet_EmitsActorUpdated() public {
        vm.prank(admin);
        vm.expectEmit(false, true, true, true);
        emit ActorUpdated("DEV", address(0), dev);
        registry.setDevWallet(dev);
    }

    function test_SetLA2Wallet_EmitsPreviousAddress() public {
        vm.startPrank(admin);
        registry.setLA2Wallet(la2);

        vm.expectEmit(false, true, true, true);
        emit ActorUpdated("LA2", la2, address(99));
        registry.setLA2Wallet(address(99));
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                      ZERO-ADDRESS GUARD TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SetLA2Wallet_RevertIf_ZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(LAWPActorRegistry.LAWPActorRegistry_ZeroAddress.selector);
        registry.setLA2Wallet(address(0));
    }

    function test_SetMVI1Wallet_RevertIf_ZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(LAWPActorRegistry.LAWPActorRegistry_ZeroAddress.selector);
        registry.setMVI1Wallet(address(0));
    }

    function test_SetOperationalTreasuryWallet_RevertIf_ZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(LAWPActorRegistry.LAWPActorRegistry_ZeroAddress.selector);
        registry.setOperationalTreasuryWallet(address(0));
    }

    function test_SetDevWallet_RevertIf_ZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(LAWPActorRegistry.LAWPActorRegistry_ZeroAddress.selector);
        registry.setDevWallet(address(0));
    }

    /*//////////////////////////////////////////////////////////////
                     AUTHORIZATION GUARD TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SetLA2Wallet_RevertIf_NotOwner() public {
        vm.prank(nobody);
        vm.expectRevert();
        registry.setLA2Wallet(la2);
    }

    function test_SetMVI1Wallet_RevertIf_NotOwner() public {
        vm.prank(nobody);
        vm.expectRevert();
        registry.setMVI1Wallet(mvi1);
    }

    function test_SetOperationalTreasuryWallet_RevertIf_NotOwner() public {
        vm.prank(nobody);
        vm.expectRevert();
        registry.setOperationalTreasuryWallet(operationalTreasury);
    }

    function test_SetDevWallet_RevertIf_NotOwner() public {
        vm.prank(nobody);
        vm.expectRevert();
        registry.setDevWallet(dev);
    }

    /*//////////////////////////////////////////////////////////////
                    OWNERSHIP PROTECTION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_RenounceOwnership_IsDisabled() public {
        vm.prank(admin);
        vm.expectRevert("LAWPActorRegistry: renounceOwnership is disabled");
        registry.renounceOwnership();
    }

    function test_TwoStepOwnershipTransfer_Success() public {
        // Step 1: propose
        vm.prank(admin);
        registry.transferOwnership(newAdmin);
        assertEq(registry.owner(), admin); // Not yet transferred
        assertEq(registry.pendingOwner(), newAdmin);

        // Step 2: accept
        vm.prank(newAdmin);
        registry.acceptOwnership();
        assertEq(registry.owner(), newAdmin);
        assertEq(registry.pendingOwner(), address(0));
    }

    function test_TwoStepOwnership_RevertIf_WrongAcceptor() public {
        vm.prank(admin);
        registry.transferOwnership(newAdmin);

        vm.prank(nobody);
        vm.expectRevert();
        registry.acceptOwnership();
    }

    /*//////////////////////////////////////////////////////////////
                         FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_SetAllWallets_Success(
        address _la2,
        address _mvi1,
        address _operationalTreasury,
        address _dev
    ) public {
        vm.assume(_la2 != address(0));
        vm.assume(_mvi1 != address(0));
        vm.assume(_operationalTreasury != address(0));
        vm.assume(_dev != address(0));

        vm.startPrank(admin);
        registry.setLA2Wallet(_la2);
        registry.setMVI1Wallet(_mvi1);
        registry.setOperationalTreasuryWallet(_operationalTreasury);
        registry.setDevWallet(_dev);
        vm.stopPrank();

        assertEq(registry.la2Wallet(), _la2);
        assertEq(registry.mvi1Wallet(), _mvi1);
        assertEq(registry.operationalTreasuryWallet(), _operationalTreasury);
        assertEq(registry.devWallet(), _dev);
    }
}
