// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {BountyMarket} from "../src/BountyMarket.sol";

contract Deploy is Script {
    // Tempo testnet USDC — replace with actual address
    address constant USDC = 0x20C000000000000000000000b9537d11c60E8b50;

    function run() external {
        address treasury = vm.envAddress("TREASURY");
        uint256 pk = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(pk);
        BountyMarket market = new BountyMarket(USDC, treasury);
        vm.stopBroadcast();

        console.log("BountyMarket deployed at:", address(market));
    }
}
