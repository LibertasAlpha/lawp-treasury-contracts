// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {LAWPFixture} from "../base/LAWPFixture.t.sol";
import {LAWPMultiSigController} from "../../src/core/LAWPMultiSigController.sol";
import {ILAWPMultiSigController} from "../../src/interfaces/ILAWPMultiSigController.sol";
import {LAWPStructs} from "../../src/libraries/LAWPStructs.sol";

contract LAWPMultiSigControllerTest is LAWPFixture {
    uint256 constant POOL_ID = 1;
    uint256 constant WAD = 1e18;

    struct Signer {
        uint256 privateKey;
        address addr;
    }

    Signer[] public board;

    function setUp() public override {
        super.setUp();

        vm.startPrank(governance);
        for (uint256 i = 1; i <= 5; i++) {
            uint256 pk = 0x1000 + i;
            address addr = vm.addr(pk);
            board.push(Signer({privateKey: pk, addr: addr}));
            engine.grantRole(multisig.SIGNER_ROLE(), addr);
        }
        engine.grantRole(engine.OPERATOR_ROLE(), address(multisig));
        vm.stopPrank();

        // Create a pool so it is active
        token.mint(campaignManager, 1000e6);
        vm.startPrank(campaignManager);
        token.approve(address(engine), 1000e6);

        address[] memory c = new address[](1);
        c[0] = alice;
        uint256[] memory w = new uint256[](1);
        w[0] = WAD;

        engine.processPoolDeposit(POOL_ID, 1000e6, c, w);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                            INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    function test_RevertIf_ConstructorZeroAddress() public {
        vm.expectRevert(LAWPMultiSigController.LAWPMultiSigController_ZeroAddress.selector);
        new LAWPMultiSigController(address(0), 3);
    }

    function test_RevertIf_ConstructorInvalidThreshold() public {
        vm.expectRevert(LAWPMultiSigController.LAWPMultiSigController_InvalidThreshold.selector);
        new LAWPMultiSigController(address(engine), 0);
    }

    function test_ConstructorSuccess() public {
        LAWPMultiSigController newMultiSig = new LAWPMultiSigController(address(engine), 3);
        assertEq(address(newMultiSig.engine()), address(engine));
        assertEq(newMultiSig.threshold(), 3);
    }

    /*//////////////////////////////////////////////////////////////
                            THRESHOLD MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    function test_UpdateThreshold_Success() public {
        vm.prank(governance); // governance has GOVERNANCE_ROLE on engine
        vm.expectEmit(true, true, true, true);
        emit ILAWPMultiSigController.ThresholdUpdated(2, 5); // Fixture default is 2
        multisig.updateThreshold(5);

        assertEq(multisig.threshold(), 5);
    }

    function test_RevertIf_UpdateThreshold_Unauthorized() public {
        address unauthorized = makeAddr("unauthorized");
        vm.prank(unauthorized);
        vm.expectRevert(LAWPMultiSigController.LAWPMultiSigController_UnauthorizedCaller.selector);
        multisig.updateThreshold(5);
    }

    function test_RevertIf_UpdateThreshold_Zero() public {
        vm.prank(governance);
        vm.expectRevert(LAWPMultiSigController.LAWPMultiSigController_InvalidThreshold.selector);
        multisig.updateThreshold(0);
    }

    /*//////////////////////////////////////////////////////////////
                            DIGEST & CRYPTOGRAPHY
    //////////////////////////////////////////////////////////////*/

    function test_GetProposalDigest() public {
        uint256 proposalId = 1;
        uint256 amount = 500e6;
        LAWPStructs.FlowType flow = LAWPStructs.FlowType.GRANT_CONTINUOUS;
        uint256 deadline = block.timestamp + 1 hours;

        bytes32 structHash =
            keccak256(abi.encode(multisig.PROPOSAL_TYPEHASH(), proposalId, POOL_ID, amount, uint8(flow), deadline));

        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("LAWP MultiSig")),
                keccak256(bytes("1")),
                block.chainid,
                address(multisig)
            )
        );

        bytes32 expectedDigest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        assertEq(multisig.getProposalDigest(proposalId, POOL_ID, amount, flow, deadline), expectedDigest);
    }

    /*//////////////////////////////////////////////////////////////
                            EXECUTION REVERTS (INPUTS)
    //////////////////////////////////////////////////////////////*/

    function test_RevertIf_ExecuteProposal_Expired() public {
        vm.expectRevert(LAWPMultiSigController.LAWPMultiSigController_Expired.selector);
        multisig.executeProposal(1, POOL_ID, 1000e6, LAWPStructs.FlowType.GRANT_CONTINUOUS, block.timestamp - 1, "");
    }

    function test_RevertIf_ExecuteProposal_InvalidAmount() public {
        vm.expectRevert(LAWPMultiSigController.LAWPMultiSigController_InvalidPayload.selector);
        multisig.executeProposal(1, POOL_ID, 0, LAWPStructs.FlowType.GRANT_CONTINUOUS, block.timestamp + 1 hours, "");
    }

    function test_RevertIf_ExecuteProposal_InvalidPool() public {
        vm.expectRevert(LAWPMultiSigController.LAWPMultiSigController_InvalidPool.selector);
        multisig.executeProposal(1, 999, 1000e6, LAWPStructs.FlowType.GRANT_CONTINUOUS, block.timestamp + 1 hours, "");
    }

    function test_RevertIf_ExecuteProposal_InvalidSignatureLength() public {
        bytes memory sigs = new bytes(64); // Need 65 * threshold (65 * 2 = 130)
        vm.expectRevert(LAWPMultiSigController.LAWPMultiSigController_InvalidSignatureLength.selector);
        multisig.executeProposal(
            1, POOL_ID, 1000e6, LAWPStructs.FlowType.GRANT_CONTINUOUS, block.timestamp + 1 hours, sigs
        );
    }

    /*//////////////////////////////////////////////////////////////
                            EXECUTION REVERTS (CRYPTOGRAPHY)
    //////////////////////////////////////////////////////////////*/

    function test_RevertIf_ExecuteProposal_InvalidSignatures_Garbage() public {
        uint256 amount = 500e6;
        uint256 deadline = block.timestamp + 1 hours;

        // 130 bytes of garbage (2 * 65)
        bytes memory badSigs = new bytes(130);
        for (uint256 i = 0; i < 130; i++) {
            badSigs[i] = 0xAA;
        }

        vm.expectRevert(LAWPMultiSigController.LAWPMultiSigController_InvalidSignatures.selector);
        multisig.executeProposal(1, POOL_ID, amount, LAWPStructs.FlowType.GRANT_CONTINUOUS, deadline, badSigs);
    }

    function test_RevertIf_ExecuteProposal_InvalidSignerOrder() public {
        uint256 amount = 500e6;
        uint256 deadline = block.timestamp + 1 hours;
        LAWPStructs.FlowType flow = LAWPStructs.FlowType.GRANT_CONTINUOUS;

        bytes32 digest = multisig.getProposalDigest(1, POOL_ID, amount, flow, deadline);

        // Get 2 valid signatures but NOT SORTED
        // To guarantee unsorted, we take descending order
        Signer[] memory selected = new Signer[](2);
        selected[0] = board[0];
        selected[1] = board[1];
        _sortSignersDescending(selected); // Custom sort helper

        bytes memory sigs = _generateSignatures(digest, selected);

        vm.expectRevert(LAWPMultiSigController.LAWPMultiSigController_InvalidSignerOrder.selector);
        multisig.executeProposal(1, POOL_ID, amount, flow, deadline, sigs);
    }

    function test_RevertIf_ExecuteProposal_DuplicateSignatures() public {
        uint256 amount = 500e6;
        uint256 deadline = block.timestamp + 1 hours;
        LAWPStructs.FlowType flow = LAWPStructs.FlowType.GRANT_CONTINUOUS;

        bytes32 digest = multisig.getProposalDigest(1, POOL_ID, amount, flow, deadline);

        // 2 signatures, but two are the same signer
        Signer[] memory selected = new Signer[](2);
        selected[0] = board[0];
        selected[1] = board[0]; // Duplicate

        // Even if sorted (which they are natively since 0 == 0), the condition current <= last will trip
        bytes memory sigs = _generateSignatures(digest, selected);

        vm.expectRevert(LAWPMultiSigController.LAWPMultiSigController_InvalidSignerOrder.selector);
        multisig.executeProposal(1, POOL_ID, amount, flow, deadline, sigs);
    }

    function test_RevertIf_ExecuteProposal_UnauthorizedSigner() public {
        uint256 amount = 500e6;
        uint256 deadline = block.timestamp + 1 hours;
        LAWPStructs.FlowType flow = LAWPStructs.FlowType.GRANT_CONTINUOUS;

        bytes32 digest = multisig.getProposalDigest(1, POOL_ID, amount, flow, deadline);

        // Include hacker in the signers
        Signer[] memory selected = new Signer[](2);
        selected[0] = board[0];

        uint256 hackerPk = 0xBADDAD;
        address hackerAddr = vm.addr(hackerPk);
        selected[1] = Signer(hackerPk, hackerAddr);

        _sortSignersAscending(selected);

        bytes memory sigs = _generateSignatures(digest, selected);

        vm.expectRevert(LAWPMultiSigController.LAWPMultiSigController_InvalidSignatures.selector);
        multisig.executeProposal(1, POOL_ID, amount, flow, deadline, sigs);
    }

    function test_RevertIf_ExecuteProposal_MalleableSignature() public {
        uint256 amount = 500e6;
        uint256 deadline = block.timestamp + 1 hours;
        LAWPStructs.FlowType flow = LAWPStructs.FlowType.GRANT_CONTINUOUS;

        bytes32 digest = multisig.getProposalDigest(1, POOL_ID, amount, flow, deadline);

        Signer[] memory selected = new Signer[](2);
        selected[0] = board[0];
        selected[1] = board[1];
        _sortSignersAscending(selected);

        // Generate normally
        bytes memory sigs = _generateSignatures(digest, selected);

        {
            uint256 n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
            uint256 originalS;
            assembly { originalS := mload(add(sigs, 64)) }
            uint256 malleableS = n - originalS;
            assembly { mstore(add(sigs, 64), malleableS) }

            uint8 originalV;
            assembly { originalV := byte(0, mload(add(sigs, 96))) }
            uint8 flippedV = originalV == 27 ? 28 : 27;
            sigs[64] = bytes1(flippedV);
        }

        vm.expectRevert(LAWPMultiSigController.LAWPMultiSigController_InvalidSignatures.selector);
        multisig.executeProposal(1, POOL_ID, amount, flow, deadline, sigs);
    }

    function test_ExecuteProposal_HardwareWalletV_Success() public {
        uint256 proposalId = 100;
        uint256 amount = 500e6;
        uint256 deadline = block.timestamp + 1 hours;
        LAWPStructs.FlowType flow = LAWPStructs.FlowType.GRANT_CONTINUOUS;

        bytes32 digest = multisig.getProposalDigest(proposalId, POOL_ID, amount, flow, deadline);

        Signer[] memory selected = new Signer[](2);
        selected[0] = board[0];
        selected[1] = board[1];
        _sortSignersAscending(selected);

        bytes memory sigs = _generateSignatures(digest, selected);

        // Hardware wallets output v as 0 or 1 instead of 27 or 28.
        // We will subtract 27 from the v value in our signatures to simulate this.
        for (uint256 i = 0; i < selected.length; i++) {
            uint256 offset = (i * 65) + 64;
            uint8 currentV;
            assembly { currentV := byte(0, mload(add(sigs, add(32, offset)))) }
            if (currentV >= 27) {
                sigs[offset] = bytes1(currentV - 27);
            }
        }

        token.mint(operator, amount);
        vm.startPrank(operator);
        token.approve(address(engine), amount);

        multisig.executeProposal(proposalId, POOL_ID, amount, flow, deadline, sigs);
        vm.stopPrank();

        assertTrue(multisig.executedProposals(digest));
    }

    /*//////////////////////////////////////////////////////////////
                            SUCCESSFUL EXECUTION
    //////////////////////////////////////////////////////////////*/

    function test_ExecuteProposal_Success() public {
        uint256 proposalId = 42;
        uint256 amount = 500e6;
        uint256 deadline = block.timestamp + 1 hours;
        LAWPStructs.FlowType flow = LAWPStructs.FlowType.GRANT_CONTINUOUS;

        bytes32 digest = multisig.getProposalDigest(proposalId, POOL_ID, amount, flow, deadline);

        Signer[] memory selected = new Signer[](2);
        selected[0] = board[0];
        selected[1] = board[1];
        _sortSignersAscending(selected);

        bytes memory sigs = _generateSignatures(digest, selected);

        // The relayer must hold the tokens and approve the engine
        token.mint(operator, amount);
        vm.startPrank(operator);
        token.approve(address(engine), amount);

        vm.expectEmit(true, true, true, true);
        emit ILAWPMultiSigController.ProposalExecuted(digest, proposalId, POOL_ID, amount, flow);
        multisig.executeProposal(proposalId, POOL_ID, amount, flow, deadline, sigs);
        vm.stopPrank();

        // Check it was marked as executed
        assertTrue(multisig.executedProposals(digest));
    }

    function test_RevertIf_ExecuteProposal_AlreadyExecuted() public {
        uint256 proposalId = 42;
        uint256 amount = 500e6;
        uint256 deadline = block.timestamp + 1 hours;
        LAWPStructs.FlowType flow = LAWPStructs.FlowType.GRANT_CONTINUOUS;

        bytes32 digest = multisig.getProposalDigest(proposalId, POOL_ID, amount, flow, deadline);

        Signer[] memory selected = new Signer[](2);
        selected[0] = board[0];
        selected[1] = board[1];
        _sortSignersAscending(selected);

        bytes memory sigs = _generateSignatures(digest, selected);

        token.mint(operator, amount * 2);
        vm.startPrank(operator);
        token.approve(address(engine), amount * 2);

        multisig.executeProposal(proposalId, POOL_ID, amount, flow, deadline, sigs);

        // Try again (replay attack)
        vm.expectRevert(LAWPMultiSigController.LAWPMultiSigController_ProposalAlreadyExecuted.selector);
        multisig.executeProposal(proposalId, POOL_ID, amount, flow, deadline, sigs);

        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                            HELPERS
    //////////////////////////////////////////////////////////////*/

    function _generateSignatures(bytes32 digest, Signer[] memory signers) internal pure returns (bytes memory) {
        bytes memory sigs = new bytes(signers.length * 65);
        for (uint256 i = 0; i < signers.length; i++) {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(signers[i].privateKey, digest);

            // Encode r, s, v into the `sigs` byte array
            uint256 offset = i * 65;

            assembly {
                let sigData := add(sigs, add(32, offset))
                mstore(sigData, r)
                mstore(add(sigData, 32), s)
            }
            // Add v at the 64th byte offset
            sigs[offset + 64] = bytes1(v);
        }
        return sigs;
    }

    function _sortSignersAscending(Signer[] memory arr) internal pure {
        uint256 l = arr.length;
        for (uint256 i = 0; i < l; i++) {
            for (uint256 j = i + 1; j < l; j++) {
                if (uint160(arr[i].addr) > uint160(arr[j].addr)) {
                    Signer memory temp = arr[i];
                    arr[i] = arr[j];
                    arr[j] = temp;
                }
            }
        }
    }

    function _sortSignersDescending(Signer[] memory arr) internal pure {
        uint256 l = arr.length;
        for (uint256 i = 0; i < l; i++) {
            for (uint256 j = i + 1; j < l; j++) {
                if (uint160(arr[i].addr) < uint160(arr[j].addr)) {
                    Signer memory temp = arr[i];
                    arr[i] = arr[j];
                    arr[j] = temp;
                }
            }
        }
    }
}
