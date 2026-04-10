// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {LAWPErrors} from "../libraries/LAWPErrors.sol";

/**
 * @title LAWPActorRegistry
 * @dev Centralized directory for the Libertas Alpha Water Project.
 * Maps operational roles (Human Nodes, LA2, etc.) to wallet addresses.
 * Governed by a Timelocked Admin (DEFAULT_ADMIN_ROLE).
 */
contract LAWPActorRegistry is AccessControl {
    bytes32 public constant HUMAN_NODE_ROLE = keccak256("HUMAN_NODE_ROLE");
    bytes32 public constant LA2_ROLE = keccak256("LA2_ROLE");
    bytes32 public constant MVI1_ROLE = keccak256("MVI1_ROLE");
    bytes32 public constant TECH_TEAM_ROLE = keccak256("TECH_TEAM_ROLE");

    /**
     * @notice Initializes the registry and assigns the default admin.
     * @param initialAdmin The address (ideally a Timelock/Safe) that will manage the registry.
     */
    constructor(address initialAdmin) {
        if (initialAdmin == address(0)) revert LAWPErrors.Error_ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
    }

    /**
     * @notice Convenience function to strictly check if an actor holds a specific role.
     * @dev Reverts with a custom error if the role is missing, ensuring gas-efficient routing failures.
     * @param role The bytes32 role identifier.
     * @param account The address to check.
     */
    function enforceRole(bytes32 role, address account) external view {
        if (!hasRole(role, account)) {
            revert LAWPErrors.Error_RoleNotRegistered(role, account);
        }
    }
}