// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockCNGN
/// @notice A standard ERC20 mock replicating the cNGN 6-decimal stablecoin behavior for testing.
contract MockCNGN is ERC20 {
    constructor() ERC20("cNGN Stablecoin", "cNGN") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}
