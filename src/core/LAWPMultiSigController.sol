// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ILAWPMultiSigController } from "../interfaces/ILAWPMultiSigController.sol";
import { ILAWPComplianceEngine } from "../interfaces/ILAWPComplianceEngine.sol";
import { LAWPStructs } from "../libraries/LAWPStructs.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

/// @title LAWPMultiSigController
/// @author Obinna Franklin Duru (BinnaDev)
/// @notice Safe-inspired off-chain verification bridge utilizing EIP-712 ECDSA signatures.
/// @dev Gathers off-chain signatures from the Community Board to
///      validate real-world Planbok deposits, then securely triggers the Compliance Engine.
///      Designed intentionally narrower than Safe to minimize attack surfaces,
///      focusing purely on verifying payload authenticity.
contract LAWPMultiSigController is ILAWPMultiSigController, Ownable2Step, ReentrancyGuard, EIP712 {
    /*//////////////////////////////////////////////////////////////
                           MULTI-SIG ERRORS
    //////////////////////////////////////////////////////////////*/
    error LAWPMultiSigController_InvalidSignatures();
    error LAWPMultiSigController_BelowThreshold();
    error LAWPMultiSigController_ProposalAlreadyExecuted();
    error LAWPMultiSigController_InvalidPayload();
    error LAWPMultiSigController_NotASigner();
    error LAWPMultiSigController_InvalidSignerOrder();
    error LAWPMultiSigController_InvalidThreshold();
    error LAWPMultiSigController_SignerAlreadyExists();
    error LAWPMultiSigController_Expired();
    error LAWPMultiSigController_TooManySigners();
    error LAWPMultiSigController_InvalidSignatureLength();
    error LAWPMultiSigController_ZeroAddress();
    error LAWPMultiSigController_InvalidPool();

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice The Compliance Engine contract where executed payloads are sent.
    /// @dev    Represents the explicit trust boundary.
    ///         The engine only accepts commands from this specific controller.
    ILAWPComplianceEngine public immutable engine;

    /// @notice The EIP-712 TypeHash for the Proposal struct.
    /// @dev    Hash of the struct signature used to securely pack the data for signing.
    bytes32 public constant PROPOSAL_TYPEHASH = keccak256(
        "Proposal(uint256 proposalId,uint256 poolId,uint256 totalAmount,uint8 flowType,uint256 deadline)"
    );

    /// @notice Hard upper bound for active board members.
    /// @dev    Anti-griefing measure to completely eliminate
    ///         unbounded loops during signature validation.
    uint256 public constant MAX_SIGNERS = 20;

    /// @notice Registry of authorized board members.
    /// @dev SECURITY ASSUMPTION: Signers MUST be standard Externally Owned Accounts (EOAs).
    ///      Smart contract signatures (ERC-1271) are explicitly unsupported.
    mapping(address signer => bool authorized) public isSigner;

    /// @notice Tracks the exact number of active signers to prevent threshold lockouts.
    uint256 public signerCount;

    /// @notice The minimum number of valid signatures required to execute a proposal.
    uint256 public threshold;

    /// @notice Replay protection: Cryptographic mapping of successfully executed EIP-712 digests.
    /// @dev Keying by the full digest instead of just `proposalId` prevents accidental reuse
    ///      of IDs across different payloads.
    mapping(bytes32 => bool) public executedProposals;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Initializes the controller with the required EIP-712 domain.
    /// @param _admin The initial owner (Admin Safe). Address(0) triggers native OZ v5 revert.
    /// @param _engine The address of the deployed LAWP Compliance Engine.
    /// @param _initialSigners Array of initial board members (EOAs only).
    /// @param _initialThreshold The starting signature requirement.
    constructor(
        address _admin,
        address _engine,
        address[] memory _initialSigners,
        uint256 _initialThreshold
    ) Ownable(_admin) EIP712("LAWP MultiSig", "1") {
        if (_engine == address(0)) {
            revert LAWPMultiSigController_ZeroAddress();
        }

        uint256 length = _initialSigners.length;
        if (length == 0 || _initialThreshold == 0 || _initialThreshold > length) {
            revert LAWPMultiSigController_InvalidThreshold();
        }
        if (length > MAX_SIGNERS) revert LAWPMultiSigController_TooManySigners();

        for (uint256 i = 0; i < length; i++) {
            address signer = _initialSigners[i];
            if (signer == address(0) || isSigner[signer]) {
                revert LAWPMultiSigController_InvalidSignatures();
            }
            isSigner[signer] = true;
            emit SignerAdded(signer);
        }

        engine = ILAWPComplianceEngine(_engine);
        signerCount = length;
        threshold = _initialThreshold;
        emit ThresholdUpdated(0, _initialThreshold);
    }

    /// @dev Overridden to prevent accidental renunciation of ownership.
    function renounceOwnership() public view override onlyOwner {
        revert("LAWPMultiSigController: renounceOwnership is disabled");
    }

    /*//////////////////////////////////////////////////////////////
                         PROPOSAL EXECUTION
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ILAWPMultiSigController
    /// @notice     OFF-CHAIN ASSUMPTION:
    ///             1. Board members observe a CNGN on-ramp in the Planbok account.
    ///             2. They construct the payload (`proposalId`, `poolId`, `deadline`, etc.)
    ///             and sign it locally.
    ///             3. A relayer collects `threshold` number of signatures,
    ///             sorts them by signer address, and submits this transaction.

    ///             Execution is permissionless; But the executor must pay the gas,
    ///             holds the CNGN to submit, and submit valid signatures.
    ///             Executor must approve the Compliance Engine to spend the CNGN
    ///             before calling this function, the Compliance Engine will pull
    ///             the totalAmount from the executor's address as part of the routing logic.
    function executeProposal(
        uint256 _proposalId,
        uint256 _poolId,
        uint256 _totalAmount,
        LAWPStructs.FlowType _flowType,
        uint256 _deadline,
        bytes calldata _signatures
    ) external override nonReentrant {
        // 1. Checks: Input Validation & Expiration
        if (block.timestamp >= _deadline) revert LAWPMultiSigController_Expired();
        if (_totalAmount == 0) revert LAWPMultiSigController_InvalidPayload();
        if (!engine.isPoolActive(_poolId)) revert LAWPMultiSigController_InvalidPool();

        // Exact length check (65 bytes per signature).
        // Strict equality prevents garbage bytes or extra signatures from being appended.
        if (_signatures.length != threshold * 65) {
            revert LAWPMultiSigController_InvalidSignatureLength();
        }

        // 2. Checks: Construct the EIP-712 Digest
        // This securely binds the payload to this specific contract address and chain ID.
        // This creates a unique fingerprint of the proposal.
        bytes32 digest = getProposalDigest(_proposalId, _poolId, _totalAmount, _flowType, _deadline);

        // 3. Checks: Cryptographic Replay Protection
        // Bounding the replay check to the full digest (not just the ID) prevents cross-payload ID collisions.
        if (executedProposals[digest]) revert LAWPMultiSigController_ProposalAlreadyExecuted();

        // 4. Checks: Gas-Optimized Cryptographic Signature Verification
        _verifySignatures(digest, _signatures);

        // 5. Effects: Mark as executed BEFORE external calls (CEI Pattern)
        executedProposals[digest] = true;

        // 6. Interactions: Trigger the validated mathematical routing logic.
        // Explicit Trust Boundary: The Engine relies entirely on this controller to filter out invalid or malicious executions.
        // The relayer (msg.sender) is explicitly defined as the fund provider
        engine.routeOperationalAllocation(_poolId, _totalAmount, msg.sender, _flowType);

        // _proposalId acts as contextual metadata for off-chain indexers
        emit ProposalExecuted(digest, _proposalId, _poolId, _totalAmount, _flowType);
    }

    /*//////////////////////////////////////////////////////////////
                             UTILITIES
    //////////////////////////////////////////////////////////////*/

    /// @notice Generates the exact EIP-712 digest required for off-chain signing.
    /// @dev Highly useful for frontends, relayers, and signers to verify the payload hash locally.
    function getProposalDigest(
        uint256 _proposalId,
        uint256 _poolId,
        uint256 _totalAmount,
        LAWPStructs.FlowType _flowType,
        uint256 _deadline
    ) public view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                PROPOSAL_TYPEHASH, _proposalId, _poolId, _totalAmount, uint8(_flowType), _deadline
            )
        );
        return _hashTypedDataV4(structHash);
    }

    /*//////////////////////////////////////////////////////////////
                        ADMINISTRATION (BOARD MGMT)
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ILAWPMultiSigController
    function addSigner(address _signer) external override onlyOwner {
        if (_signer == address(0)) revert LAWPMultiSigController_ZeroAddress();
        if (isSigner[_signer]) revert LAWPMultiSigController_SignerAlreadyExists();
        if (signerCount >= MAX_SIGNERS) revert LAWPMultiSigController_TooManySigners();

        isSigner[_signer] = true;
        signerCount++;

        emit SignerAdded(_signer);
    }

    /// @inheritdoc ILAWPMultiSigController
    function removeSigner(address _signer) external override onlyOwner {
        if (!isSigner[_signer]) revert LAWPMultiSigController_NotASigner();

        // Prevent removing a signer if it drops the total count below the required threshold
        if (signerCount - 1 < threshold) revert LAWPMultiSigController_InvalidThreshold();

        isSigner[_signer] = false;
        signerCount--;

        emit SignerRemoved(_signer);
    }

    /// @inheritdoc ILAWPMultiSigController
    function updateThreshold(uint256 _newThreshold) external override onlyOwner {
        if (_newThreshold == 0 || _newThreshold > signerCount) {
            revert LAWPMultiSigController_InvalidThreshold();
        }

        uint256 oldThreshold = threshold;
        threshold = _newThreshold;

        emit ThresholdUpdated(oldThreshold, _newThreshold);
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Verifies exactly `threshold` signatures, enforcing ordering and uniqueness.
    /// @dev Reverts on any invalid signature, duplicate, or unsorted signer.
    function _verifySignatures(bytes32 digest, bytes calldata _signatures) private view {
        address lastSigner = address(0);

        // Signature Verification Bounded loop: Only checks exactly the `threshold` number of signatures.
        for (uint256 i = 0; i < threshold; i++) {
            // Slice signature from calldata
            bytes32 r;
            bytes32 s;
            uint8 v;

            // Inline assembly to slice packed bytes natively from calldata, matching Safe's gas efficiency.
            assembly {
                // Calculate the starting position of the current signature in calldata
                let signaturePos := add(_signatures.offset, mul(i, 65))

                // First 32 bytes: r, Next 32 bytes: s, Final byte: v
                // The `r` value is loaded directly as a 32-byte word from calldata.
                r := calldataload(signaturePos)

                // The `s` value is loaded as a full 32 bytes, but we will validate its range later to prevent malleability.
                s := calldataload(add(signaturePos, 32))

                // The `v` value is the last byte of the 65-byte signature. We use `byte` to extract it.
                v := byte(0, calldataload(add(signaturePos, 64)))
            }

            v = _normaliseV(v);
            _checkSignatureMalleability(s);

            // Recover the signer address from the digest and signature
            // SECURITY ASSUMPTION: Signers MUST be EOAs. ERC-1271 contract signatures are not supported.
            // This is a deliberate design choice to minimize complexity and attack surfaces.
            // The `ecrecover` function returns the address that signed the message. If the signature is invalid, it returns address(0).
            address currentSigner = ecrecover(digest, v, r, s);
            if (currentSigner == address(0) || !isSigner[currentSigner]) {
                revert LAWPMultiSigController_InvalidSignatures();
            }

            // CRITICAL ANTI-DOS & ANTI-DUPLICATE CHECK:
            // Signatures MUST be submitted in ascending order based on the signer's Ethereum address.
            // If currentSigner <= lastSigner, it means the relayer either provided duplicates (A, A, B)
            // or unordered signatures (B, A). This natively prevents double-counting a single signature.
            if (uint160(currentSigner) <= uint160(lastSigner)) {
                revert LAWPMultiSigController_InvalidSignerOrder();
            }

            // Update lastSigner for the next iteration's comparison. This ensures strict ascending order.
            // By enforcing this order, we guarantee that each signature is unique and that the total count of valid signatures is exactly `threshold`.
            lastSigner = currentSigner;
        }
    }

    /// @notice Normalizes the recovery byte `v` to standard Ethereum values (27 or 28).
    /// @dev Supports EIP-2098 compact signatures and certain hardware wallets that output `v` as 0 or 1.
    function _normaliseV(uint8 v) private pure returns (uint8) {
        // Normalize v if necessary (some hardware wallets output 0 or 1 instead of 27 or 28)
        if (v < 27) v += 27;

        // Validate v is exactly 27 or 28
        if (v != 27 && v != 28) revert LAWPMultiSigController_InvalidSignatures();

        return v;
    }

    function _checkSignatureMalleability(bytes32 s) private pure {
        // ECDSA Malleability Check: Ensure `s` is in the lower half of the secp256k1 curve.
        // This prevents signature malleability, where an attacker could modify `s` to create a different valid signature for the same message.
        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) {
            revert LAWPMultiSigController_InvalidSignatures();
        }
    }
}
