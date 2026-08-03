// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title LAWPConstants
/// @notice Shared mathematical constants, typehashes, and role definitions for testing.
library LAWPConstants {
    // Math Constants
    uint256 constant WAD = 1e18; // TOTAL_SHARES
    uint256 constant BPS = 10_000; // TOTAL_BPS
    uint256 constant MIN_CONTRIBUTION = 100 * 1e6; // 100 cNGN

    // Roles (matching keccak256 hashes in contracts)
    bytes32 constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 constant CAMPAIGN_MANAGER_ROLE = keccak256("CAMPAIGN_MANAGER_ROLE");
    bytes32 constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 constant SIGNER_ROLE = keccak256("SIGNER_ROLE");

    // EIP-712 Domain / TypeHashes
    bytes32 constant PROPOSAL_TYPEHASH =
        keccak256("Proposal(uint256 proposalId,uint256 poolId,uint256 totalAmount,uint8 flowType,uint256 deadline)");
}
