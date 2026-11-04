// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {BuilderKeyRegistry} from "../src/BuilderKeyRegistry.sol";

/// @notice Deploys a new implementation and points the existing proxy at it.
///         The broadcasting account must be the current owner of the proxy.
///
/// Environment variables:
///   PROXY  address of the deployed BuilderKeyRegistry proxy (required)
///
/// Example:
///   PROXY=0x... forge script script/Upgrade.s.sol --rpc-url bsc_testnet --broadcast --account <keystore-name>
contract Upgrade is Script {
    function run() external {
        address proxy = vm.envAddress("PROXY");

        vm.startBroadcast();
        BuilderKeyRegistry newImpl = new BuilderKeyRegistry();
        BuilderKeyRegistry(proxy).upgradeToAndCall(address(newImpl), "");
        vm.stopBroadcast();

        console.log("new implementation:", address(newImpl));
        console.log("proxy upgraded:", proxy);
    }
}
