// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ILAWPImpactToken
 * @dev Interface for the ERC-721 Impact Token. Acts as a liquid, bearer asset 
 * tracking "Impact Equity" and the right to claim RoC.
 */
interface ILAWPImpactToken {
    /**
     * @notice Mints a new Impact Token receipt for a contribution.
     * @dev Restricted to the Launchpad or Compliance Engine.
     * @param to The address of the contributor.
     * @return tokenId The ID of the newly minted token.
     */
    function mintReceipt(address to) external returns (uint256 tokenId);

    /**
     * @notice Returns the current owner of the given Impact Token.
     * @param tokenId The target token ID.
     * @return owner The address of the current token holder.
     */
    function ownerOf(uint256 tokenId) external view returns (address owner);
}