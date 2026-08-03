// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {MockCNGN} from "./MockCNGN.sol";

/// @title MockFOTToken
/// @notice A mock ERC20 simulating a fee-on-transfer token.
contract MockFOTToken is MockCNGN {
    uint256 public feeBPS = 500; // 5% fee

    function setFeeRate(uint256 _fee) external {
        feeBPS = _fee;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        uint256 fee = (amount * feeBPS) / 10000;
        uint256 netAmount = amount - fee;

        _transfer(from, to, netAmount);
        _transfer(from, address(this), fee);

        uint256 currentAllowance = allowance(from, msg.sender);
        require(currentAllowance >= amount, "ERC20: transfer amount exceeds allowance");
        unchecked {
            _approve(from, msg.sender, currentAllowance - amount);
        }
        return true;
    }
}
