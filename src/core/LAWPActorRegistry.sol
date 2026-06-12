// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { ILAWPActorRegistry } from "../interfaces/ILAWPActorRegistry.sol";

/// @title LAWPActorRegistry
/// @author Obinna Franklin Duru (BinnaDev)
/// @notice Centralized directory for operational addresses (LA2, MVI1, Operational Treasury, Dev).
/// @dev Inherits Ownable. Ownership is held by the Admin Safe.
contract LAWPActorRegistry is ILAWPActorRegistry, Ownable2Step {
    /*//////////////////////////////////////////////////////////////
                         ACTOR REGISTRY ERRORS
    //////////////////////////////////////////////////////////////*/
    error LAWPActorRegistry_ZeroAddress();

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice LA2 (Project Management) wallet address responsible for
    ///         high allocation for operational stability and factory upkeep.
    address public la2Wallet;

    /// @notice MVI1 (System Treasury) wallet address responsible for
    ///         increased ecosystem funding for governance and new MVI launches.
    address public mvi1Wallet;

    /// @notice Operational Treasury wallet - the unified custodian for campaign capital.
    ///         Receives both the systemic risk fee and the full net campaign capital
    ///         on every pool deposit. Funds are held in the Operational Vault and
    ///         claimed by this wallet to execute real-world campaign objectives
    ///         (e.g., purchasing bottles for LAWP deployment).
    address public operationalTreasuryWallet;

    /// @notice DApp Team (Dev) wallet address responsible for
    ///         direct, fixed allocation for continuous technical support and platform innovation.
    address public devWallet;

    /// @notice Initializes the registry with the initial Admin Safe / deployer address.
    /// @param _initialAdmin The address of the initial owner.
    constructor(address _initialAdmin) Ownable(_initialAdmin) { }

    /// @dev Overridden to prevent accidental renunciation of ownership.
    /// Ownership must always be transferred to a valid address via the two-step process.
    function renounceOwnership() public view override onlyOwner {
        revert("LAWPActorRegistry: renounceOwnership is disabled");
    }

    /// @notice Updates the LA2 (Project Management) wallet.
    /// @param _la2Wallet The new address for the LA2 wallet.
    function setLA2Wallet(address _la2Wallet) external onlyOwner {
        if (_la2Wallet == address(0)) revert LAWPActorRegistry_ZeroAddress();

        address oldWallet = la2Wallet;
        la2Wallet = _la2Wallet;

        emit ActorUpdated("LA2", oldWallet, _la2Wallet);
    }

    /// @notice Updates the MVI1 (System Treasury) wallet.
    /// @param _mvi1Wallet The new address for the MVI1 wallet.
    function setMVI1Wallet(address _mvi1Wallet) external onlyOwner {
        if (_mvi1Wallet == address(0)) revert LAWPActorRegistry_ZeroAddress();

        address oldWallet = mvi1Wallet;
        mvi1Wallet = _mvi1Wallet;

        emit ActorUpdated("MVI1", oldWallet, _mvi1Wallet);
    }

    /// @notice Updates the Operational Treasury wallet.
    /// @dev    The Operational Treasury is the unified custodian receiving both the
    ///         systemic risk fee and the net campaign capital on every pool deposit.
    /// @param _operationalTreasuryWallet The new address for the Operational Treasury wallet.
    function setOperationalTreasuryWallet(address _operationalTreasuryWallet) external onlyOwner {
        if (_operationalTreasuryWallet == address(0)) revert LAWPActorRegistry_ZeroAddress();

        address oldWallet = operationalTreasuryWallet;
        operationalTreasuryWallet = _operationalTreasuryWallet;

        emit ActorUpdated("OPERATIONAL_TREASURY", oldWallet, _operationalTreasuryWallet);
    }

    /// @notice Updates the DApp Team (Dev) wallet.
    /// @param _devWallet The new address for the Dev wallet.
    function setDevWallet(address _devWallet) external onlyOwner {
        if (_devWallet == address(0)) revert LAWPActorRegistry_ZeroAddress();

        address oldWallet = devWallet;
        devWallet = _devWallet;

        emit ActorUpdated("DEV", oldWallet, _devWallet);
    }
}
