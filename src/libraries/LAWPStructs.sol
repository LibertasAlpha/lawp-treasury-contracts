// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title LAWPStructs
 * @dev Core data structures for the Libertas Alpha Water Project.
 * Designed with strict storage packing to minimize gas costs on Base L2.
 */
library LAWPStructs {
    /**
     * @dev Defines the strict whitelist of permitted fund flow classifications.
     */
    enum FlowType {
        ROC,                // Return of Contribution (Principal recovery)
        GRANT_INITIAL,      // System 1: Activator Sales Surplus
        GRANT_CONTINUOUS    // System 2: Refill Sales Surplus
    }

    /**
     * @dev Represents a multi-sig transaction request.
     * * Storage Packing (3 Slots Total):
     * Slot 1: recipient (160 bits) + amount (96 bits) = 256 bits
     * Slot 2: tokenId (256 bits) = 256 bits
     * Slot 3: flowType (8 bits) + submittedAt (32 bits) + executionCount (32 bits) + executed (8 bits) = 80 bits
     */
    struct Proposal {
        address recipient;
        uint96 amount;          // uint96 max is ~79.2 billion (assuming 18 decimals), safe for CNGN
        uint256 tokenId;        // Target Impact Token ID (Ignored if flowType is a GRANT)
        FlowType flowType;
        uint32 submittedAt;     // Safe until year 2106
        uint32 executionCount;  // Nonce for replay protection
        bool executed;          // Prevents double execution
    }

    /**
     * @dev Tracks contributor capital state. Mapped against an Impact Token ID.
     * * Storage Packing (1 Slot Total):
     * principalContributed (120 bits) + rocReturned (120 bits) + isActive (8 bits) = 248 bits
     */
    struct ContributorState {
        uint120 principalContributed; // uint120 max is ~1.3e36, safe for CNGN
        uint120 rocReturned;
        bool isActive;
    }
}