// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console2 } from "forge-std/Script.sol";
import { MockAdminOperations, MockCngn3 } from "../test/mocks/MockCngn3.sol";

/// @title LAWP Mock Deployment Script
/// @author Obinna Franklin Duru (BinnaDev)
/// @notice Deploys the cNGN and Admin Operations mocks for local Anvil and Testnet simulations.
contract DeployMock is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console2.log("Starting Mock Deployment from:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        MockAdminOperations adminOps = new MockAdminOperations();
        console2.log("MockAdminOperations deployed at:", address(adminOps));

        MockCngn3 cngn = new MockCngn3(address(adminOps));
        console2.log("MockCngn3 deployed at:", address(cngn));

        // Pre-approve the deployer to mint Test tokens freely on the testnet
        adminOps.setCanMint(deployer, type(uint256).max);

        vm.stopBroadcast();

        console2.log("Mock ecosystem ready for LAWP deployment simulation.");
    }
}
