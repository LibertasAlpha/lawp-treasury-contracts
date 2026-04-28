// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ILAWPTreasury
/// @author Obinna Franklin Duru (BinnaDev)
/// @notice Interface for the "Dumb Vault" which holds assets and accepts routing commands.
interface ILAWPTreasury {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when the Compliance Engine address is updated.
    event ComplianceEngineUpdated(address indexed oldEngine, address indexed newEngine);

    /// @notice Emitted when the Risk Pool wallet address is updated.
    event RiskPoolWalletUpdated(address indexed oldPool, address indexed newPool);

    /// @notice Emitted when a deposit is made into the treasury.
    event Deposited(address indexed sender, uint256 amount);

    /// @notice Emitted when a transfer is executed from the treasury.
    event TransferExecuted(address indexed to, uint256 amount);

    /// @notice Emitted when the risk fee is routed to the Risk Pool.
    event RiskFeeRouted(address indexed riskPool, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                                 LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Accepts incoming CNGN deposits.
    /// @param amount The total amount of CNGN deposited.
    function deposit(uint256 amount) external;

    /// @notice Executes a transfer to a specified address. Strictly gated to the Compliance Engine.
    /// @param to The recipient address.
    /// @param amount The amount of CNGN to transfer.
    function executeTransfer(address to, uint256 amount) external;

    /// @notice Routes the deducted risk fee to the dedicated Risk Management Pool.
    /// @param amount The risk fee amount to route.
    function routeRiskFee(uint256 amount) external;

    /// @notice Returns the current balance of the treasury.
    function getVaultBalance() external view returns (uint256);
}
