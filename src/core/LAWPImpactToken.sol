// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ILAWPImpactToken} from "../interfaces/ILAWPImpactToken.sol";
import {LAWPErrors} from "../libraries/LAWPErrors.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title LAWPImpactToken
 * @dev The ERC-721 bearer asset representing Impact Equity.
 * Ownership of a specific tokenId is mathematically tied to the right to claim RoC.
 */
contract LAWPImpactToken is ILAWPImpactToken, ERC721, AccessControl {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    
    uint256 private _nextTokenId;

    /**
     * @notice Initializes the token and grants the deployer the initial admin role.
     * @param initialAdmin The address controlling role distribution.
     */
    constructor(address initialAdmin) ERC721("LAWP Impact Token", "LAWPI") {
        if (initialAdmin == address(0)) revert LAWPErrors.Error_ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
        // Start token IDs at 1 to prevent edge cases with ID 0
        _nextTokenId = 1; 
    }

    /**
     * @notice Mints a new Impact Token receipt.
     * @dev Restricted to the Compliance Engine or Launchpad contracts.
     * @param to The address of the contributor.
     * @return tokenId The ID of the newly minted token.
     */
    function mintReceipt(address to) external override returns (uint256 tokenId) {
        if (!hasRole(MINTER_ROLE, msg.sender)) revert LAWPErrors.Error_Unauthorized();
        if (to == address(0)) revert LAWPErrors.Error_ZeroAddress();

        tokenId = _nextTokenId++;
        _mint(to, tokenId);
        
        return tokenId;
    }

    /**
     * @dev Required override to resolve interface collision between ERC721 and AccessControl (ERC165).
     */
    function supportsInterface(bytes4 interfaceId) public view override(ERC721, AccessControl) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}