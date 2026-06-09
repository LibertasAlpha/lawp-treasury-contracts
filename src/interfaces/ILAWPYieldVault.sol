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

    /// @notice Emitted when the Admin updates the recognized Compliance Engine.
    event ComplianceEngineUpdated(address indexed oldEngine, address indexed newEngine);

    /*//////////////////////////////////////////////////////////////
                               EXECUTION
    //////////////////////////////////////////////////////////////*/

    /// @notice Executes an outbound ERC-20 transfer.
    /// @dev Strictly protected by the onlyEngine modifier. Follows CEI pattern inherently
    /// as it only acts upon fully resolved Engine state.
    /// @param _to The destination address.
    /// @param _amount The exact amount of cNGN to transfer.
    function executeTransfer(address _to, uint256 _amount) external;

    /*//////////////////////////////////////////////////////////////
                             CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Updates the recognized Compliance Engine.
    /// @dev Restricted to the Admin/Owner.
    function setComplianceEngine(address _newEngine) external;
}
