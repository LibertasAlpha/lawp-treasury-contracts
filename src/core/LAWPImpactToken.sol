// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {LAWPStructs} from "../libraries/LAWPStructs.sol";
import {ILAWPImpactToken} from "../interfaces/ILAWPImpactToken.sol";
import {ILAWPComplianceEngine} from "../interfaces/ILAWPComplianceEngine.sol";

/// @title LAWPImpactToken
/// @author Obinna Franklin Duru (BinnaDev)
/// @notice Fractional Bearer Asset tracking Impact Equity, RoC, and Continuous Yield rights.
/// @dev Implements the Interception Hook to prevent yield double-spending on secondary markets.
contract LAWPImpactToken is ERC721, ILAWPImpactToken, ReentrancyGuard {
    /*//////////////////////////////////////////////////////////////
                          IMPACT TOKEN ERRORS
    //////////////////////////////////////////////////////////////*/

    error LAWPImpactToken_ZeroAddress();
    error LAWPImpactToken_InvalidShare();
    error LAWPImpactToken_InvalidPoolId();
    error LAWPImpactToken_InvalidBaseURI();
    error LAWPImpactToken_ZeroAddressMint();
    error LAWPImpactToken_InvalidRocAmount();
    error LAWPImpactToken_InvalidPrincipal();
    error LAWPImpactToken_UnauthorizedCaller();
    error LAWPImpactToken_ExceedsPrincipalCap();

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/
    uint256 private _nextTokenId = 1;

    /// @notice WAD denominator: 1e18 = 100% share.
    ///         Any contributor whose WAD share rounds to 0 would need to provide
    ///         less than 1 quintillionth of the pool economically impossible.
    uint256 public constant TOTAL_SHARES = 1e18;

    /// @notice The immutable LAWPComplianceEngine contract that controls minting, updates, and claims.
    address public immutable complianceEngine;

    /// @notice The base URI for all token metadata. Since all unique data is onchain, this is a static URI pointing to a generic JSON schema on IPFS that can be used for all tokens.
    string public baseTokenURI;

    mapping(uint256 tokenId => LAWPStructs.TokenData tokenData) private _tokenData;

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyComplianceEngine() {
        _onlyComplianceEngine();
        _;
    }

    function _onlyComplianceEngine() internal view {
        if (msg.sender != complianceEngine) revert LAWPImpactToken_UnauthorizedCaller();
    }

    constructor(address _engine, string memory _uri) ERC721("LAWP Impact Token", "LAWP-IT") {
        if (_engine == address(0)) revert LAWPImpactToken_ZeroAddress();
        if (bytes(_uri).length == 0) revert LAWPImpactToken_InvalidBaseURI();

        complianceEngine = _engine;
        baseTokenURI = _uri;
    }

    /*//////////////////////////////////////////////////////////////
                        CONFIGURATION LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Updates the static IPFS Base URI.
    /// @param _uri The new base URI string.
    function setBaseURI(string memory _uri) external onlyComplianceEngine {
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
    function mint(address _to, uint256 _netPrincipal, uint256 _poolShareWAD, uint256 _poolId)
        external
        override
        onlyComplianceEngine
        returns (uint256 tokenId)
    {
        if (_to == address(0)) revert LAWPImpactToken_ZeroAddressMint();
        if (_netPrincipal == 0) revert LAWPImpactToken_InvalidPrincipal();
        if (_poolShareWAD == 0 || _poolShareWAD > TOTAL_SHARES) {
            revert LAWPImpactToken_InvalidShare();
        }
        if (_poolId == 0) revert LAWPImpactToken_InvalidPoolId();

        tokenId = _nextTokenId++;

        _tokenData[tokenId] = LAWPStructs.TokenData({
            netPrincipal: _netPrincipal, rocReturned: 0, poolShareWAD: _poolShareWAD, poolId: _poolId
        });

        emit ImpactTokenMinted(tokenId, _to, _netPrincipal, _poolShareWAD);

        _mint(_to, tokenId);
    }

    /// @inheritdoc ILAWPImpactToken
    function updateRocReturned(uint256 _tokenId, uint256 _amount) external override onlyComplianceEngine {
        _requireOwned(_tokenId);
        if (_amount == 0) revert LAWPImpactToken_InvalidRocAmount();

        LAWPStructs.TokenData storage data = _tokenData[_tokenId];
        if (data.rocReturned + _amount > data.netPrincipal) {
            revert LAWPImpactToken_ExceedsPrincipalCap();
        }

        data.rocReturned += _amount;
    }

    /// @inheritdoc ILAWPImpactToken
    function getTokenData(uint256 _tokenId) external view override returns (LAWPStructs.TokenData memory) {
        _requireOwned(_tokenId);
        return _tokenData[_tokenId];
    }

    /// @notice The State Desync Interception Hook (CRITICAL INVARIANT)
    /// @dev Overrides OZ v5 _update to attempt a yield flush before ownership changes hands.
    ///
    ///      Security contract (three guarantees):
    ///      1. A token transfer MUST NEVER be blocked by yield vault state, a race condition,
    ///         or a governance change to `complianceEngine`. This is enforced by caching the
    ///         engine address locally and wrapping the yield claim in a try/catch.
    ///      2. No TOCTOU: The pre-check `calculateProportionalYield` view call has been removed.
    ///         It created a stale-read race where a front-runner draining yield between the view
    ///         and the stateful call caused `claimYield` to revert with NothingToClaim, permanently
    ///         blocking the transfer. The engine's `claimYield` now handles the zero-yield path
    ///         silently when invoked by this hook.
    ///      3. Cross-contract reentrancy: `nonReentrant` guards _update against recursive entry
    ///         into ImpactToken. `updateRocReturned` relies on `onlyComplianceEngine` (not
    ///         nonReentrant) because adding nonReentrant there would deadlock the
    ///         _update -> claimYield -> updateRocReturned call chain (same per-contract lock).
    ///
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

        // Only act on true transfers (not mints or burns) and only when the engine is linked.
        // Cache the engine address locally to prevent a governance-race where the storage slot
        // is updated between two reads within the same transaction.
        if (from != address(0) && _to != address(0)) {
            address engineAddr = complianceEngine;
            if (engineAddr != address(0)) {
                // Attempt to flush pending yield to the outgoing owner.
                // The try/catch guarantees this hook can never block a legitimate transfer:
                //   - vault shortfalls are absorbed silently
                //   - NothingToClaim is absorbed silently (engine returns early for hook callers)
                //   - any future revert path in the engine is safely contained
                // Yield that fails to flush here is NOT lost; it remains claimable by the
                // outgoing owner via a direct `claimYield` call after the transfer completes.
                try ILAWPComplianceEngine(engineAddr).claimYield(_tokenId) {} catch {}
            }
        }

        return super._update(_to, _tokenId, _auth);
    }
}
