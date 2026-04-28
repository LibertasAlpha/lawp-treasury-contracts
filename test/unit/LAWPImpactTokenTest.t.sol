// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { LAWPImpactToken } from "../../src/core/LAWPImpactToken.sol";
import { LAWPErrors } from "../../src/libraries/LAWPErrors.sol";
import { LAWPStructs } from "../../src/libraries/LAWPStructs.sol";

/*
 * ============================================================================
 * @dev NOTE FOR PHASE 6 DEPLOYMENT (Invariant Testing)
 * ============================================================================
 * Finding: Incomplete Privilege Revocation During Deployment
 * Severity: Medium
 * * Description:
 * The constructor pattern atomically sets the Timelock as `owner` of governed
 * contracts. However, the Timelock itself is deployed with the deployer EOA
 * as `DEFAULT_ADMIN_ROLE`. Unless explicit revocation occurs, the deployer
 * retains ultimate control over the Timelock's role management.
 * * Recommendation:
 * The deployment script MUST include, in a single atomic transaction:
 * 1. Deploy Timelock
 * 2. Deploy governed contracts with Timelock as `initialAdmin`
 * 3. Call `timelock.renounceRole(DEFAULT_ADMIN_ROLE, deployer)`
 * * Validation:
 * Add invariant test confirming `timelock.getRoleMemberCount(DEFAULT_ADMIN_ROLE) == 0`
 * after Phase 6 completion.
 * ============================================================================
 */

// Mock Engine to test the Interception Hook execution
contract MockEngine {
    bool public claimYieldCalled;

    function claimYield(uint256) external {
        claimYieldCalled = true;
    }
}

contract LAWPImpactTokenTest is Test, LAWPErrors {
    LAWPImpactToken public token;
    MockEngine public mockEngine;

    address public admin = address(1);
    address public engineAddress;
    address public userA = address(3);
    address public userB = address(4);

    function setUp() public {
        mockEngine = new MockEngine();
        engineAddress = address(mockEngine);

        token = new LAWPImpactToken(admin, "ipfs://QmMock/");

        vm.prank(admin);
        token.setComplianceEngine(engineAddress);
    }

    function test_Mint_OnlyEngine() public {
        vm.prank(engineAddress);
        uint256 tokenId = token.mint(userA, 9000e18, 2000, 1);

        assertEq(token.ownerOf(tokenId), userA);

        LAWPStructs.TokenData memory data = token.getTokenData(tokenId);
        assertEq(data.netPrincipal, 9000e18);
        assertEq(data.poolShareBPS, 2000);
        assertEq(data.poolId, 1);
        assertEq(data.rocReturned, 0);
        assertEq(token.balanceOf(userA), 1);
    }

    function test_RevertIf_UnauthorizedMint() public {
        vm.prank(userA);
        vm.expectRevert(LAWPComplianceEngine_UnauthorizedCaller.selector);
        token.mint(userA, 9000e18, 2000, 1);
    }

    function test_RevertIf_MintInvalidParameters() public {
        vm.startPrank(engineAddress);

        // Zero Principal
        vm.expectRevert(LAWPImpactToken_InvalidPrincipal.selector);
        token.mint(userA, 0, 2000, 1);

        // Zero BPS
        vm.expectRevert(LAWPImpactToken_InvalidBPS.selector);
        token.mint(userA, 9000e18, 0, 1);

        // Exceeds Max BPS
        vm.expectRevert(LAWPImpactToken_InvalidBPS.selector);
        token.mint(userA, 9000e18, 10001, 1);

        // Invalid Pool ID
        vm.expectRevert(LAWPImpactToken_InvalidPoolId.selector);
        token.mint(userA, 9000e18, 2000, 0);

        vm.stopPrank();
    }

    function test_UpdateRocReturned() public {
        vm.prank(engineAddress);
        uint256 tokenId = token.mint(userA, 9000e18, 2000, 1);

        vm.prank(engineAddress);
        token.updateRocReturned(tokenId, 4500e18);

        LAWPStructs.TokenData memory data = token.getTokenData(tokenId);
        assertEq(data.rocReturned, 4500e18);
    }

    function test_RevertIf_ExceedsPrincipalCap() public {
        vm.prank(engineAddress);
        uint256 tokenId = token.mint(userA, 9000e18, 2000, 1);

        vm.prank(engineAddress);
        vm.expectRevert(LAWPComplianceEngine_ExceedsPrincipalCap.selector);
        token.updateRocReturned(tokenId, 9001e18); // 1 wei over cap
    }

    function test_RevertIf_ConstructorEmptyURI() public {
        vm.expectRevert(LAWPImpactToken_InvalidBaseURI.selector);
        new LAWPImpactToken(admin, "");
    }

    function test_RevertIf_SetBaseURIEmpty() public {
        vm.prank(admin);
        vm.expectRevert(LAWPImpactToken_InvalidBaseURI.selector);
        token.setBaseURI("");
    }

    function test_RevertIf_SetComplianceEngineZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(LAWPImpactToken_ZeroAddress.selector);
        token.setComplianceEngine(address(0));
    }

    function test_TransferInterceptionHook_FiresCorrectly() public {
        vm.prank(engineAddress);
        uint256 tokenId = token.mint(userA, 9000e18, 2000, 1);

        // UserA transfers to UserB
        vm.prank(userA);
        token.transferFrom(userA, userB, tokenId);

        assertEq(token.ownerOf(tokenId), userB);
        // Assert that the Interception Hook forcefully called the Engine's claimYield
        assertTrue(mockEngine.claimYieldCalled());
    }

    function test_RevertIf_RenounceOwnership() public {
        vm.prank(admin);
        vm.expectRevert("LAWPImpactToken: renounceOwnership is disabled");
        token.renounceOwnership();
    }

    function test_TwoStepOwnershipTransfer() public {
        address newAdmin = address(5);

        // Step 1: Admin proposes new owner
        vm.prank(admin);
        token.transferOwnership(newAdmin);

        // Ownership shouldn't change yet
        assertEq(token.owner(), admin);

        // Step 2: New owner accepts
        vm.prank(newAdmin);
        token.acceptOwnership();

        // Ownership is officially transferred
        assertEq(token.owner(), newAdmin);
    }
}
