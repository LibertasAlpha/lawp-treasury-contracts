// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { LAWPStructs } from "../libraries/LAWPStructs.sol";

/// @title ILAWPImpactToken
/// @author Obinna Franklin Duru (BinnaDev)
/// @notice Interface for the ERC-721 token representing fractional Impact Equity.
interface ILAWPImpactToken {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when an Impact Token is minted representing a contributor's equity.
    event ImpactTokenMinted(
        uint256 indexed tokenId, address indexed owner, uint256 netPrincipal, uint256 poolShareBPS
    );

    /*//////////////////////////////////////////////////////////////
                                 LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Mints a new Impact Token. Strictly gated to the Compliance Engine.
    /// @param to The address of the contributor.
    /// @param netPrincipal The locked capital after the risk fee deduction.
    /// @param poolShareBPS The proportional percentage in Basis Points.
    /// @param poolId The project deployment pool ID.
    /// @return The ID of the newly minted token.
    function mint(address to, uint256 netPrincipal, uint256 poolShareBPS, uint256 poolId)
        external
        returns (uint256);

    /// @notice Retrieves the immutable and updatable state data for a specific token.
    /// @param tokenId The ID of the token.
    /// @return The TokenData struct containing principal, returned RoC, and BPS share.
    function getTokenData(uint256 tokenId) external view returns (LAWPStructs.TokenData memory);

    /// @notice Updates the `rocReturned` state when RoC payouts are processed.
    /// @param tokenId The ID of the token.
    /// @param amount The amount of RoC paid out.
    function updateRocReturned(uint256 tokenId, uint256 amount) external;
}
