// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { LAWPTestBase } from "../base/LAWPTestBase.sol";
import { LAWPMultiSigController } from "../../src/core/LAWPMultiSigController.sol";
import { LAWPStructs } from "../../src/libraries/LAWPStructs.sol";

/// @title LAWPMultiSigControllerTest
/// @notice Unit tests for the EIP-712 multi-sig proposal controller.
/// @dev Tests: construction, board management, EIP-712 proposal digest, signature
///      verification (ordering, malleability, duplicates), replay protection, and
///      the updated fund-provider flow where the RELAYER is the ERC20 source.
contract LAWPMultiSigControllerTest is LAWPTestBase {
    LAWPMultiSigController public controller;

    // EOA signers (private keys deterministic for testing)
    uint256 internal pk1 = 0x1001;
    uint256 internal pk2 = 0x1002;
    uint256 internal pk3 = 0x1003;
    uint256 internal pk4 = 0x1004;
    uint256 internal pk5 = 0x1005;

    address internal s1;
    address internal s2;
    address internal s3;
    address internal s4;
    address internal s5;

    // The relayer who will submit executeProposal
    uint256 internal relayerPk = 0xBEEF;
    address internal relayer;

    uint256 internal constant THRESHOLD = 3;

    function setUp() public override {
        super.setUp();

        s1 = vm.addr(pk1);
        s2 = vm.addr(pk2);
        s3 = vm.addr(pk3);
        s4 = vm.addr(pk4);
        s5 = vm.addr(pk5);
        relayer = vm.addr(relayerPk);

        // Sort signers ascending for strict ordering requirement
        // s1 < s2 < s3 < s4 < s5 is assumed; vm.addr is deterministic
        address[] memory signers = new address[](5);
        signers[0] = s1;
        signers[1] = s2;
        signers[2] = s3;
        signers[3] = s4;
        signers[4] = s5;

        controller = new LAWPMultiSigController(admin, address(engine), signers, THRESHOLD);

        // Wire the real controller as the authorized multiSig
        vm.prank(admin);
        engine.setMultiSigController(address(controller));

        // Relayer is the fund provider - approves ENGINE directly
        cngn.mintTest(relayer, 10_000_000e6);
        vm.prank(relayer);
        cngn.approve(address(engine), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                         CONSTRUCTOR TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Constructor_SetsState() public view {
        assertEq(address(controller.engine()), address(engine));
        assertEq(controller.threshold(), THRESHOLD);
        assertEq(controller.signerCount(), 5);
        assertTrue(controller.isSigner(s1));
        assertTrue(controller.isSigner(s2));
        assertTrue(controller.isSigner(s3));
    }

    function test_Constructor_RevertIf_ZeroEngine() public {
        address[] memory signers = new address[](1);
        signers[0] = s1;
        vm.expectRevert(LAWPMultiSigController.LAWPMultiSigController_ZeroAddress.selector);
        new LAWPMultiSigController(admin, address(0), signers, 1);
    }

    function test_Constructor_RevertIf_EmptySigners() public {
        address[] memory signers = new address[](0);
        vm.expectRevert(LAWPMultiSigController.LAWPMultiSigController_InvalidThreshold.selector);
        new LAWPMultiSigController(admin, address(engine), signers, 1);
    }

    function test_Constructor_RevertIf_ThresholdExceedsSigners() public {
        address[] memory signers = new address[](2);
        signers[0] = s1;
        signers[1] = s2;
        vm.expectRevert(LAWPMultiSigController.LAWPMultiSigController_InvalidThreshold.selector);
        new LAWPMultiSigController(admin, address(engine), signers, 3);
    }

    function test_Constructor_RevertIf_TooManySigners() public {
        address[] memory signers = new address[](21);
        for (uint160 i = 0; i < 21; i++) {
            signers[i] = address(i + 100);
        }
        vm.expectRevert(LAWPMultiSigController.LAWPMultiSigController_TooManySigners.selector);
        new LAWPMultiSigController(admin, address(engine), signers, 3);
    }

    function test_Constructor_RevertIf_DuplicateSigner() public {
        address[] memory signers = new address[](2);
        signers[0] = s1;
        signers[1] = s1; // duplicate
        vm.expectRevert(LAWPMultiSigController.LAWPMultiSigController_InvalidSignatures.selector);
        new LAWPMultiSigController(admin, address(engine), signers, 1);
    }

    function test_Constructor_RevertIf_ZeroAddressSigner() public {
        address[] memory signers = new address[](2);
        signers[0] = address(0);
        signers[1] = s1;
        vm.expectRevert(LAWPMultiSigController.LAWPMultiSigController_InvalidSignatures.selector);
        new LAWPMultiSigController(admin, address(engine), signers, 1);
    }

    /*//////////////////////////////////////////////////////////////
                         BOARD MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    function test_AddSigner_Success() public {
        address newSigner = address(77);
        vm.prank(admin);
        controller.addSigner(newSigner);
        assertTrue(controller.isSigner(newSigner));
        assertEq(controller.signerCount(), 6);
    }

    function test_AddSigner_RevertIf_ZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(LAWPMultiSigController.LAWPMultiSigController_ZeroAddress.selector);
        controller.addSigner(address(0));
    }

    function test_AddSigner_RevertIf_AlreadyExists() public {
        vm.prank(admin);
        vm.expectRevert(LAWPMultiSigController.LAWPMultiSigController_SignerAlreadyExists.selector);
        controller.addSigner(s1);
    }

    function test_AddSigner_RevertIf_NotOwner() public {
        vm.prank(attacker);
        vm.expectRevert();
        controller.addSigner(address(77));
    }

    function test_RemoveSigner_Success() public {
        vm.prank(admin);
        controller.removeSigner(s5); // Keep 4, threshold=3 - safe
        assertFalse(controller.isSigner(s5));
        assertEq(controller.signerCount(), 4);
    }

    function test_RemoveSigner_RevertIf_DropsBelowThreshold() public {
        // Remove s4 and s5 to reach signerCount=3=threshold
        vm.startPrank(admin);
        controller.removeSigner(s5);
        controller.removeSigner(s4);
        // Now removing s3 would drop count to 2 < threshold=3
        vm.expectRevert(LAWPMultiSigController.LAWPMultiSigController_InvalidThreshold.selector);
        controller.removeSigner(s3);
        vm.stopPrank();
    }

    function test_RemoveSigner_RevertIf_NotASigner() public {
        vm.prank(admin);
        vm.expectRevert(LAWPMultiSigController.LAWPMultiSigController_NotASigner.selector);
        controller.removeSigner(address(99));
    }

    function test_UpdateThreshold_Success() public {
        vm.prank(admin);
        controller.updateThreshold(5);
        assertEq(controller.threshold(), 5);
    }

    function test_UpdateThreshold_RevertIf_ExceedsSigners() public {
        vm.prank(admin);
        vm.expectRevert(LAWPMultiSigController.LAWPMultiSigController_InvalidThreshold.selector);
        controller.updateThreshold(6);
    }

    function test_UpdateThreshold_RevertIf_Zero() public {
        vm.prank(admin);
        vm.expectRevert(LAWPMultiSigController.LAWPMultiSigController_InvalidThreshold.selector);
        controller.updateThreshold(0);
    }

    function test_RenounceOwnership_IsDisabled() public {
        vm.prank(admin);
        vm.expectRevert("LAWPMultiSigController: renounceOwnership is disabled");
        controller.renounceOwnership();
    }

    /*//////////////////////////////////////////////////////////////
                         EIP-712 PROPOSAL DIGEST
    //////////////////////////////////////////////////////////////*/

    function test_GetProposalDigest_IsDeterministic() public view {
        bytes32 d1 = controller.getProposalDigest(1, 1, 10_000e6, LAWPStructs.FlowType.RoC, 9999);
        bytes32 d2 = controller.getProposalDigest(1, 1, 10_000e6, LAWPStructs.FlowType.RoC, 9999);
        assertEq(d1, d2);
    }

    function test_GetProposalDigest_DifferentForDifferentPayloads() public view {
        bytes32 d1 = controller.getProposalDigest(1, 1, 10_000e6, LAWPStructs.FlowType.RoC, 9999);
        bytes32 d2 = controller.getProposalDigest(2, 1, 10_000e6, LAWPStructs.FlowType.RoC, 9999);
        bytes32 d3 = controller.getProposalDigest(1, 2, 10_000e6, LAWPStructs.FlowType.RoC, 9999);
        assertTrue(d1 != d2, "Different proposalId must yield different digest");
        assertTrue(d1 != d3, "Different poolId must yield different digest");
    }

    /*//////////////////////////////////////////////////////////////
                      EXECUTE PROPOSAL TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Builds a packed 65-byte-per-signature calldata blob from a set of signers.
    ///         Signers MUST be provided in ascending address order.
    function _buildSignatures(bytes32 digest, uint256[] memory pks)
        internal
        pure
        returns (bytes memory)
    {
        bytes memory sigs;
        for (uint256 i = 0; i < pks.length; i++) {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(pks[i], digest);
            sigs = abi.encodePacked(sigs, r, s, v);
        }
        return sigs;
    }

    function _sortSignersByAddress(uint256[3] memory pks)
        internal
        pure
        returns (uint256[] memory sorted)
    {
        // Bubble sort 3 elements by derived address
        address[3] memory addrs;
        for (uint256 i = 0; i < 3; i++) {
            addrs[i] = vm.addr(pks[i]);
        }
        for (uint256 i = 0; i < 2; i++) {
            for (uint256 j = i + 1; j < 3; j++) {
                if (uint160(addrs[i]) > uint160(addrs[j])) {
                    (addrs[i], addrs[j]) = (addrs[j], addrs[i]);
                    (pks[i], pks[j]) = (pks[j], pks[i]);
                }
            }
        }
        sorted = new uint256[](3);
        for (uint256 i = 0; i < 3; i++) {
            sorted[i] = pks[i];
        }
    }

    function test_ExecuteProposal_RoC_Success() public {
        // Setup deposit first
        _setupStandardDeposit();

        uint256 amount = 10_000e6;
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest =
            controller.getProposalDigest(1, 1, amount, LAWPStructs.FlowType.RoC, deadline);

        // Sort signers ascending by address
        uint256[3] memory unsorted = [pk1, pk2, pk3];
        uint256[] memory sortedPks = _sortSignersByAddress(unsorted);
        bytes memory sigs = _buildSignatures(digest, sortedPks);

        uint256 yieldBefore = cngn.balanceOf(address(yieldVault));

        // Relayer submits and is the fund provider
        vm.prank(relayer);
        controller.executeProposal(1, 1, amount, LAWPStructs.FlowType.RoC, deadline, sigs);

        assertEq(engine.poolRocTracker(1), amount);
        assertEq(cngn.balanceOf(address(yieldVault)), yieldBefore + amount);
        assertEq(cngn.balanceOf(address(controller)), 0, "Controller holds zero cNGN");
        assertTrue(controller.executedProposals(digest));
    }

    function test_ExecuteProposal_RevertIf_AlreadyExecuted() public {
        _setupStandardDeposit();
        uint256 amount = 10_000e6;
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest =
            controller.getProposalDigest(1, 1, amount, LAWPStructs.FlowType.RoC, deadline);

        uint256[3] memory unsorted = [pk1, pk2, pk3];
        uint256[] memory sortedPks = _sortSignersByAddress(unsorted);
        bytes memory sigs = _buildSignatures(digest, sortedPks);

        vm.prank(relayer);
        controller.executeProposal(1, 1, amount, LAWPStructs.FlowType.RoC, deadline, sigs);

        vm.prank(relayer);
        vm.expectRevert(
            LAWPMultiSigController.LAWPMultiSigController_ProposalAlreadyExecuted.selector
        );
        controller.executeProposal(1, 1, amount, LAWPStructs.FlowType.RoC, deadline, sigs);
    }

    function test_ExecuteProposal_RevertIf_Expired() public {
        uint256 amount = 10_000e6;
        uint256 deadline = block.timestamp - 1; // Already expired
        bytes32 digest =
            controller.getProposalDigest(1, 1, amount, LAWPStructs.FlowType.RoC, deadline);

        uint256[3] memory unsorted = [pk1, pk2, pk3];
        uint256[] memory sortedPks = _sortSignersByAddress(unsorted);
        bytes memory sigs = _buildSignatures(digest, sortedPks);

        vm.prank(relayer);
        vm.expectRevert(LAWPMultiSigController.LAWPMultiSigController_Expired.selector);
        controller.executeProposal(1, 1, amount, LAWPStructs.FlowType.RoC, deadline, sigs);
    }

    function test_ExecuteProposal_RevertIf_ZeroAmount() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = controller.getProposalDigest(1, 1, 0, LAWPStructs.FlowType.RoC, deadline);
        uint256[3] memory unsorted = [pk1, pk2, pk3];
        uint256[] memory sortedPks = _sortSignersByAddress(unsorted);
        bytes memory sigs = _buildSignatures(digest, sortedPks);

        vm.prank(relayer);
        vm.expectRevert(LAWPMultiSigController.LAWPMultiSigController_InvalidPayload.selector);
        controller.executeProposal(1, 1, 0, LAWPStructs.FlowType.RoC, deadline, sigs);
    }

    function test_ExecuteProposal_RevertIf_WrongSignatureLength() public {
        _setupStandardDeposit();

        uint256 deadline = block.timestamp + 1 hours;
        // Only 2 sigs for a threshold-3 controller (wrong: 2*65 vs 3*65)
        bytes memory sigs = new bytes(130); // 2 * 65

        vm.prank(relayer);
        vm.expectRevert(
            LAWPMultiSigController.LAWPMultiSigController_InvalidSignatureLength.selector
        );
        controller.executeProposal(1, 1, 10_000e6, LAWPStructs.FlowType.RoC, deadline, sigs);
    }

    function test_ExecuteProposal_RevertIf_NonSigner() public {
        _setupStandardDeposit();

        uint256 amount = 10_000e6;
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest =
            controller.getProposalDigest(1, 1, amount, LAWPStructs.FlowType.RoC, deadline);

        // pk4 not in this set but included to replace pk3
        uint256 outsiderPk = 0xDEAD; // Not a signer
        uint256[3] memory unsorted = [pk1, pk2, outsiderPk];
        uint256[] memory sortedPks = _sortSignersByAddress(unsorted);
        bytes memory sigs = _buildSignatures(digest, sortedPks);

        vm.prank(relayer);
        vm.expectRevert(LAWPMultiSigController.LAWPMultiSigController_InvalidSignatures.selector);
        controller.executeProposal(1, 1, amount, LAWPStructs.FlowType.RoC, deadline, sigs);
    }

    function test_ExecuteProposal_RevertIf_UnorderedSigners() public {
        _setupStandardDeposit();

        uint256 amount = 10_000e6;
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest =
            controller.getProposalDigest(1, 1, amount, LAWPStructs.FlowType.RoC, deadline);

        // Deliberately use DESCENDING order (wrong)
        // Build manually: sort descending
        address[3] memory addrs = [s1, s2, s3];
        uint256[3] memory pks = [pk1, pk2, pk3];
        // Sort descending by address
        for (uint256 i = 0; i < 2; i++) {
            for (uint256 j = i + 1; j < 3; j++) {
                if (uint160(addrs[i]) < uint160(addrs[j])) {
                    (addrs[i], addrs[j]) = (addrs[j], addrs[i]);
                    (pks[i], pks[j]) = (pks[j], pks[i]);
                }
            }
        }
        bytes memory sigs;
        for (uint256 i = 0; i < 3; i++) {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(pks[i], digest);
            sigs = abi.encodePacked(sigs, r, s, v);
        }

        vm.prank(relayer);
        vm.expectRevert(LAWPMultiSigController.LAWPMultiSigController_InvalidSignerOrder.selector);
        controller.executeProposal(1, 1, amount, LAWPStructs.FlowType.RoC, deadline, sigs);
    }

    function test_ExecuteProposal_RevertIf_DuplicateSigners() public {
        _setupStandardDeposit();

        uint256 amount = 10_000e6;
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest =
            controller.getProposalDigest(1, 1, amount, LAWPStructs.FlowType.RoC, deadline);

        // Use s1 twice (a, a, b) - must revert on ordering check
        (uint8 v1, bytes32 r1, bytes32 s1_sig) = vm.sign(pk1, digest);
        (uint8 v2, bytes32 r2, bytes32 s2_sig) = vm.sign(pk2, digest);
        bytes memory sigs = abi.encodePacked(
            r1,
            s1_sig,
            v1,
            r1,
            s1_sig,
            v1, // duplicate
            r2,
            s2_sig,
            v2
        );

        vm.prank(relayer);
        vm.expectRevert(LAWPMultiSigController.LAWPMultiSigController_InvalidSignerOrder.selector);
        controller.executeProposal(1, 1, amount, LAWPStructs.FlowType.RoC, deadline, sigs);
    }

    function test_ExecuteProposal_RelayerIsPermissionless() public {
        // Any address can be relayer and can submit valid signatures - execution is permissionless
        // But relayer must be the fund provider in the new flow, so they must have cNGN and approve ENGINE first
        _setupStandardDeposit();
        address randomRelayer = address(555);
        cngn.mintTest(randomRelayer, 100_000e6);
        vm.prank(randomRelayer);
        cngn.approve(address(engine), type(uint256).max);

        uint256 amount = 5_000e6;
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest =
            controller.getProposalDigest(1, 1, amount, LAWPStructs.FlowType.RoC, deadline);

        uint256[3] memory unsorted = [pk1, pk2, pk3];
        uint256[] memory sortedPks = _sortSignersByAddress(unsorted);
        bytes memory sigs = _buildSignatures(digest, sortedPks);

        vm.prank(randomRelayer);
        // Relayer submits and is the fund provider
        controller.executeProposal(1, 1, amount, LAWPStructs.FlowType.RoC, deadline, sigs);

        assertEq(engine.poolRocTracker(1), amount);
        assertEq(cngn.balanceOf(address(controller)), 0);
    }

    function test_CrossPayloadReplay_DifferentProposalId_Blocked() public {
        _setupStandardDeposit();
        uint256 amount = 10_000e6;
        uint256 deadline = block.timestamp + 1 hours;

        bytes32 digest1 =
            controller.getProposalDigest(1, 1, amount, LAWPStructs.FlowType.RoC, deadline);
        bytes32 digest2 =
            controller.getProposalDigest(2, 1, amount, LAWPStructs.FlowType.RoC, deadline);

        // The two digests must differ
        assertTrue(digest1 != digest2, "Same payload/different proposalId must yield unique digest");

        // Execute proposal 1 successfully
        uint256[3] memory unsorted = [pk1, pk2, pk3];
        uint256[] memory sortedPks = _sortSignersByAddress(unsorted);
        bytes memory sigs1 = _buildSignatures(digest1, sortedPks);

        vm.prank(relayer);
        controller.executeProposal(1, 1, amount, LAWPStructs.FlowType.RoC, deadline, sigs1);

        // Replay with proposal 2 (different id, same payload): different digest → not blocked
        // But pool 1 RoC can be routed again as a new proposal
        cngn.mintTest(relayer, amount); // top up for second routing
        bytes memory sigs2 = _buildSignatures(digest2, sortedPks);

        vm.prank(relayer);
        controller.executeProposal(2, 1, amount, LAWPStructs.FlowType.RoC, deadline, sigs2);

        assertEq(engine.poolRocTracker(1), amount * 2);
    }
}
