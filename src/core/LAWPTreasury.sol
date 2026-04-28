// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ILAWPTreasury } from "../interfaces/ILAWPTreasury.sol";
import { LAWPErrors } from "../libraries/LAWPErrors.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title LAWPTreasury (The Dumb Vault)
/// @author Obinna Franklin Duru (BinnaDev)
/// @notice Securely holds CNGN assets. Contains zero routing logic.
/// @dev Executes transfers STRICTLY upon command from the authorized LAWPComplianceEngine.
contract LAWPTreasury is ILAWPTreasury, LAWPErrors, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                              STATE VARIABLES
    //////////////////////////////////////////////////////////////*/
    IERC20 public immutable cngnToken;
    address public complianceEngine;
    address public riskPoolWallet;

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyComplianceEngine() {
        if (msg.sender != complianceEngine) revert LAWPTreasury_UnauthorizedCommand();
        _;
    }

    /// @notice Initializes the vault with the CNGN token address.
    /// @param _cngnToken Address of the stablecoin (CNGN).
    /// @param _initialAdmin Address of the Timelock controller.
    constructor(address _cngnToken, address _initialAdmin) Ownable(_initialAdmin) {
        if (_cngnToken == address(0) || _initialAdmin == address(0)) {
            revert LAWPTreasury_ZeroAddress();
        }
        cngnToken = IERC20(_cngnToken);
    }

    /// @dev Overridden to prevent accidental renunciation of ownership.
    /// Ownership must always be transferred to a valid address via the two-step process.
    function renounceOwnership() public view override onlyOwner {
        revert("LAWPTreasury: renounceOwnership is disabled");
    }

    /*//////////////////////////////////////////////////////////////
                        CONFIGURATION LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Links the Compliance Engine to the Vault. Callable only by Admin/Timelock.
    /// @param _engine The address of the LAWPComplianceEngine contract.
    function setComplianceEngine(address _engine) external onlyOwner {
        if (_engine == address(0)) revert LAWPTreasury_ZeroAddress();

        address oldEngine = complianceEngine;
        complianceEngine = _engine;

        emit ComplianceEngineUpdated(oldEngine, _engine);
    }

    /// @notice Sets the destination for the risk fee.
    /// @param _riskPool The address of the risk pool wallet.
    function setRiskPoolWallet(address _riskPool) external onlyOwner {
        if (_riskPool == address(0)) revert LAWPTreasury_ZeroAddress();

        address oldPool = riskPoolWallet;
        riskPoolWallet = _riskPool;

        emit RiskPoolWalletUpdated(oldPool, _riskPool);
    }

    /*//////////////////////////////////////////////////////////////
                          FINANCIAL LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ILAWPTreasury
    /// @dev Assumes the user has already approved this contract to spend their CNGN.
    /// @dev Accounting is handled upstream; this strictly acts as a unified deposit gateway.
    function deposit(uint256 _amount) external override nonReentrant {
        if (_amount == 0) revert LAWPTreasury_InvalidAmount();

        cngnToken.safeTransferFrom(msg.sender, address(this), _amount);

        emit Deposited(msg.sender, _amount);
    }

    /// @inheritdoc ILAWPTreasury
    function executeTransfer(address _to, uint256 _amount)
        external
        override
        onlyComplianceEngine
        nonReentrant
    {
        if (_to == address(0)) revert LAWPTreasury_ZeroAddress();
        if (_amount == 0) revert LAWPTreasury_InvalidAmount();
        if (cngnToken.balanceOf(address(this)) < _amount) {
            revert LAWPTreasury_InsufficientVaultFunds();
        }

        cngnToken.safeTransfer(_to, _amount);

        emit TransferExecuted(_to, _amount);
    }

    /// @inheritdoc ILAWPTreasury
    function routeRiskFee(uint256 _amount) external override onlyComplianceEngine nonReentrant {
        if (_amount == 0) revert LAWPTreasury_InvalidAmount();
        if (riskPoolWallet == address(0)) revert LAWPTreasury_RiskPoolNotSet();
        if (cngnToken.balanceOf(address(this)) < _amount) {
            revert LAWPTreasury_InsufficientVaultFunds();
        }

        cngnToken.safeTransfer(riskPoolWallet, _amount);

        emit RiskFeeRouted(riskPoolWallet, _amount);
    }

    /// @inheritdoc ILAWPTreasury
    function getVaultBalance() external view override returns (uint256) {
        return cngnToken.balanceOf(address(this));
    }
}
