// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { LAWPActorRegistry } from "../../src/core/LAWPActorRegistry.sol";

/*
 * ============================================================================
 * @dev NOTE FOR PHASE 6 DEPLOYMENT (Invariant Testing)
 * ============================================================================
 * Finding: Incomplete Privilege Revocation During Deployment
 * Severity: Medium
 * * Description:
 * The constructor pattern atomically sets the Timelock as `owner` of governed
 * contracts. However, the Timelock itself is deployed with the deployer EOA
 * as `DEFAULT_ADMIN_ROLE`. Unless explicit revocation occurs, the deployer
 * retains ultimate control over the Timelock's role management.
 * * Recommendation:
 * The deployment script MUST include, in a single atomic transaction:
 * 1. Deploy Timelock
 * 2. Deploy governed contracts with Timelock as `initialAdmin`
 * 3. Call `timelock.renounceRole(DEFAULT_ADMIN_ROLE, deployer)`
 * * Validation:
 * Add invariant test confirming `timelock.getRoleMemberCount(DEFAULT_ADMIN_ROLE) == 0`
 * after Phase 6 completion.
 * ============================================================================
 */

contract LAWPActorRegistryTest is Test {
    LAWPActorRegistry public registry;
    address public admin = address(1);
    address public la2 = address(2);
    address public mvi1 = address(3);
    address public riskPool = address(4);

    function setUp() public {
        registry = new LAWPActorRegistry(admin);
    }

    function test_InitialAdminIsSet() public view {
        assertEq(registry.owner(), admin);
    }

    function test_SetLA2Wallet() public {
        vm.prank(admin);
        registry.setLA2Wallet(la2);
        assertEq(registry.la2Wallet(), la2);
    }

    function test_SetMVI1Wallet() public {
        vm.prank(admin);
        registry.setMVI1Wallet(mvi1);
        assertEq(registry.mvi1Wallet(), mvi1);
    }

    function test_SetRiskPoolWallet() public {
        vm.prank(admin);
        registry.setRiskPoolWallet(riskPool);
        assertEq(registry.riskPoolWallet(), riskPool);
    }

    function test_RevertIf_NotAdminUpdates() public {
        vm.prank(address(99));
        vm.expectRevert(); // OZ OwnableUnauthorizedAccount
        registry.setLA2Wallet(la2);
    }

    function test_RevertIf_ZeroAddressSet() public {
        vm.prank(admin);
        vm.expectRevert(LAWPActorRegistry.LAWPActorRegistry_ZeroAddress.selector);
        registry.setLA2Wallet(address(0));
    }

    function test_RevertIf_RenounceOwnership() public {
        vm.prank(admin);
        vm.expectRevert("LAWPActorRegistry: renounceOwnership is disabled");
        registry.renounceOwnership();
    }

    function test_TwoStepOwnershipTransfer() public {
        address newAdmin = address(5);

        // Step 1: Admin proposes new owner
        vm.prank(admin);
        registry.transferOwnership(newAdmin);

        // Ownership shouldn't change yet
        assertEq(registry.owner(), admin);

        // Step 2: New owner accepts
        vm.prank(newAdmin);
        registry.acceptOwnership();

        // Ownership is officially transferred
        assertEq(registry.owner(), newAdmin);
    }
}
