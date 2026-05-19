// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// import { Test } from "forge-std/Test.sol";
// import { LAWPMultiSigController } from "../../src/core/LAWPMultiSigController.sol";
// import { LAWPComplianceEngine } from "../../src/core/LAWPComplianceEngine.sol";
// import { LAWPTreasury } from "../../src/core/LAWPTreasury.sol";
// import { LAWPImpactToken } from "../../src/core/LAWPImpactToken.sol";
// import { LAWPActorRegistry } from "../../src/core/LAWPActorRegistry.sol";
// import { MockCngn3, MockAdminOperations } from "../mocks/MockCngn3.sol";
// import { LAWPStructs } from "../../src/libraries/LAWPStructs.sol";
// import { LAWPErrors } from "../../src/libraries/LAWPErrors.sol";

// contract LAWPMultiSigControllerTest is Test, LAWPErrors {
//     LAWPMultiSigController public controller;

//     // Real Ecosystem Integration
//     LAWPComplianceEngine public engine;
//     LAWPTreasury public treasury;
//     LAWPImpactToken public impactToken;
//     LAWPActorRegistry public registry;
//     MockCngn3 public cngn;
//     MockAdminOperations public adminOps;

//     address public admin = address(1);

//     // Operational Wallets
//     address public la2Wallet = address(11);
//     address public mvi1Wallet = address(12);
//     address public riskPoolWallet = address(13);
//     address public devWallet = address(14);

//     // Signer Private Keys
//     uint256 public pk1 = 0xA11CE;
//     uint256 public pk2 = 0xB0B;
//     uint256 public pk3 = 0xCAFE;

//     address public signer1;
//     address public signer2;
//     address public signer3;

//     function setUp() public {
//         signer1 = vm.addr(pk1);
//         signer2 = vm.addr(pk2);
//         signer3 = vm.addr(pk3);

//         // 1. Deploy Core Dependencies
//         adminOps = new MockAdminOperations();
//         cngn = new MockCngn3(address(adminOps));

//         registry = new LAWPActorRegistry(admin);
//         treasury = new LAWPTreasury(address(cngn), admin);
//         impactToken = new LAWPImpactToken(admin, "ipfs://base/");

//         // 2. Configure Actor Registry
//         vm.startPrank(admin);
//         registry.setLA2Wallet(la2Wallet);
//         registry.setMVI1Wallet(mvi1Wallet);
//         registry.setRiskPoolWallet(riskPoolWallet);
//         registry.setDevWallet(devWallet);
//         vm.stopPrank();

//         // 3. Deploy the Real Engine
//         engine = new LAWPComplianceEngine(
//             admin,
//             address(treasury),
//             address(impactToken),
//             address(registry),
//             address(cngn),
//             1000 // 10% Risk Fee
//         );

//         // 4. Deploy the Controller linked to the Real Engine
//         address[] memory initialSigners = new address[](3);
//         initialSigners[0] = signer1;
//         initialSigners[1] = signer2;
//         initialSigners[2] = signer3;

//         controller = new LAWPMultiSigController(
//             admin,
//             address(engine),
//             initialSigners,
//             2 // Threshold of 2
//         );

//         // 5. Finalize Linkages (Trust Boundaries)
//         vm.startPrank(admin);
//         engine.setMultiSigController(address(controller));
//         treasury.setComplianceEngine(address(engine));
//         impactToken.setComplianceEngine(address(engine));
//         vm.stopPrank();

//         // 6. Seed Treasury with Tokens so the Engine can successfully route execution funds
//         cngn.mintTest(address(treasury), 1_000_000e6);
//     }

//     /*//////////////////////////////////////////////////////////////
//                            CONSTRUCTOR TESTS
//     //////////////////////////////////////////////////////////////*/

//     function test_Constructor_RevertIf_ZeroEngine() public {
//         address[] memory signers = new address[](1);
//         signers[0] = signer1;
//         vm.expectRevert(LAWPMultiSigController_ZeroAddress.selector);
//         new LAWPMultiSigController(admin, address(0), signers, 1);
//     }

//     function test_Constructor_RevertIf_InvalidThreshold() public {
//         address[] memory signers = new address[](2);
//         signers[0] = signer1;
//         signers[1] = signer2;

//         // Threshold 0
//         vm.expectRevert(LAWPMultiSigController_InvalidThreshold.selector);
//         new LAWPMultiSigController(admin, address(engine), signers, 0);

//         // Threshold > length
//         vm.expectRevert(LAWPMultiSigController_InvalidThreshold.selector);
//         new LAWPMultiSigController(admin, address(engine), signers, 3);

//         // Empty signers array
//         address[] memory emptySigners = new address[](0);
//         vm.expectRevert(LAWPMultiSigController_InvalidThreshold.selector);
//         new LAWPMultiSigController(admin, address(engine), emptySigners, 1);
//     }

//     function test_Constructor_RevertIf_TooManySigners() public {
//         address[] memory manySigners = new address[](21); // Max is 20
//         for (uint256 i = 0; i < 21; i++) {
//             manySigners[i] = address(uint160(100 + i));
//         }
//         vm.expectRevert(LAWPMultiSigController_TooManySigners.selector);
//         new LAWPMultiSigController(admin, address(engine), manySigners, 2);
//     }

//     function test_Constructor_RevertIf_InvalidSignerOrDuplicate() public {
//         address[] memory signers = new address[](2);
//         signers[0] = signer1;
//         signers[1] = address(0);

//         vm.expectRevert(LAWPMultiSigController_InvalidSignatures.selector);
//         new LAWPMultiSigController(admin, address(engine), signers, 2);

//         signers[1] = signer1; // Duplicate
//         vm.expectRevert(LAWPMultiSigController_InvalidSignatures.selector);
//         new LAWPMultiSigController(admin, address(engine), signers, 2);
//     }

//     /*//////////////////////////////////////////////////////////////
//                            ADMINISTRATION TESTS
//     //////////////////////////////////////////////////////////////*/

//     function test_RenounceOwnership_Reverts() public {
//         vm.prank(admin);
//         vm.expectRevert("LAWPMultiSigController: renounceOwnership is disabled");
//         controller.renounceOwnership();
//     }

//     function test_AddSigner() public {
//         address newSigner = address(0x999);
//         vm.prank(admin);
//         controller.addSigner(newSigner);
//         assertTrue(controller.isSigner(newSigner));
//         assertEq(controller.signerCount(), 4);
//     }

//     function test_AddSigner_Reverts() public {
//         vm.startPrank(admin);
//         vm.expectRevert(LAWPMultiSigController_ZeroAddress.selector);
//         controller.addSigner(address(0));

//         vm.expectRevert(LAWPMultiSigController_SignerAlreadyExists.selector);
//         controller.addSigner(signer1);
//         vm.stopPrank();

//         // Test MAX_SIGNERS
//         address[] memory manySigners = new address[](20);
//         for (uint256 i = 0; i < 20; i++) {
//             manySigners[i] = address(uint160(100 + i));
//         }
//         LAWPMultiSigController hugeController =
//             new LAWPMultiSigController(admin, address(engine), manySigners, 2);

//         vm.prank(admin);
//         vm.expectRevert(LAWPMultiSigController_TooManySigners.selector);
//         hugeController.addSigner(address(0x999));
//     }

//     function test_RemoveSigner() public {
//         vm.prank(admin);
//         controller.removeSigner(signer3);
//         assertFalse(controller.isSigner(signer3));
//         assertEq(controller.signerCount(), 2);
//     }

//     function test_RemoveSigner_Reverts() public {
//         vm.startPrank(admin);
//         vm.expectRevert(LAWPMultiSigController_NotASigner.selector);
//         controller.removeSigner(address(0x999));

//         // Dropping below threshold
//         controller.removeSigner(signer3);
//         vm.expectRevert(LAWPMultiSigController_InvalidThreshold.selector);
//         controller.removeSigner(signer2); // Would drop to 1 (threshold is 2)
//         vm.stopPrank();
//     }

//     function test_UpdateThreshold() public {
//         vm.prank(admin);
//         controller.updateThreshold(3);
//         assertEq(controller.threshold(), 3);
//     }

//     function test_UpdateThreshold_Reverts() public {
//         vm.startPrank(admin);
//         vm.expectRevert(LAWPMultiSigController_InvalidThreshold.selector);
//         controller.updateThreshold(0);

//         vm.expectRevert(LAWPMultiSigController_InvalidThreshold.selector);
//         controller.updateThreshold(4); // Greater than signerCount (3)
//         vm.stopPrank();
//     }

//     /*//////////////////////////////////////////////////////////////
//                            EXECUTION TESTS
//     //////////////////////////////////////////////////////////////*/

//     function _getSortedSignatures(uint256 _pkA, uint256 _pkB, bytes32 _digest)
//         internal
//         pure
//         returns (bytes memory)
//     {
//         address addrA = vm.addr(_pkA);
//         address addrB = vm.addr(_pkB);

//         uint256 firstPk = addrA < addrB ? _pkA : _pkB;
//         uint256 secondPk = addrA < addrB ? _pkB : _pkA;

//         (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(firstPk, _digest);
//         (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(secondPk, _digest);

//         return abi.encodePacked(r1, s1, v1, r2, s2, v2);
//     }

//     function test_ExecuteProposal_Success() public {
//         uint256 proposalId = 1;
//         uint256 poolId = 1;
//         uint256 amount = 100_000e6;
//         LAWPStructs.FlowType flow = LAWPStructs.FlowType.GRANT_INITIAL;
//         uint256 deadline = block.timestamp + 1 hours;

//         bytes32 digest = controller.getProposalDigest(proposalId, poolId, amount, flow, deadline);
//         bytes memory sigs = _getSortedSignatures(pk1, pk2, digest);

//         uint256 la2BalBefore = cngn.balanceOf(la2Wallet);

//         controller.executeProposal(proposalId, poolId, amount, flow, deadline, sigs);

//         assertTrue(controller.executedProposals(digest));

//         // INTEGRATION CHECK: Verify the Engine successfully pulled funds from the Treasury
//         // For GRANT_INITIAL (100,000e6): 50% goes to LA2 (50,000e6), 30% to Collective Yield Tracker
//         assertEq(cngn.balanceOf(la2Wallet), la2BalBefore + 50_000e6);
//         assertEq(engine.poolYieldTracker(poolId), 30_000e6);
//     }

//     function test_ExecuteProposal_RevertIf_Expired() public {
//         uint256 deadline = block.timestamp - 1; // Expired
//         vm.expectRevert(LAWPMultiSigController_Expired.selector);
//         controller.executeProposal(1, 1, 1000, LAWPStructs.FlowType.RoC, deadline, "");
//     }

//     function test_ExecuteProposal_RevertIf_ZeroAmount() public {
//         uint256 deadline = block.timestamp + 1 hours;
//         vm.expectRevert(LAWPMultiSigController_InvalidPayload.selector);
//         controller.executeProposal(1, 1, 0, LAWPStructs.FlowType.RoC, deadline, "");
//     }

//     function test_ExecuteProposal_RevertIf_InvalidSignatureLength() public {
//         uint256 deadline = block.timestamp + 1 hours;

//         // Too short
//         bytes memory shortSig = new bytes(64);
//         vm.expectRevert(LAWPMultiSigController_InvalidSignatureLength.selector);
//         controller.executeProposal(1, 1, 1000, LAWPStructs.FlowType.RoC, deadline, shortSig);

//         // Too long (Garbage bytes appended)
//         bytes memory longSig = new bytes(131);
//         vm.expectRevert(LAWPMultiSigController_InvalidSignatureLength.selector);
//         controller.executeProposal(1, 1, 1000, LAWPStructs.FlowType.RoC, deadline, longSig);
//     }

//     function test_ExecuteProposal_RevertIf_AlreadyExecuted() public {
//         uint256 proposalId = 1;
//         uint256 deadline = block.timestamp + 1 hours;

//         bytes32 digest =
//             controller.getProposalDigest(proposalId, 1, 1000, LAWPStructs.FlowType.RoC, deadline);
//         bytes memory sigs = _getSortedSignatures(pk1, pk2, digest);

//         controller.executeProposal(proposalId, 1, 1000, LAWPStructs.FlowType.RoC, deadline, sigs);

//         // Replay attempt
//         vm.expectRevert(LAWPMultiSigController_ProposalAlreadyExecuted.selector);
//         controller.executeProposal(proposalId, 1, 1000, LAWPStructs.FlowType.RoC, deadline, sigs);
//     }

//     function test_ExecuteProposal_RevertIf_UnorderedOrDuplicateSignatures() public {
//         uint256 deadline = block.timestamp + 1 hours;
//         bytes32 digest =
//             controller.getProposalDigest(1, 1, 1000, LAWPStructs.FlowType.RoC, deadline);

//         // Duplicate
//         (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk1, digest);
//         bytes memory duplicateSigs = abi.encodePacked(r, s, v, r, s, v);
//         vm.expectRevert(LAWPMultiSigController_InvalidSignerOrder.selector);
//         controller.executeProposal(1, 1, 1000, LAWPStructs.FlowType.RoC, deadline, duplicateSigs);

//         // Unordered (B then A)
//         address addrA = vm.addr(pk1);
//         address addrB = vm.addr(pk2);
//         uint256 firstPk = addrA < addrB ? pk1 : pk2;
//         uint256 secondPk = addrA < addrB ? pk2 : pk1;

//         (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(secondPk, digest); // Incorrectly order second PK first
//         (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(firstPk, digest);
//         bytes memory unorderedSigs = abi.encodePacked(r1, s1, v1, r2, s2, v2);

//         vm.expectRevert(LAWPMultiSigController_InvalidSignerOrder.selector);
//         controller.executeProposal(1, 1, 1000, LAWPStructs.FlowType.RoC, deadline, unorderedSigs);
//     }

//     function test_ExecuteProposal_RevertIf_NotASigner() public {
//         uint256 deadline = block.timestamp + 1 hours;
//         bytes32 digest =
//             controller.getProposalDigest(1, 1, 1000, LAWPStructs.FlowType.RoC, deadline);

//         uint256 maliciousPk = 0xBAD; // Not a registered board member
//         bytes memory sigs = _getSortedSignatures(pk1, maliciousPk, digest);

//         vm.expectRevert(LAWPMultiSigController_NotASigner.selector);
//         controller.executeProposal(1, 1, 1000, LAWPStructs.FlowType.RoC, deadline, sigs);
//     }

//     /*//////////////////////////////////////////////////////////////
//                   CRYPTOGRAPHIC EDGE CASES (V & S)
//     //////////////////////////////////////////////////////////////*/

//     function test_ExecuteProposal_Success_WithNormalizedV() public {
//         uint256 deadline = block.timestamp + 1 hours;
//         bytes32 digest =
//             controller.getProposalDigest(1, 1, 1000, LAWPStructs.FlowType.RoC, deadline);

//         address addrA = vm.addr(pk1);
//         address addrB = vm.addr(pk2);
//         uint256 firstPk = addrA < addrB ? pk1 : pk2;
//         uint256 secondPk = addrA < addrB ? pk2 : pk1;

//         (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(firstPk, digest);
//         (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(secondPk, digest);

//         // Normalize v downwards to simulate hardware wallets (e.g. 27 -> 0, 28 -> 1)
//         uint8 newV1 = v1 == 27 ? 0 : 1;
//         uint8 newV2 = v2 == 27 ? 0 : 1;

//         bytes memory sigs = abi.encodePacked(r1, s1, newV1, r2, s2, newV2);

//         // Should successfully normalize V and execute
//         controller.executeProposal(1, 1, 1000, LAWPStructs.FlowType.RoC, deadline, sigs);
//         assertTrue(controller.executedProposals(digest));

//         // Integration Check: RoC simply adds to the ledger, no treasury transfer occurs
//         assertEq(engine.poolRocTracker(1), 1000);
//     }

//     function test_ExecuteProposal_RevertIf_InvalidV() public {
//         uint256 deadline = block.timestamp + 1 hours;
//         bytes32 digest =
//             controller.getProposalDigest(1, 1, 1000, LAWPStructs.FlowType.RoC, deadline);

//         (, bytes32 r1, bytes32 s1) = vm.sign(pk1, digest);
//         (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(pk2, digest);

//         // Force invalid V (e.g., 29)
//         bytes memory sigs = abi.encodePacked(r1, s1, uint8(29), r2, s2, v2);

//         vm.expectRevert(LAWPMultiSigController_InvalidSignatures.selector);
//         controller.executeProposal(1, 1, 1000, LAWPStructs.FlowType.RoC, deadline, sigs);
//     }

//     function test_ExecuteProposal_RevertIf_MalleableS() public {
//         uint256 deadline = block.timestamp + 1 hours;
//         bytes32 digest =
//             controller.getProposalDigest(1, 1, 1000, LAWPStructs.FlowType.RoC, deadline);
//         bytes memory sigs;

//         {
//             (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(pk1, digest);
//             (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(pk2, digest);

//             // Mutate s to the upper half of the secp256k1 curve
//             uint256 malleableS =
//                 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141 - uint256(s1);
//             uint8 malleableV = v1 == 27 ? 28 : 27;

//             sigs = abi.encodePacked(r1, bytes32(malleableS), malleableV, r2, s2, v2);
//         }

//         {
//             vm.expectRevert(LAWPMultiSigController_InvalidSignatures.selector);
//             controller.executeProposal(1, 1, 1000, LAWPStructs.FlowType.RoC, deadline, sigs);
//         }
//     }
// }
