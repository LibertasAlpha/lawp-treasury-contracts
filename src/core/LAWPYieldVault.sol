// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ILAWPYieldVault } from "../interfaces/ILAWPYieldVault.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title LAWPYieldVault
/// @author Obinna Franklin Duru (BinnaDev)
/// @notice Securely isolates Investor capital (Principal, RoC, and Yield).
/// @dev Designed to evolve independently from operational funds if future lockup/vesting logic is needed for investors.
contract LAWPYieldVault is ILAWPYieldVault, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                          YIELD VAULT ERRORS
    //////////////////////////////////////////////////////////////*/
    error LAWPYieldVault_UnauthorizedCaller();
    error LAWPYieldVault_InvalidAddress();
    error LAWPYieldVault_InvalidAmount();

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice The ERC20 token custodied by this vault (cNGN).
    IERC20 public immutable cngnToken;

    /// @notice The explicitly authorized orchestrator contract (LAWPComplianceEngine).
    address public complianceEngine;

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Restricts execution strictly to the Compliance Engine to prevent unauthorized extraction.
    modifier onlyComplianceEngine() {
        if (msg.sender != complianceEngine) revert LAWPYieldVault_UnauthorizedCaller();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Initializes the vault with the asset token and sets the initial admin.
    /// @param _cngnToken Address of the stablecoin (cNGN).
    /// @param _initialAdmin Address of the deployer or Timelock controller.
    constructor(address _cngnToken, address _initialAdmin) Ownable(_initialAdmin) {
        if (_cngnToken == address(0))  revert LAWPYieldVault_InvalidAddress();

        cngnToken = IERC20(_cngnToken);
    }

    /*//////////////////////////////////////////////////////////////
                        CONFIGURATION LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Overridden to prevent accidental renunciation of ownership.
    /// @dev Ownership must always be explicitly transferred to a valid address via the two-step process.
    function renounceOwnership() public view override onlyOwner {
        revert("LAWPYieldVault: renounceOwnership is disabled");
    }

    /// @notice Links the Compliance Engine to the Vault.
    /// @dev Callable only by the Admin/Timelock. 
    ///      Crucial for establishing the physical trust boundary.
    /// @param _engine The address of the new LAWPComplianceEngine contract.
    function setComplianceEngine(address _engine) external override onlyOwner {
        if (_engine == address(0)) revert LAWPYieldVault_InvalidAddress();

        address oldEngine = complianceEngine;
        complianceEngine = _engine;

        emit ComplianceEngineUpdated(oldEngine, _engine);
    }

    /*//////////////////////////////////////////////////////////////
                          FINANCIAL LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ILAWPYieldVault
    /// @dev Executes the transfer using SafeERC20. 
    //       Relies on the ERC20 contract to revert natively if funds are insufficient.
    function executeTransfer(address _to, uint256 _amount)
        external
        override
        onlyComplianceEngine
        nonReentrant
    {
        if (_to == address(0)) revert LAWPYieldVault_InvalidAddress();
        if (_amount == 0) revert LAWPYieldVault_InvalidAmount();

        // SafeERC20 physically moves the tokens and reverts if the underlying transfer fails
        cngnToken.safeTransfer(_to, _amount);

        emit YieldTransferExecuted(_to, _amount);
    }
}
