// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ILAWPTreasury} from "../interfaces/ILAWPTreasury.sol";
import {LAWPErrors} from "../libraries/LAWPErrors.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/**
 * @title LAWPTreasury
 * @dev The highly-restricted vault for the LAWP ecosystem. 
 * Designed to hold CNGN and only respond to the verified Compliance Engine.
 */
contract LAWPTreasury is ILAWPTreasury, Ownable2Step {
    using SafeERC20 for IERC20;

    address public complianceEngine;

    event ComplianceEngineUpdated(address indexed oldEngine, address indexed newEngine);
    event FundsDeposited(address indexed token, address indexed sender, uint256 amount);
    event FundsTransferred(address indexed token, address indexed to, uint256 amount);

    /**
     * @notice Initializes the Treasury under the control of the Timelock Admin.
     * @param initialOwner The address of the Timelock/Admin.
     */
    constructor(address initialOwner) Ownable(initialOwner) {
        if (initialOwner == address(0)) revert LAWPErrors.Error_ZeroAddress();
    }

    /**
     * @notice Sets the authorized Compliance Engine.
     * @dev Only callable by the Admin. This restricts where the vault takes orders from.
     * @param _complianceEngine The address of the new routing logic contract.
     */
    function setComplianceEngine(address _complianceEngine) external onlyOwner {
        if (_complianceEngine == address(0)) revert LAWPErrors.Error_ZeroAddress();
        address oldEngine = complianceEngine;
        complianceEngine = _complianceEngine;
        emit ComplianceEngineUpdated(oldEngine, _complianceEngine);
    }

    /**
     * @notice Pulls funds from a user into the Treasury.
     * @dev The user must have approved this contract to spend their tokens.
     * @param token The ERC20 token address (CNGN).
     * @param amount The amount to deposit.
     */
    function deposit(address token, uint256 amount) external override {
        if (amount == 0) revert LAWPErrors.Error_ZeroAmount();
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        emit FundsDeposited(token, msg.sender, amount);
    }

    /**
     * @notice Pushes funds out of the Treasury.
     * @dev STRICTLY RESTRICTED to the Compliance Engine. No human or multi-sig can call this directly.
     * @param token The ERC20 token address.
     * @param to The recipient address.
     * @param amount The amount to transfer.
     */
    function executeTransfer(address token, address to, uint256 amount) external override {
        if (msg.sender != complianceEngine) revert LAWPErrors.Error_Unauthorized();
        if (amount == 0) revert LAWPErrors.Error_ZeroAmount();
        if (to == address(0)) revert LAWPErrors.Error_ZeroAddress();

        IERC20(token).safeTransfer(to, amount);
        emit FundsTransferred(token, to, amount);
    }
}