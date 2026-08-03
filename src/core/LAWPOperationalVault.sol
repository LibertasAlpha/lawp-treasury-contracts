// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {ILAWPOperationalVault} from "../interfaces/ILAWPOperationalVault.sol";

/// @title LAWPOperationalVault
/// @author Obinna Franklin Duru (BinnaDev)
/// @notice Securely isolates Protocol & Payroll capital.
/// @dev Designed to evolve independently from investor funds if operational vesting/multisig requirements are added later.
contract LAWPOperationalVault is ILAWPOperationalVault, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                       OPERATIONAL VAULT ERRORS
    //////////////////////////////////////////////////////////////*/
    error LAWPOperationalVault_InvalidAmount();
    error LAWPOperationalVault_InvalidAddress();
    error LAWPOperationalVault_UnauthorizedCaller();

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice The immutable, explicitly authorized orchestrator contract (LAWPComplianceEngine).
    address public immutable complianceEngine;

    /// @notice The immutable ERC20 settlement token (cNGN) for all deposits, fees, and yield distributions.
    IERC20 public immutable cNGNToken;

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Restricts execution strictly to the Compliance Engine to prevent unauthorized extraction.
    modifier onlyComplianceEngine() {
        _onlyComplianceEngine();
        _;
    }

    function _onlyComplianceEngine() internal view {
        if (msg.sender != complianceEngine) revert LAWPOperationalVault_UnauthorizedCaller();
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Initializes the vault and binds it to the Compliance Engine.
    /// @param _cNGNToken Address of the stablecoin (cNGN).
    /// @param _engine Address of the LAWPComplianceEngine.
    constructor(address _cNGNToken, address _engine) {
        if (_cNGNToken == address(0) || _engine == address(0)) revert LAWPOperationalVault_InvalidAddress();

        cNGNToken = IERC20(_cNGNToken);
        complianceEngine = _engine;
    }

    /*//////////////////////////////////////////////////////////////
                          FINANCIAL LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ILAWPOperationalVault
    /// @dev Executes the transfer using SafeERC20. Relies on the ERC20 contract to revert natively if funds are insufficient.
    function executeTransfer(address _to, uint256 _amount) external override onlyComplianceEngine nonReentrant {
        if (_to == address(0)) revert LAWPOperationalVault_InvalidAddress();
        if (_amount == 0) revert LAWPOperationalVault_InvalidAmount();

        // SafeERC20 physically moves the tokens and reverts if the underlying transfer fails
        cNGNToken.safeTransfer(_to, _amount);

        emit OperationalTransferExecuted(_to, _amount);
    }
}
