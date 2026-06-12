// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { LAWPStructs } from "../libraries/LAWPStructs.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title ILAWPComplianceEngine
/// @author Obinna Franklin Duru (BinnaDev)
/// @notice The Zero-Custody Switchboard and Deterministic Accounting Layer.
/// @dev Calculates splits, orchestrates single-hop transfers from external sources
///      to isolated Vaults, and maintains O(1) ledgers for pull-based claiming.
interface ILAWPComplianceEngine {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when the engine is paused, halting all operations until unpaused.
    event EnginePaused(address indexed by);

    /// @notice Emitted when the engine is unpaused, allowing operations to resume.
    event EngineUnpaused(address indexed by);

    /// @notice Emitted when the risk fee basis points are updated.
    event RiskFeeUpdated(uint256 oldFeeBPS, uint256 newFeeBPS);

    /// @notice Emitted when the Multi-Sig Controller address is updated.
    event MultiSigControllerUpdated(address indexed oldController, address indexed newController);

    /// @notice Emitted when a new project pool is created.
    event PoolCreated(uint256 indexed poolId, uint256 timestamp);

    /// @notice Emitted when a risk fee is assessed for a project pool.
    event RiskFeeAssessed(
        uint256 indexed poolId, uint256 grossAmount, uint256 feeAmount, uint256 netCapital
    );

    /// @notice Emitted when a new contribution is processed and capital is safely locked.
    event CapitalPooled(uint256 indexed poolId, uint256 grossAmount, uint256 riskFeeDeducted);

    /// @notice Emitted when off-chain revenue is mathematically allocated and routed.
    event OperationalAllocationRouted(
        uint256 indexed poolId, LAWPStructs.FlowType flowType, uint256 totalAmount
    );

    /// @notice Emitted when an operational actor (LA2, Dev, etc.) pulls their allocated funds.
    event OperationalFundsClaimed(address indexed wallet, uint256 amount);

    /// @notice Emitted when a Contributor pulls their proportional yield and RoC.
    event YieldClaimed(
        uint256 indexed tokenId, address indexed claimer, uint256 yieldAmount, uint256 rocAmount
    );

    /*//////////////////////////////////////////////////////////////
                           CAPITAL FORMATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Processes incoming campaign capital and orchestrates physical vault routing.
    /// @dev Pulls `_grossAmount` from msg.sender in a single transfer into the Operational Vault.
    ///      Internally credits the `operationalTreasuryWallet` with both the risk fee component
    ///      and the net campaign capital component via the pull-based `operationalBalances` ledger.
    ///      No funds touch the Yield Vault at deposit time — the Yield Vault is funded exclusively
    ///      by subsequent revenue routing (GRANT_INITIAL, GRANT_CONTINUOUS, RoC flows).
    ///      Mints fractional ERC-721 equity to contributors tracking their netPrincipal shares.
    /// @param _poolId The unique deployment pool identifier.
    /// @param _grossAmount Total payment token deposited before risk fee deduction.
    /// @param _contributors Array of investor wallet addresses.
    /// @param _bpsShares Array of basis points representing fractional equity (must sum to 10000).
    function processPoolDeposit(
        uint256 _poolId,
        uint256 _grossAmount,
        address[] calldata _contributors,
        uint256[] calldata _bpsShares
    ) external;

    /*//////////////////////////////////////////////////////////////
                           REVENUE ROUTING
    //////////////////////////////////////////////////////////////*/

    /// @notice Orchestrates the mathematical split and physical routing of external revenue.
    /// @dev Pulls `_totalAmount` directly from the `_fundProvider`. Drops Yield/RoC directly into
    ///      the Yield Vault. Drops Operational funds directly into the Operational Vault. Credits internal ledgers.
    /// @param _poolId The target deployment pool.
    /// @param _totalAmount The verified fiat-equivalent revenue entering the system.
    /// @param _fundProvider The relayer (msg.sender of MultiSig) providing the capital.
    /// @param _flowType GRANT_INITIAL, GRANT_CONTINUOUS, or RoC.
    function routeOperationalAllocation(
        uint256 _poolId,
        uint256 _totalAmount,
        address _fundProvider,
        LAWPStructs.FlowType _flowType
    ) external;

    /*//////////////////////////////////////////////////////////////
                           PULL-OVER-PUSH CLAIMS
    //////////////////////////////////////////////////////////////*/

    /// @notice Allows operational teams to claim their allocated revenue splits.
    /// @dev Relies on the `operationalBalances` ledger. Follows strict CEI pattern.
    /// @param _wallet The operational actor's wallet address. Can be LA2, Dev, etc.
    function claimOperationalFunds(address _wallet) external;

    /// @notice Allows an investor to pull their accrued yield for a specific token.
    /// @dev Calculates un-claimed yield against the O(1) `poolYieldTracker`.
    /// @param _tokenId The ERC-721 Impact Token ID.
    function claimYield(uint256 _tokenId) external;

    /// @notice Gas-optimized batch claim for multiple tokens owned by the caller.
    /// @param _tokenIds Array of token IDs to claim against.
    function claimYieldBatch(uint256[] calldata _tokenIds) external;

    /*//////////////////////////////////////////////////////////////
                               VIEW HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Calculates the exact pending yield for a specific token.
    /// @param _tokenId The ERC-721 Impact Token ID.
    function calculateProportionalYield(uint256 _tokenId) external view returns (uint256);

    /// @notice Checks if a given pool ID corresponds to an active project pool.
    /// @param _poolId The unique deployment pool identifier.
    function isPoolActive(uint256 _poolId) external view returns (bool);
}
