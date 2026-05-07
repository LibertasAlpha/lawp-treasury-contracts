// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test, console } from "forge-std/Test.sol";
import { LAWPComplianceEngine } from "../../src/core/LAWPComplianceEngine.sol";
import { LAWPTreasury } from "../../src/core/LAWPTreasury.sol";
import { LAWPImpactToken } from "../../src/core/LAWPImpactToken.sol";
import { LAWPActorRegistry } from "../../src/core/LAWPActorRegistry.sol";
import { MockCngn3, MockAdminOperations } from "../mocks/MockCngn3.sol";
import { MockMultiSig } from "../mocks/MockMultiSig.sol";
import { LAWPStructs } from "../../src/libraries/LAWPStructs.sol";

contract LAWPFlowTest is Test {
    LAWPComplianceEngine public engine;
    LAWPTreasury public treasury;
    LAWPImpactToken public impactToken;
    LAWPActorRegistry public registry;
    MockCngn3 public cngn;
    MockAdminOperations public adminOps;
    MockMultiSig public mockMultiSig;

    address public admin = address(1);
    address public la2Wallet = address(11);
    address public mvi1Wallet = address(12);
    address public riskPoolWallet = address(13);
    address public devWallet = address(14);
    address public coordinator = address(15);

    address[] public users;

    function setUp() public {
        adminOps = new MockAdminOperations();
        cngn = new MockCngn3(address(adminOps));

        registry = new LAWPActorRegistry(admin);
        treasury = new LAWPTreasury(address(cngn), admin);
        impactToken = new LAWPImpactToken(admin, "ipfs://base/");

        vm.startPrank(admin);
        registry.setLA2Wallet(la2Wallet);
        registry.setMVI1Wallet(mvi1Wallet);
        registry.setRiskPoolWallet(riskPoolWallet);
        registry.setDevWallet(devWallet);
        vm.stopPrank();

        engine = new LAWPComplianceEngine(
            admin,
            address(treasury),
            address(impactToken),
            address(registry),
            address(cngn),
            1000 // 10% Risk Fee
        );

        mockMultiSig = new MockMultiSig(address(engine));

        vm.startPrank(admin);
        engine.setMultiSigController(address(mockMultiSig));
        treasury.setComplianceEngine(address(engine));
        treasury.setRiskPoolWallet(riskPoolWallet);
        impactToken.setComplianceEngine(address(engine));
        vm.stopPrank();

        // Setup 10 Users
        for (uint160 i = 100; i < 110; i++) {
            address u = address(i);
            users.push(u);
            cngn.mintTest(u, 10_000e6);
        }
        cngn.mintTest(coordinator, 100_000e6);
        cngn.mintTest(address(treasury), 1_000_000e6); // Seed vault for revenue
    }

    function test_FullLifecycleFlow() public {
        // 1. 10 Users pool CNGN
        // 10% each i < 10; i++)
        uint256[] memory bps = new uint256[](10);
        for (uint256 i = 0; i < 10; i++) {
            bps[i] = 1000;
        }

        vm.startPrank(coordinator);
        cngn.approve(address(engine), 100_000e6);
        engine.processPoolDeposit(1, 100_000e6, users, bps);
        vm.stopPrank();

        assertEq(cngn.balanceOf(riskPoolWallet), 10_000e6); // 10% Risk Fee

        // 2. Activator Sale (GRANT_INITIAL)
        mockMultiSig.execute(1, 50_000e6, LAWPStructs.FlowType.GRANT_INITIAL);

        // 3. Secondary Market NFT Transfer (User 100 -> User 999)
        address user1 = users[0];
        address buyer = address(999);
        uint256 token1Id = 1;

        uint256 user1BalBefore = cngn.balanceOf(user1);

        vm.prank(user1);
        impactToken.transferFrom(user1, buyer, token1Id);

        // Interception Hook Assertion: Pending yield must be flushed to User 1
        // Expected Yield for Token 1: 30% of 50k = 15k pool yield. 10% of 15k = 1,500e6.
        assertEq(cngn.balanceOf(user1), user1BalBefore + 1_500e6);
        assertEq(engine.calculateProportionalYield(token1Id), 0); // Buyer gets nothing initially

        // 4. More Revenue & Subsequent Claims
        mockMultiSig.execute(1, 20_000e6, LAWPStructs.FlowType.GRANT_CONTINUOUS);
        mockMultiSig.execute(1, 10_000e6, LAWPStructs.FlowType.RoC);

        // Buyer claims new yield + RoC
        uint256 buyerBalBefore = cngn.balanceOf(buyer);
        vm.prank(buyer);
        engine.claimYield(token1Id);

        // Buyer Expected: Yield: (20k * 10% collective) * 10% = 200e6. RoC: 10k * 10% = 1,000e6. Total = 1,200e6
        assertEq(cngn.balanceOf(buyer), buyerBalBefore + 1_200e6);
    }
}
