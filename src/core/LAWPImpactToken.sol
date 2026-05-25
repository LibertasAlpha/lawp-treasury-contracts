// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ERC721 } from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { ILAWPImpactToken } from "../interfaces/ILAWPImpactToken.sol";
import { ILAWPComplianceEngine } from "../interfaces/ILAWPComplianceEngine.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { LAWPStructs } from "../libraries/LAWPStructs.sol";

/// @title LAWPImpactToken
/// @author Obinna Franklin Duru (BinnaDev)
/// @notice Fractional Bearer Asset tracking Impact Equity, RoC, and Continuous Yield rights.
/// @dev Implements the Interception Hook to prevent yield double-spending on secondary markets.
contract LAWPImpactToken is ERC721, ILAWPImpactToken, Ownable2Step, ReentrancyGuard {
    /*//////////////////////////////////////////////////////////////
                          IMPACT TOKEN ERRORS
    //////////////////////////////////////////////////////////////*/
    error LAWPImpactToken_TransferIntercepted();
    error LAWPImpactToken_UnauthorizedCaller();
    error LAWPImpactToken_ExceedsPrincipalCap();
    error LAWPImpactToken_InvalidTokenId();
    error LAWPImpactToken_ZeroAddressMint();
    error LAWPImpactToken_InvalidRocAmount();
    error LAWPImpactToken_ZeroAddress();
    error LAWPImpactToken_InvalidBaseURI();
    error LAWPImpactToken_InvalidPrincipal();
    error LAWPImpactToken_InvalidBPS();
    error LAWPImpactToken_InvalidPoolId();

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/
    uint256 private _nextTokenId = 1;

    /// @notice The LAWPComplianceEngine contract that controls minting, updates, and claims. Critical for enforcing invariants and preventing double-spend exploits.
    address public complianceEngine;

    /// @notice The base URI for all token metadata. Since all unique data is onchain, this is a static URI pointing to a generic JSON schema on IPFS that can be used for all tokens.
    string public baseTokenURI;

    mapping(uint256 tokenId => LAWPStructs.TokenData tokenData) private _tokenData;

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyComplianceEngine() {
        if (msg.sender != complianceEngine) revert LAWPImpactToken_UnauthorizedCaller();
        _;
    }

    constructor(address _initialAdmin, string memory _uri)
        ERC721("LAWP Impact Token", "LAWP-IT")
        Ownable(_initialAdmin)
    {
        if (bytes(_uri).length == 0) {
            revert LAWPImpactToken_InvalidBaseURI();
        }

        baseTokenURI = _uri;
    }

    /// @dev Overridden to prevent accidental renunciation of ownership.
    /// Ownership must always be transferred to a valid address via the two-step process.
    function renounceOwnership() public view override onlyOwner {
        revert("LAWPImpactToken: renounceOwnership is disabled");
    }

    /*//////////////////////////////////////////////////////////////
                        CONFIGURATION LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Links the Compliance Engine. Callable only by Admin/Timelock.
    /// @param _engine The address of the LAWPComplianceEngine contract.
    function setComplianceEngine(address _engine) external onlyOwner {
        if (_engine == address(0)) revert LAWPImpactToken_ZeroAddress();

        address oldEngine = complianceEngine;
        complianceEngine = _engine;

        emit ComplianceEngineUpdated(oldEngine, _engine);
    }

    /// @notice Updates the static IPFS Base URI.
    /// @param _uri The new base URI string.
    function setBaseURI(string memory _uri) external onlyOwner {
        if (bytes(_uri).length == 0) revert LAWPImpactToken_InvalidBaseURI();

        string memory oldURI = baseTokenURI;
        baseTokenURI = _uri;

        emit BaseURIUpdated(oldURI, _uri);
    }

    function _baseURI() internal view override returns (string memory) {
        return baseTokenURI;
    }

    /// @notice Returns the static, global IPFS URI for all tokens.
    /// @dev Overrides standard concatenation since all unique equity data is strictly on-chain.
    /// @param _tokenId The ID of the token (used only for validation in this implementation).
    /// @return The base URI string for metadata resolution.
    function tokenURI(uint256 _tokenId) public view override returns (string memory) {
        _requireOwned(_tokenId);
        return _baseURI();
    }

    /*//////////////////////////////////////////////////////////////
                            CORE LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ILAWPImpactToken
    function mint(address _to, uint256 _netPrincipal, uint256 _poolShareBPS, uint256 _poolId)
        external
        override
        onlyComplianceEngine
        returns (uint256 tokenId)
    {
        if (_to == address(0)) revert LAWPImpactToken_ZeroAddressMint();
        if (_netPrincipal == 0) revert LAWPImpactToken_InvalidPrincipal();
        if (_poolShareBPS == 0 || _poolShareBPS > 10000) revert LAWPImpactToken_InvalidBPS();
        if (_poolId == 0) revert LAWPImpactToken_InvalidPoolId();

        tokenId = _nextTokenId++;

        _tokenData[tokenId] = LAWPStructs.TokenData({
            netPrincipal: _netPrincipal,
            rocReturned: 0,
            poolShareBPS: _poolShareBPS,
            poolId: _poolId
        });

        emit ImpactTokenMinted(tokenId, _to, _netPrincipal, _poolShareBPS);

        _mint(_to, tokenId);
    }

    /// @inheritdoc ILAWPImpactToken
    function updateRocReturned(uint256 _tokenId, uint256 _amount)
        external
        override
        onlyComplianceEngine
    {
        _requireOwned(_tokenId);
        if (_amount == 0) revert LAWPImpactToken_InvalidRocAmount();

        LAWPStructs.TokenData storage data = _tokenData[_tokenId];
        if (data.rocReturned + _amount > data.netPrincipal) {
            revert LAWPImpactToken_ExceedsPrincipalCap();
        }

        data.rocReturned += _amount;
    }

    /// @inheritdoc ILAWPImpactToken
    function getTokenData(uint256 _tokenId)
        external
        view
        override
        returns (LAWPStructs.TokenData memory)
    {
        _requireOwned(_tokenId);
        return _tokenData[_tokenId];
    }

    /// @notice The State Desync Interception Hook (CRITICAL INVARIANT)
    /// @dev Overrides OZ v5 _update to force a yield claim before a token transfers ownership.
    /// @custom:security ComplianceEngine is a fully trusted contract with no reentrant side effects.
    /// But ReentrancyGuard is included to minimize risk of future code changes introducing vulnerabilities in this critical hook.
    /// @param _to The destination address of the transfer (zero if burning).
    /// @param _tokenId The ID of the token being transferred.
    /// @param _auth The address initiating the transfer (for access control, if needed in future).
    /// @return The address of the previous owner before the transfer.
    function _update(address _to, uint256 _tokenId, address _auth)
        internal
        virtual
        override
        nonReentrant
        returns (address)
    {
        address from = _ownerOf(_tokenId);
        
        // If it is a transfer (not minting or burning) and the engine is linked
        if (from != address(0) && _to != address(0) && complianceEngine != address(0)) {
            // 1. Ask the engine exactly how much is owed to this specific token
            uint256 pendingYield =
                ILAWPComplianceEngine(complianceEngine).calculateProportionalYield(_tokenId);

            // 2. Only force flush if there is actually money to claim (prevents NothingToClaim revert)
            if (pendingYield > 0) {
                ILAWPComplianceEngine(complianceEngine).claimYield(_tokenId);
            }
        }

        return super._update(_to, _tokenId, _auth);
    }
}
