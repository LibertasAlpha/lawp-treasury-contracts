// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { LAWPStructs } from "../libraries/LAWPStructs.sol";

/// @title ILAWPComplianceEngine
/// @author Obinna Franklin Duru (BinnaDev)
/// @notice Interface for the core business logic, risk fee deduction, and proportional splitting.
interface ILAWPComplianceEngine {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when the development wallet address is updated.
    event DevWalletUpdated(address indexed oldWallet, address indexed newWallet);

    /// @notice Emitted when the engine is paused, halting all operations until unpaused.
    event EnginePaused(address indexed by);

    /// @notice Emitted when the engine is unpaused, allowing operations to resume.
    event EngineUnpaused(address indexed by);

    /// @notice Emitted when a new contribution is processed and the risk fee is deducted.
    event CapitalPooled(uint256 indexed poolId, uint256 grossAmount, uint256 riskFeeDeducted);

    /// @notice Emitted when the Multi-Sig triggers a validated revenue distribution.
    event RevenueRouted(uint256 indexed poolId, LAWPStructs.FlowType flowType, uint256 totalAmount);

    /// @notice Emitted when a risk fee is assessed for a project pool.
    event RiskFeeAssessed(
        uint256 indexed poolId, uint256 grossAmount, uint256 feeAmount, uint256 netCapital
    );

    /// @notice Emitted when a Contributor pulls their proportional yield.
    event YieldClaimed(
        uint256 indexed tokenId, address indexed claimer, uint256 yieldAmount, uint256 rocAmount
    );

    /*//////////////////////////////////////////////////////////////
                                 LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Processes incoming pooled capital, deducts the 7-10% risk fee, and triggers NFT minting.
    /// @param poolId The specific project pool identifier.
    /// @param grossAmount The total CNGN contributed before fees.
    /// @param contributors Array of contributor addresses.
    /// @param bpsShares Array of proportional shares (must sum to 10000).
    function processPoolDeposit(
        uint256 poolId,
        uint256 grossAmount,
        address[] calldata contributors,
        uint256[] calldata bpsShares
    ) external;

    /// @notice Validates a Multi-Sig proposal payload and routes funds according to the strict LTD/GTE splits.
    /// @param poolId The pool generating the revenue.
    /// @param totalAmount The total CNGN to split.
    /// @param flowType The strict classification of the flow (RoC, GRANT_INITIAL, GRANT_CONTINUOUS).
    function validateAndRoute(uint256 poolId, uint256 totalAmount, LAWPStructs.FlowType flowType)
        external;

    /// @notice Allows a token holder to pull their accrued fractional share (Pull-over-Push pattern).
    /// @param tokenId The ID of the ERC-721 Impact Token.
    function claimYield(uint256 tokenId) external;

    /// @notice Calculates the total proportional yield currently available for a specific token.
    /// @param tokenId The ID of the ERC-721 Impact Token.
    /// @return The amount of CNGN claimable.
    function calculateProportionalYield(uint256 tokenId) external view returns (uint256);
}
