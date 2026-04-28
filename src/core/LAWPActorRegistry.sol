// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title LAWPActorRegistry
/// @author Obinna Franklin Duru (BinnaDev)
/// @notice Centralized directory for operational addresses (LA2, MVI1, Risk Pool).
/// @dev Inherits Ownable. Ownership will be transferred to the TimelockController in Phase 6.
contract LAWPActorRegistry is Ownable2Step {
    error LAWPActorRegistry_ZeroAddress();

    address public la2Wallet;
    address public mvi1Wallet;
    address public riskPoolWallet;
    address public devWallet; // For the 10% DApp Team split

    event ActorUpdated(string role, address oldAddress, address newAddress);

    /// @notice Initializes the registry with the initial Timelock/Admin address.
    /// @param _initialAdmin The address of the Timelock controller.
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

    /// @notice Updates the Risk Management Pool wallet.
    /// @param _riskPoolWallet The new address for the Risk Pool wallet.
    function setRiskPoolWallet(address _riskPoolWallet) external onlyOwner {
        if (_riskPoolWallet == address(0)) revert LAWPActorRegistry_ZeroAddress();

        address oldWallet = riskPoolWallet;
        riskPoolWallet = _riskPoolWallet;

        emit ActorUpdated("RISK_POOL", oldWallet, _riskPoolWallet);
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
