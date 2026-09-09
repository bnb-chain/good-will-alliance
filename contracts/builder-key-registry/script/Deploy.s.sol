// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {BuilderKeyRegistry} from "../src/BuilderKeyRegistry.sol";

/// @notice Deploys the implementation + ERC-1967 proxy, initializes it, and optionally loads the
///         initial builder list from a JSON file.
///
/// Environment variables:
///   OWNER            address that receives the admin role (required)
///   DEFAULT_MAX_KEYS default per-builder key cap (default: 4)
///   BUILDERS_JSON    path under ./script/input to a JSON array of {addr,name,url} (optional)
///
/// Example (simulation only, no broadcast):
///   OWNER=0x... BUILDERS_JSON=script/input/bsc-mainnet/builders.json \
///     forge script script/Deploy.s.sol --rpc-url bsc_testnet
/// Add `--broadcast --account <keystore-name>` to actually send transactions.
contract Deploy is Script {
    /// @dev Field order must be alphabetical to match how `vm.parseJson` ABI-encodes JSON objects.
    struct Entry {
        address addr;
        string name;
        string url;
    }

    function run() external {
        address owner = vm.envAddress("OWNER");
        uint256 defaultMaxKeys = vm.envOr("DEFAULT_MAX_KEYS", uint256(4));
        string memory buildersJson = vm.envOr("BUILDERS_JSON", string(""));

        BuilderKeyRegistry.Builder[] memory initial = _loadBuilders(buildersJson);
        _checkCapFits(initial, defaultMaxKeys);

        vm.startBroadcast();

        BuilderKeyRegistry impl = new BuilderKeyRegistry();
        bytes memory init = abi.encodeCall(BuilderKeyRegistry.initialize, (msg.sender, defaultMaxKeys));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), init);
        BuilderKeyRegistry registry = BuilderKeyRegistry(address(proxy));

        if (initial.length > 0) {
            registry.addBuilders(initial);
        }

        // Deployer initializes as owner so it can load the list, then hands the role to OWNER.
        // OWNER must call acceptOwnership() to complete the transfer.
        if (owner != msg.sender) {
            registry.transferOwnership(owner);
        }

        vm.stopBroadcast();

        console.log("BuilderKeyRegistry implementation:", address(impl));
        console.log("BuilderKeyRegistry proxy (use this address):", address(proxy));
        console.log("default max keys:", defaultMaxKeys);
        console.log("initial builders loaded:", initial.length);
        if (owner != msg.sender) {
            console.log("pending owner (must call acceptOwnership):", owner);
        }
    }

    /// @dev Fails fast (in simulation, before any gas is spent) if some operator in the initial list
    ///      holds more keys than the default cap allows. The current mainnet list has operators with
    ///      up to 7 keys, so the initial deployment needs DEFAULT_MAX_KEYS >= 7; lower it to the
    ///      target (4) with setDefaultMaxKeys() once the key reduction has been executed.
    function _checkCapFits(BuilderKeyRegistry.Builder[] memory list, uint256 cap) internal pure {
        uint256 worstCount;
        string memory worstName;
        for (uint256 i = 0; i < list.length; ++i) {
            bytes32 key = keccak256(bytes(list[i].name));
            uint256 count;
            for (uint256 j = 0; j < list.length; ++j) {
                if (keccak256(bytes(list[j].name)) == key) count++;
            }
            if (count > worstCount) {
                worstCount = count;
                worstName = list[i].name;
            }
        }
        require(
            worstCount <= cap,
            string.concat(
                "initial list exceeds DEFAULT_MAX_KEYS: '",
                worstName,
                "' has ",
                vm.toString(worstCount),
                " keys; set DEFAULT_MAX_KEYS >= ",
                vm.toString(worstCount)
            )
        );
    }

    function _loadBuilders(string memory path) internal view returns (BuilderKeyRegistry.Builder[] memory out) {
        if (bytes(path).length == 0) {
            return out;
        }
        string memory json = vm.readFile(path);
        Entry[] memory entries = abi.decode(vm.parseJson(json), (Entry[]));
        out = new BuilderKeyRegistry.Builder[](entries.length);
        for (uint256 i = 0; i < entries.length; ++i) {
            out[i] = BuilderKeyRegistry.Builder({addr: entries[i].addr, url: entries[i].url, name: entries[i].name});
        }
    }
}
