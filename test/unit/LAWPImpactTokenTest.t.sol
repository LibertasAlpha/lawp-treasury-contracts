// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { LAWPImpactToken } from "../../src/core/LAWPImpactToken.sol";
import { LAWPStructs } from "../../src/libraries/LAWPStructs.sol";
import { MockEngineWithCalculateYield } from "../mocks/MaliciousMocks.sol";

/// @title LAWPImpactTokenTest
/// @notice Unit tests for LAWPImpactToken - the fractional bearer asset tracking impact equity.
/// @dev Tests: minting guards, sequential token IDs, return value capture, RoC updates,
///      the CEI-compliant _update() interception hook (super first, then yield claim),
///      burn/mint path exclusions, and ownership protection.
contract LAWPImpactTokenTest is Test {
    LAWPImpactToken public token;
    MockEngineWithCalculateYield public mockEngine;

    address public admin = address(1);
    address public userA = address(10);
    address public userB = address(11);
    address public nobody = address(99);

    event ImpactTokenMinted(
        uint256 indexed tokenId, address indexed to, uint256 netPrincipal, uint256 poolShareWAD
    );
    event ComplianceEngineUpdated(address indexed oldEngine, address indexed newEngine);
    event BaseURIUpdated(string oldURI, string newURI);

    function setUp() public {
        mockEngine = new MockEngineWithCalculateYield();
        token = new LAWPImpactToken(admin, "ipfs://lawp-base/");

        vm.prank(admin);
        token.setComplianceEngine(address(mockEngine));
    }

    /*//////////////////////////////////////////////////////////////
                          CONSTRUCTOR TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Constructor_SetsOwnerAndURI() public view {
        assertEq(token.owner(), admin);
        assertEq(token.baseTokenURI(), "ipfs://lawp-base/");
    }

    function test_Constructor_RevertIf_ZeroAdmin() public {
        vm.expectRevert();
        new LAWPImpactToken(address(0), "ipfs://lawp/");
    }

    function test_Constructor_RevertIf_EmptyURI() public {
        vm.expectRevert(LAWPImpactToken.LAWPImpactToken_InvalidBaseURI.selector);
        new LAWPImpactToken(admin, "");
    }

    /*//////////////////////////////////////////////////////////////
                          CONFIGURATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SetComplianceEngine_Success() public {
        address newEngine = address(77);
        vm.prank(admin);
        vm.expectEmit(true, true, false, false);
        emit ComplianceEngineUpdated(address(mockEngine), newEngine);
        token.setComplianceEngine(newEngine);
        assertEq(token.complianceEngine(), newEngine);
    }

    function test_SetComplianceEngine_RevertIf_ZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(LAWPImpactToken.LAWPImpactToken_ZeroAddress.selector);
        token.setComplianceEngine(address(0));
    }

    function test_SetComplianceEngine_RevertIf_NotOwner() public {
        vm.prank(nobody);
        vm.expectRevert();
        token.setComplianceEngine(address(77));
    }

    function test_SetBaseURI_Success() public {
        string memory newURI = "ipfs://updated/";
        vm.prank(admin);
        vm.expectEmit(false, false, false, true);
        emit BaseURIUpdated("ipfs://lawp-base/", newURI);
        token.setBaseURI(newURI);
        assertEq(token.baseTokenURI(), newURI);
    }

    function test_SetBaseURI_RevertIf_Empty() public {
        vm.prank(admin);
        vm.expectRevert(LAWPImpactToken.LAWPImpactToken_InvalidBaseURI.selector);
        token.setBaseURI("");
    }

    /*//////////////////////////////////////////////////////////////
                           MINT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Mint_OnlyEngine() public {
        vm.prank(address(mockEngine));
        uint256 tokenId = token.mint(userA, 90_000e6, 1e18, 1);

        assertEq(tokenId, 1);
        assertEq(token.ownerOf(1), userA);
        assertEq(token.balanceOf(userA), 1);
    }

    function test_Mint_ReturnsSequentialTokenIds() public {
        vm.startPrank(address(mockEngine));
        uint256 id1 = token.mint(userA, 54_000e6, 6e17, 1);
        uint256 id2 = token.mint(userB, 36_000e6, 4e17, 1);
        uint256 id3 = token.mint(userA, 45_000e6, 1e18, 2);
        vm.stopPrank();

        assertEq(id1, 1);
        assertEq(id2, 2);
        assertEq(id3, 3);
    }

    function test_Mint_StoresTokenDataCorrectly() public {
        vm.prank(address(mockEngine));
        uint256 tokenId = token.mint(userA, 54_000e6, 6e17, 1);

        LAWPStructs.TokenData memory data = token.getTokenData(tokenId);
        assertEq(data.netPrincipal, 54_000e6);
        assertEq(data.rocReturned, 0);
        assertEq(data.poolShareWAD, 6e17);
        assertEq(data.poolId, 1);
    }

    function test_Mint_EmitsImpactTokenMinted() public {
        vm.prank(address(mockEngine));
        vm.expectEmit(true, true, false, true);
        emit ImpactTokenMinted(1, userA, 90_000e6, 1e18);
        token.mint(userA, 90_000e6, 1e18, 1);
    }

    function test_Mint_RevertIf_NotEngine() public {
        vm.prank(nobody);
        vm.expectRevert(LAWPImpactToken.LAWPImpactToken_UnauthorizedCaller.selector);
        token.mint(userA, 90_000e6, 1e18, 1);
    }

    function test_Mint_RevertIf_ZeroAddress() public {
        vm.prank(address(mockEngine));
        vm.expectRevert(LAWPImpactToken.LAWPImpactToken_ZeroAddressMint.selector);
        token.mint(address(0), 90_000e6, 1e18, 1);
    }

    function test_Mint_RevertIf_ZeroPrincipal() public {
        vm.prank(address(mockEngine));
        vm.expectRevert(LAWPImpactToken.LAWPImpactToken_InvalidPrincipal.selector);
        token.mint(userA, 0, 1e18, 1);
    }

    function test_Mint_RevertIf_ZeroWAD() public {
        vm.prank(address(mockEngine));
        vm.expectRevert(LAWPImpactToken.LAWPImpactToken_InvalidShare.selector);
        token.mint(userA, 90_000e6, 0, 1);
    }

    function test_Mint_RevertIf_WADExceedsMax() public {
        vm.prank(address(mockEngine));
        vm.expectRevert(LAWPImpactToken.LAWPImpactToken_InvalidShare.selector);
        token.mint(userA, 90_000e6, 1e18 + 1, 1);
    }

    function test_Mint_RevertIf_ZeroPoolId() public {
        vm.prank(address(mockEngine));
        vm.expectRevert(LAWPImpactToken.LAWPImpactToken_InvalidPoolId.selector);
        token.mint(userA, 90_000e6, 1e18, 0);
    }

    /*//////////////////////////////////////////////////////////////
                     UPDATE ROC RETURNED TESTS
    //////////////////////////////////////////////////////////////*/

    function test_UpdateRocReturned_Success() public {
        vm.prank(address(mockEngine));
        uint256 tokenId = token.mint(userA, 90_000e6, 1e18, 1);

        vm.prank(address(mockEngine));
        token.updateRocReturned(tokenId, 45_000e6);

        LAWPStructs.TokenData memory data = token.getTokenData(tokenId);
        assertEq(data.rocReturned, 45_000e6);
    }

    function test_UpdateRocReturned_Cumulative() public {
        vm.prank(address(mockEngine));
        uint256 tokenId = token.mint(userA, 90_000e6, 1e18, 1);

        vm.startPrank(address(mockEngine));
        token.updateRocReturned(tokenId, 30_000e6);
        token.updateRocReturned(tokenId, 30_000e6);
        vm.stopPrank();

        assertEq(token.getTokenData(tokenId).rocReturned, 60_000e6);
    }

    function test_UpdateRocReturned_ExactCap_Succeeds() public {
        vm.prank(address(mockEngine));
        uint256 tokenId = token.mint(userA, 90_000e6, 1e18, 1);

        vm.prank(address(mockEngine));
        token.updateRocReturned(tokenId, 90_000e6); // Exactly at cap - must succeed
        assertEq(token.getTokenData(tokenId).rocReturned, 90_000e6);
    }

    function test_UpdateRocReturned_RevertIf_ExceedsCap() public {
        vm.prank(address(mockEngine));
        uint256 tokenId = token.mint(userA, 90_000e6, 1e18, 1);

        vm.prank(address(mockEngine));
        vm.expectRevert(LAWPImpactToken.LAWPImpactToken_ExceedsPrincipalCap.selector);
        token.updateRocReturned(tokenId, 90_001e6); // 1 wei over cap
    }

    function test_UpdateRocReturned_RevertIf_ZeroAmount() public {
        vm.prank(address(mockEngine));
        uint256 tokenId = token.mint(userA, 90_000e6, 1e18, 1);

        vm.prank(address(mockEngine));
        vm.expectRevert(LAWPImpactToken.LAWPImpactToken_InvalidRocAmount.selector);
        token.updateRocReturned(tokenId, 0);
    }

    function test_UpdateRocReturned_RevertIf_NotEngine() public {
        vm.prank(address(mockEngine));
        uint256 tokenId = token.mint(userA, 90_000e6, 1e18, 1);

        vm.prank(nobody);
        vm.expectRevert(LAWPImpactToken.LAWPImpactToken_UnauthorizedCaller.selector);
        token.updateRocReturned(tokenId, 1000e6);
    }

    /*//////////////////////////////////////////////////////////////
                   _UPDATE INTERCEPTION HOOK TESTS
    //////////////////////////////////////////////////////////////*/

    function test_TransferHook_DoesNotFireOnMint() public {
        // Minting: from == address(0) - hook must not fire
        vm.prank(address(mockEngine));
        token.mint(userA, 90_000e6, 1e18, 1);

        assertFalse(mockEngine.claimYieldCalled(), "Hook must NOT fire on mint");
    }

    /// @dev After C-1 fix: the hook always calls claimYield (no pre-check gate).
    ///      The engine handles the zero-yield case silently. The transfer must succeed.
    function test_TransferHook_AlwaysCallsClaimYield_EvenWithZeroYield() public {
        vm.prank(address(mockEngine));
        token.mint(userA, 90_000e6, 1e18, 1);

        // pendingYield == 0 - hook now calls claimYield unconditionally.
        // The engine returns silently; transfer still succeeds.
        mockEngine.setPendingYield(0);

        vm.prank(userA);
        token.transferFrom(userA, userB, 1);

        // claimYield IS called (no pre-check guard in _update anymore)
        assertTrue(mockEngine.claimYieldCalled(), "Hook MUST always call claimYield");
        assertEq(token.ownerOf(1), userB, "Transfer must succeed regardless of yield state");
    }

    function test_TransferHook_FiresWhenYieldPending() public {
        vm.prank(address(mockEngine));
        token.mint(userA, 90_000e6, 1e18, 1);

        mockEngine.setPendingYield(5_000e6); // Simulate pending yield

        vm.prank(userA);
        token.transferFrom(userA, userB, 1);

        assertTrue(mockEngine.claimYieldCalled(), "Hook MUST fire when yield > 0");
        assertEq(token.ownerOf(1), userB);
    }

    /*//////////////////////////////////////////////////////////////
                    SECURITY REGRESSION TESTS
    //////////////////////////////////////////////////////////////*/

    /// @dev Verifies Guarantee #2: a reverting claimYield must NEVER block a token transfer.
    ///      Simulates the TOCTOU scenario where yield is drained between hook invocation and
    ///      execution, causing the engine to revert. The try/catch in _update must absorb it.
    function test_TransferNeverBlocked_WhenClaimYieldReverts() public {
        vm.prank(address(mockEngine));
        token.mint(userA, 90_000e6, 1e18, 1);

        // Force claimYield to always revert (simulates TOCTOU race or vault shortfall)
        mockEngine.setClaimYieldShouldRevert(true);

        // Transfer must still succeed - the try/catch absorbs the revert
        vm.prank(userA);
        token.transferFrom(userA, userB, 1);

        assertEq(token.ownerOf(1), userB, "Transfer must succeed even when claimYield reverts");
    }

    /// @dev Verifies that _update does NOT call calculateProportionalYield.
    ///      Uses a tracking mock that distinguishes between the two calls.
    function test_HookDoesNotCallCalculateProportionalYield() public {
        TrackingMockEngine trackingEngine = new TrackingMockEngine();

        vm.prank(admin);
        token.setComplianceEngine(address(trackingEngine));

        vm.prank(address(trackingEngine));
        token.mint(userA, 90_000e6, 1e18, 1);

        vm.prank(userA);
        token.transferFrom(userA, userB, 1);

        assertFalse(
            trackingEngine.calculateProportionalYieldCalled(),
            "_update must NOT call calculateProportionalYield after C-1 fix"
        );
        assertTrue(
            trackingEngine.claimYieldCalled(),
            "_update MUST call claimYield directly (no pre-check gate)"
        );
    }

    /// @dev Verifies that mint path (from == address(0)) does not trigger the hook.
    ///      Regression guard: existing behaviour preserved after the changes.
    function test_HookDoesNotFireOnMint_Regression() public {
        vm.prank(address(mockEngine));
        token.mint(userA, 90_000e6, 1e18, 1);
        // After mint, claimYieldCalled should still be false (hook only fires on transfers)
        assertFalse(mockEngine.claimYieldCalled(), "Hook MUST NOT fire on mint");
    }

    /*//////////////////////////////////////////////////////////////
                            URI TESTS
    //////////////////////////////////////////////////////////////*/

    function test_TokenURI_ReturnsBaseURI() public {
        vm.prank(address(mockEngine));
        uint256 tokenId = token.mint(userA, 90_000e6, 1e18, 1);
        assertEq(token.tokenURI(tokenId), "ipfs://lawp-base/");
    }

    function test_TokenURI_RevertIf_TokenDoesNotExist() public {
        vm.expectRevert();
        token.tokenURI(999);
    }

    /*//////////////////////////////////////////////////////////////
                      OWNERSHIP PROTECTION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_RenounceOwnership_IsDisabled() public {
        vm.prank(admin);
        vm.expectRevert("LAWPImpactToken: renounceOwnership is disabled");
        token.renounceOwnership();
    }

    function test_TwoStepOwnershipTransfer_Success() public {
        address newAdmin = address(88);
        vm.prank(admin);
        token.transferOwnership(newAdmin);
        assertEq(token.owner(), admin);

        vm.prank(newAdmin);
        token.acceptOwnership();
        assertEq(token.owner(), newAdmin);
    }

    /*//////////////////////////////////////////////////////////////
                         FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_Mint_ValidParameters(
        address to,
        uint256 principal,
        uint256 wad,
        uint256 poolId
    ) public {
        vm.assume(to != address(0));
        wad = bound(wad, 1, 1e18);
        principal = bound(principal, 1, type(uint128).max);
        poolId = bound(poolId, 1, type(uint128).max);

        vm.prank(address(mockEngine));
        uint256 tokenId = token.mint(to, principal, wad, poolId);

        assertGt(tokenId, 0);
        assertEq(token.ownerOf(tokenId), to);
        LAWPStructs.TokenData memory data = token.getTokenData(tokenId);
        assertEq(data.netPrincipal, principal);
        assertEq(data.poolShareWAD, wad);
        assertEq(data.poolId, poolId);
    }

    function testFuzz_UpdateRocReturned_NeverExceedsCap(uint256 principal, uint256 rocAmount)
        public
    {
        principal = bound(principal, 1e6, 1_000_000e6);
        rocAmount = bound(rocAmount, 1, principal);

        vm.prank(address(mockEngine));
        uint256 tokenId = token.mint(userA, principal, 1e18, 1);

        vm.prank(address(mockEngine));
        token.updateRocReturned(tokenId, rocAmount);

        LAWPStructs.TokenData memory data = token.getTokenData(tokenId);
        assertLe(data.rocReturned, data.netPrincipal);
    }
}

/*//////////////////////////////////////////////////////////////
              C-1 HELPER: TRACKING MOCK ENGINE
//////////////////////////////////////////////////////////////*/

/// @title TrackingMockEngine
/// @notice Independently tracks calculateProportionalYield and claimYield call counts.
///         Used by test_C1_HookDoesNotCallCalculateProportionalYield to assert that
///         the fixed _update no longer calls calculateProportionalYield.
contract TrackingMockEngine {
    bool public calculateProportionalYieldCalled;
    bool public claimYieldCalled;

    function calculateProportionalYield(uint256) external returns (uint256) {
        calculateProportionalYieldCalled = true;
        return 0;
    }

    function claimYield(uint256) external {
        claimYieldCalled = true;
    }

    /// @notice Allows this mock to act as the minting authority for test setup.
    function mint(address token, address to, uint256 principal, uint256 wad, uint256 poolId)
        external
        returns (uint256)
    {
        return LAWPImpactToken(token).mint(to, principal, wad, poolId);
    }
}
