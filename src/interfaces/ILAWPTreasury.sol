// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ILAWPTreasury
 * @dev Interface for the LAWP Treasury (The Vault). 
 * Holds the CNGN and strictly restricts out-bound transfers to the Compliance Engine.
 */
interface ILAWPTreasury {
    /**
     * @notice Deposits an asset into the treasury.
     * @param token The address of the ERC20 token (e.g., CNGN).
     * @param amount The amount to deposit.
     */
    function deposit(address token, uint256 amount) external;

    /**
     * @notice Executes an outbound transfer.
     * @dev MUST be permissioned strictly to the Compliance Engine.
     * @param token The address of the ERC20 token to transfer.
     * @param to The recipient address.
     * @param amount The amount to transfer.
     */
    function executeTransfer(address token, address to, uint256 amount) external;
}