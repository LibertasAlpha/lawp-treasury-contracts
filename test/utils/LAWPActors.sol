// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

/// @title LAWPActors
/// @notice Deterministic actor addresses and private keys for the test suite.
contract LAWPActors is Test {
    // Foundational Protocol Actors
    address governance = makeAddr("governance");
    address campaignManager = makeAddr("campaignManager");
    address operator = makeAddr("operator"); // LA2 operator

    // Static Operational Wallets (System 2 Allocation Targets)
    address la2Wallet = makeAddr("la2Wallet");
    address mvi1Wallet = makeAddr("mvi1Wallet");
    address devWallet = makeAddr("devWallet");

    // Multi-Sig Signers (Keys for EIP-712 signing)
    uint256 signer1Key = 0x111;
    address signer1 = vm.addr(signer1Key);

    uint256 signer2Key = 0x222;
    address signer2 = vm.addr(signer2Key);

    uint256 signer3Key = 0x333;
    address signer3 = vm.addr(signer3Key);

    // Contributors
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address charlie = makeAddr("charlie");
    address dave = makeAddr("dave");
}
