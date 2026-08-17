// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title ILAWPYieldVault
/// @notice Dedicated vault for isolating Investor Principal, RoC, and Yield.
/// @notice A deliberately un-opinionated, zero-logic vault for asset isolation.
/// @dev Implements the "Dumb Vault" pattern. It has no public deposit functions.
/// All inflows must be orchestrated by the LAWPComplianceEngine via direct ERC20 transfers
/// to prevent orphaned capital.
interface ILAWPYieldVault {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when the Engine explicitly commands the vault to move capital.
    event YieldTransferExecuted(address indexed to, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                               EXECUTION
    //////////////////////////////////////////////////////////////*/

    /// @notice Sets the Compliance Engine address (can only be called once).
    /// @param _engine Address of the LAWPComplianceEngine.
    function setComplianceEngine(address _engine) external;

    /// @notice Executes a token transfer out of the vault.
    /// @dev Can only be called by the Compliance Engine.
    /// @param _to The destination address.
    /// @param _amount The amount of cNGN to transfer.
    function executeTransfer(address _to, uint256 _amount) external;
}
