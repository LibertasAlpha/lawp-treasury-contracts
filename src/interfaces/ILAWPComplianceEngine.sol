// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LAWPStructs} from "../libraries/LAWPStructs.sol";

/**
 * @title ILAWPComplianceEngine
 * @dev Interface for the Brain of the protocol. Translates the LTD/GTE non-profit 
 * mandate into immutable on-chain routing rules.
 */
interface ILAWPComplianceEngine {
    /**
     * @notice Validates a proposed execution against the strict non-profit rules and routes funds.
     * @dev If validation fails, this function MUST revert, causing the entire multi-sig transaction to revert.
     * @param proposal The populated Proposal struct containing the request.
     */
    function validateAndRoute(LAWPStructs.Proposal calldata proposal) external;

    /**
     * @notice Calculates the precise grant splits based on the provided flow type.
     * @param amount The total surplus amount to split.
     * @param flowType Must be GRANT_INITIAL or GRANT_CONTINUOUS.
     * @return splits An array of calculated amounts destined for respective actors.
     */
    function calculateGrantSplits(uint256 amount, LAWPStructs.FlowType flowType) external view returns (uint256[] memory splits);

    /**
     * @notice Returns the remaining Return of Contribution (RoC) allowed for a specific Impact Token.
     * @param tokenId The ERC-721 Impact Token ID.
     * @return remaining The remaining principal that can be legally claimed.
     */
    function getRemainingRoC(uint256 tokenId) external view returns (uint256 remaining);
}