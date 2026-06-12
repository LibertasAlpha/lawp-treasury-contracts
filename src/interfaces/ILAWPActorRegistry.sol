// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title ILAWPActorRegistry
/// @author Obinna Franklin Duru (BinnaDev)
/// @notice Interface for the Registry to pull operational wallets.
interface ILAWPActorRegistry {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a core actor's wallet address is updated (LA2, MVI1, Operational Treasury, Dev).
    event ActorUpdated(string role, address indexed oldAddress, address indexed newAddress);

    /*//////////////////////////////////////////////////////////////
                                 LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Funds the broader Libertas Alpha Ecosystem development and governance.
    ///         High allocation for operational stability and factory upkeep.
    /// @dev    This wallet is responsible for overseeing project execution and coordination.
    /// @return Returns the LA2 (Project Management) wallet address.
    function la2Wallet() external view returns (address);

    /// @notice Funds logistics, operational overhead,
    ///         and is the source pool for the dynamic MVI DApp Team Grants.
    ///         Increased ecosystem funding for governance and new MVI launches.
    /// @dev    This wallet is responsible for receiving protocol fees and managing treasury funds.
    /// @return Returns the MVI1 (System Treasury) wallet address.
    function mvi1Wallet() external view returns (address);

    /// @notice Receives and custodies all incoming campaign capital.
    ///         This includes the systemic risk fee (operational risk assumption)
    ///         and the full net campaign capital (funds for campaign execution,
    ///         e.g., purchasing bottles for LAWP deployment).
    ///         Both components flow through this single trusted wallet into
    ///         the Operational Vault for campaign-lifecycle spending.
    /// @dev    This wallet is the unified operational treasury for each campaign pool.
    ///         It is admin-controlled via the Actor Registry (Ownable2Step).
    /// @return Returns the Operational Treasury wallet address.
    function operationalTreasuryWallet() external view returns (address);

    /// @notice Funds the development of the decentralized application,
    ///         and is the source pool for the dynamic MVI Dev Grants.
    ///         Direct, fixed allocation for continuous technical support and platform innovation.
    /// @dev    This wallet is responsible for managing the development
    ///         of the decentralized application.
    /// @return Returns the DApp Team (Dev) wallet address.
    function devWallet() external view returns (address);
}
