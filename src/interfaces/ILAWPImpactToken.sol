// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { LAWPStructs } from "../libraries/LAWPStructs.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @title ILAWPImpactToken
/// @author Obinna Franklin Duru (BinnaDev)
/// @notice Interface for the ERC-721 token representing fractional Impact Equity.
interface ILAWPImpactToken is IERC721 {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when the Compliance Engine address is updated.
    event ComplianceEngineUpdated(address indexed oldEngine, address indexed newEngine);

    /// @notice Emitted when the base URI for token metadata is updated.
    event BaseURIUpdated(string oldURI, string newURI);

    /// @notice Emitted when an Impact Token is minted representing a contributor's equity.
    event ImpactTokenMinted(
        uint256 indexed tokenId, address indexed owner, uint256 netPrincipal, uint256 poolShareWAD
    );

    /*//////////////////////////////////////////////////////////////
                                 LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Mints a new Impact Token. Strictly gated to the Compliance Engine.
    /// @param to The address of the contributor.
    /// @param netPrincipal The locked capital after the risk fee deduction.
    /// @param poolShareWAD The proportional share as a WAD fraction (1e18 = 100%).
    /// @param poolId The project deployment pool ID.
    /// @return The ID of the newly minted token.
    function mint(address to, uint256 netPrincipal, uint256 poolShareWAD, uint256 poolId)
        external
        returns (uint256);

    /// @notice Retrieves the immutable and updatable state data for a specific token.
    /// @param tokenId The ID of the token.
    /// @return The TokenData struct containing principal, returned RoC, and WAD share.
    function getTokenData(uint256 tokenId) external view returns (LAWPStructs.TokenData memory);

    /// @notice Updates the `rocReturned` state when RoC payouts are processed.
    /// @param tokenId The ID of the token.
    /// @param amount The amount of RoC paid out.
    function updateRocReturned(uint256 tokenId, uint256 amount) external;
}
