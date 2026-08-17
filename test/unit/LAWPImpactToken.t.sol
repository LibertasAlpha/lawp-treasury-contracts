// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {LAWPFixture} from "../base/LAWPFixture.t.sol";
import {LAWPImpactToken} from "../../src/core/LAWPImpactToken.sol";
import {LAWPStructs} from "../../src/libraries/LAWPStructs.sol";
import {ILAWPImpactToken} from "../../src/interfaces/ILAWPImpactToken.sol";

contract MaliciousEngine {
    LAWPImpactToken public token;
    bool public shouldReenter;
    address public reenterTo;
    uint256 public reenterTokenId;

    function setToken(address _token) external {
        token = LAWPImpactToken(_token);
    }

    function setShouldReenter(bool _shouldReenter) external {
        shouldReenter = _shouldReenter;
    }

    function setReenterTo(address _reenterTo) external {
        reenterTo = _reenterTo;
    }

    function setReenterTokenId(uint256 _reenterTokenId) external {
        reenterTokenId = _reenterTokenId;
    }

    function claimYield(uint256) external returns (uint256) {
        if (shouldReenter) {
            token.transferFrom(address(this), reenterTo, reenterTokenId);
        }
        return 0;
    }
}

contract LAWPImpactTokenTest is LAWPFixture {
    function setUp() public override {
        super.setUp();
    }

    /*//////////////////////////////////////////////////////////////
                            INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    function test_RevertIf_ConstructorInvalidBaseURI() public {
        vm.expectRevert(LAWPImpactToken.LAWPImpactToken_InvalidBaseURI.selector);
        new LAWPImpactToken("");
    }

    function test_RevertIf_SetComplianceEngineZeroAddress() public {
        LAWPImpactToken tokenLocal = new LAWPImpactToken("ipfs://test/");
        vm.expectRevert(LAWPImpactToken.LAWPImpactToken_ZeroAddress.selector);
        tokenLocal.setComplianceEngine(address(0));
    }

    function test_RevertIf_AlreadyInitialized() public {
        vm.expectRevert(LAWPImpactToken.LAWPImpactToken_AlreadyInitialized.selector);
        impactToken.setComplianceEngine(address(engine)); // Already done in fixture
    }

    /*//////////////////////////////////////////////////////////////
                            CONFIGURATION LOGIC
    //////////////////////////////////////////////////////////////*/

    function test_RevertIf_SetBaseURI_UnauthorizedCaller() public {
        vm.prank(alice);
        vm.expectRevert(LAWPImpactToken.LAWPImpactToken_UnauthorizedCaller.selector);
        impactToken.setBaseURI("ipfs://new/");
    }

    function test_RevertIf_SetBaseURI_InvalidBaseURI() public {
        vm.prank(address(engine));
        vm.expectRevert(LAWPImpactToken.LAWPImpactToken_InvalidBaseURI.selector);
        impactToken.setBaseURI("");
    }

    function test_SetBaseURI_Success() public {
        vm.prank(address(engine));
        vm.expectEmit(true, true, true, true);
        emit ILAWPImpactToken.BaseURIUpdated("ipfs://QmBase/", "ipfs://new/");
        impactToken.setBaseURI("ipfs://new/");

        vm.prank(address(engine));
        uint256 tokenId = impactToken.mint(alice, 100e6, 1e18, 1);

        assertEq(impactToken.tokenURI(tokenId), "ipfs://new/");
    }

    function test_RevertIf_TokenURI_NotOwned() public {
        vm.expectRevert(abi.encodeWithSignature("ERC721NonexistentToken(uint256)", 999));
        impactToken.tokenURI(999);
    }

    /*//////////////////////////////////////////////////////////////
                            MINTING
    //////////////////////////////////////////////////////////////*/

    function test_RevertIf_Mint_UnauthorizedCaller() public {
        vm.prank(alice);
        vm.expectRevert(LAWPImpactToken.LAWPImpactToken_UnauthorizedCaller.selector);
        impactToken.mint(alice, 100e6, 1e18, 1);
    }

    function test_RevertIf_Mint_ZeroAddress() public {
        vm.prank(address(engine));
        vm.expectRevert(LAWPImpactToken.LAWPImpactToken_ZeroAddressMint.selector);
        impactToken.mint(address(0), 100e6, 1e18, 1);
    }

    function test_RevertIf_Mint_InvalidPrincipal() public {
        vm.prank(address(engine));
        vm.expectRevert(LAWPImpactToken.LAWPImpactToken_InvalidPrincipal.selector);
        impactToken.mint(alice, 0, 1e18, 1);
    }

    function test_RevertIf_Mint_InvalidShareZero() public {
        vm.prank(address(engine));
        vm.expectRevert(LAWPImpactToken.LAWPImpactToken_InvalidShare.selector);
        impactToken.mint(alice, 100e6, 0, 1);
    }

    function test_RevertIf_Mint_InvalidShareTooLarge() public {
        uint256 tooLargeShare = impactToken.TOTAL_SHARES() + 1;
        vm.prank(address(engine));
        vm.expectRevert(LAWPImpactToken.LAWPImpactToken_InvalidShare.selector);
        impactToken.mint(alice, 100e6, tooLargeShare, 1);
    }

    function test_RevertIf_Mint_InvalidPoolId() public {
        vm.prank(address(engine));
        vm.expectRevert(LAWPImpactToken.LAWPImpactToken_InvalidPoolId.selector);
        impactToken.mint(alice, 100e6, 1e18, 0);
    }

    function test_Mint_Success() public {
        vm.prank(address(engine));
        vm.expectEmit(true, true, true, true);
        emit ILAWPImpactToken.ImpactTokenMinted(1, alice, 100e6, 1e18);
        uint256 tokenId = impactToken.mint(alice, 100e6, 1e18, 1);

        assertEq(tokenId, 1);
        assertEq(impactToken.ownerOf(1), alice);

        LAWPStructs.TokenData memory data = impactToken.getTokenData(1);
        assertEq(data.netPrincipal, 100e6);
        assertEq(data.rocReturned, 0);
        assertEq(data.poolShareWAD, 1e18);
        assertEq(data.poolId, 1);
    }

    /*//////////////////////////////////////////////////////////////
                            UPDATE ROC
    //////////////////////////////////////////////////////////////*/

    function test_RevertIf_UpdateRoc_UnauthorizedCaller() public {
        vm.prank(address(engine));
        uint256 tokenId = impactToken.mint(alice, 100e6, 1e18, 1);

        vm.prank(alice);
        vm.expectRevert(LAWPImpactToken.LAWPImpactToken_UnauthorizedCaller.selector);
        impactToken.updateRocReturned(tokenId, 50e6);
    }

    function test_RevertIf_UpdateRoc_NotOwned() public {
        vm.prank(address(engine));
        vm.expectRevert(abi.encodeWithSignature("ERC721NonexistentToken(uint256)", 999));
        impactToken.updateRocReturned(999, 50e6);
    }

    function test_RevertIf_UpdateRoc_InvalidAmount() public {
        vm.prank(address(engine));
        uint256 tokenId = impactToken.mint(alice, 100e6, 1e18, 1);

        vm.prank(address(engine));
        vm.expectRevert(LAWPImpactToken.LAWPImpactToken_InvalidRocAmount.selector);
        impactToken.updateRocReturned(tokenId, 0);
    }

    function test_RevertIf_UpdateRoc_ExceedsPrincipalCap() public {
        vm.prank(address(engine));
        uint256 tokenId = impactToken.mint(alice, 100e6, 1e18, 1);

        vm.prank(address(engine));
        vm.expectRevert(LAWPImpactToken.LAWPImpactToken_ExceedsPrincipalCap.selector);
        impactToken.updateRocReturned(tokenId, 101e6); // 100e6 is the cap
    }

    function test_UpdateRoc_Success() public {
        vm.startPrank(address(engine));
        uint256 tokenId = impactToken.mint(alice, 100e6, 1e18, 1);

        impactToken.updateRocReturned(tokenId, 50e6);

        LAWPStructs.TokenData memory data = impactToken.getTokenData(tokenId);
        assertEq(data.rocReturned, 50e6);

        impactToken.updateRocReturned(tokenId, 50e6);
        data = impactToken.getTokenData(tokenId);
        assertEq(data.rocReturned, 100e6);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                            TRANSFER (HOOK)
    //////////////////////////////////////////////////////////////*/

    function test_Transfer_Hook_SilentCatch() public {
        vm.prank(address(engine));
        uint256 tokenId = impactToken.mint(alice, 100e6, 1e18, 1);

        vm.prank(alice);
        impactToken.transferFrom(alice, bob, tokenId);

        assertEq(impactToken.ownerOf(tokenId), bob);
    }

    function test_Transfer_Hook_BypassIfNoEngine() public {
        LAWPImpactToken tokenLocal = new LAWPImpactToken("ipfs://test/");

        vm.prank(address(0));
        uint256 tokenId = tokenLocal.mint(alice, 100e6, 1e18, 1);

        vm.prank(alice);
        tokenLocal.transferFrom(alice, bob, tokenId);

        assertEq(tokenLocal.ownerOf(tokenId), bob);
    }

    function test_Transfer_Hook_ReentrancyBlock() public {
        MaliciousEngine maliciousEngine = new MaliciousEngine();
        LAWPImpactToken tokenLocal = new LAWPImpactToken("ipfs://test/");

        tokenLocal.setComplianceEngine(address(maliciousEngine));
        maliciousEngine.setToken(address(tokenLocal));

        vm.prank(address(maliciousEngine));
        uint256 tokenId = tokenLocal.mint(address(maliciousEngine), 100e6, 1e18, 1);

        maliciousEngine.setShouldReenter(true);
        maliciousEngine.setReenterTo(operator);
        maliciousEngine.setReenterTokenId(tokenId);

        // Initiate transfer from maliciousEngine to Bob.
        // During _update, it will call maliciousEngine.claimYield(tokenId).
        // maliciousEngine will attempt to re-transfer the token (which hits ReentrancyGuard).
        // The inner transfer will fail.
        // The outer transfer will catch the failure and proceed successfully.

        vm.prank(address(maliciousEngine));
        tokenLocal.transferFrom(address(maliciousEngine), bob, tokenId);

        // The token should successfully land in Bob's address despite the inner reentrancy failure.
        assertEq(tokenLocal.ownerOf(tokenId), bob);
    }

    function test_Transfer_Hook_MaliciousEngine_NoReenter() public {
        MaliciousEngine maliciousEngine = new MaliciousEngine();
        LAWPImpactToken tokenLocal = new LAWPImpactToken("ipfs://test/");

        tokenLocal.setComplianceEngine(address(maliciousEngine));
        maliciousEngine.setToken(address(tokenLocal));

        vm.prank(address(maliciousEngine));
        uint256 tokenId = tokenLocal.mint(address(maliciousEngine), 100e6, 1e18, 1);

        maliciousEngine.setShouldReenter(false);

        vm.prank(address(maliciousEngine));
        tokenLocal.transferFrom(address(maliciousEngine), bob, tokenId);

        assertEq(tokenLocal.ownerOf(tokenId), bob);
    }
}
