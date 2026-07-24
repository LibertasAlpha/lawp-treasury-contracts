// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Script, console2 } from "forge-std/Script.sol";
import { MockCNGN } from "../test/mocks/MockCNGN.sol";

contract DeployCNGNLocal is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console2.log("=== MOCK CNGN DEPLOYMENT STARTED ===");
        console2.log("Deployer:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy Mock CNGN
        MockCNGN cNGN = new MockCNGN();
        cNGN.mint(deployer, 10_000_000 ether);

        console2.log("MockCNGN deployed at:", address(cNGN));

        vm.stopBroadcast();

        console2.log("");
        console2.log("=========== Deployment Complete ===========");
        console2.log("MockCNGN:", address(cNGN));
        console2.log("===========================================");
    }
}