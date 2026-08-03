// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {MockCNGN} from "./MockCNGN.sol";

/// @title MockZeroOpToken
/// @notice A mock ERC20 that intentionally transfers 0 tokens to the Operational Vault.
contract MockZeroOpToken is MockCNGN {
    address public opVault;

    function setOpVault(address _opVault) external {
        opVault = _opVault;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (to == opVault) {
            // simulate 100% fee or failure to deliver actual tokens to opVault
            return true;
        }
        return super.transferFrom(from, to, amount);
    }
}
