// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ILAWPActorRegistry
/// @author Obinna Franklin Duru (BinnaDev)
/// @notice Interface for the Registry to pull operational wallets.
interface ILAWPActorRegistry {
    /*//////////////////////////////////////////////////////////////
                                 LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the LA2 (Project Management) wallet address.
    function la2Wallet() external view returns (address);

    /// @notice Returns the MVI1 (System Treasury) wallet address.
    function mvi1Wallet() external view returns (address);

    /// @notice Returns the Risk Management Pool wallet address.
    function riskPoolWallet() external view returns (address);

    /// @notice Returns the DApp Team (Dev) wallet address.
    function devWallet() external view returns (address);
}
