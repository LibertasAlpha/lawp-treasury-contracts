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

    /// @notice Emitted when a new contribution is processed and the risk fee is deducted.
    event CapitalPooled(uint256 indexed poolId, uint256 grossAmount, uint256 riskFeeDeducted);

    /// @notice Emitted when the Multi-Sig triggers a validated revenue distribution.
    event RevenueRouted(
        uint256 indexed proposalId, LAWPStructs.FlowType flowType, uint256 totalAmount
    );

    /// @notice Emitted when a Contributor pulls their proportional yield.
    event YieldClaimed(uint256 indexed tokenId, address indexed claimer, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                                 LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Processes incoming pooled capital, deducts the 7-10% risk fee, and triggers NFT minting.
    /// @param poolId The specific project pool identifier.
    /// @param grossAmount The total CNGN contributed before fees.
    function processDeposit(uint256 poolId, uint256 grossAmount) external;

    /// @notice Validates a Multi-Sig proposal payload and routes funds according to the strict LTD/GTE splits.
    /// @param proposalId The ID of the proposal being executed.
    function validateAndRoute(uint256 proposalId) external;

    /// @notice Allows a token holder to pull their accrued fractional share (Pull-over-Push pattern).
    /// @param tokenId The ID of the ERC-721 Impact Token.
    function claimYield(uint256 tokenId) external;

    /// @notice Calculates the total proportional yield currently available for a specific token.
    /// @param tokenId The ID of the ERC-721 Impact Token.
    /// @return The amount of CNGN claimable.
    function calculateProportionalYield(uint256 tokenId) external view returns (uint256);
}
