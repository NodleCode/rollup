// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";

import {Tipping} from "../src/tipping/Tipping.sol";

/**
 * @title SeedTippingZkSync
 * @notice One-off registry seed after deployment (meta#242): allowlists the ContentSign-type
 *         contracts and registers the creator of every factory collection created before
 *         `Tipping` existed. Later collections register themselves (owner calls
 *         `registerCollection`) or are set by the operator at creation time.
 *
 *         Idempotent: entries already in the wanted state are skipped, so the script can be
 *         re-run after a partial broadcast.
 *
 * Usage:
 *   forge script script/SeedTippingZkSync.s.sol --rpc-url $L2_RPC --broadcast --zksync
 *
 * Environment Variables:
 *   - REGISTRY_PRIVATE_KEY:      Key holding REGISTRY_ROLE on `Tipping`.
 *   - N_TIPPING:                 Deployed `Tipping` address.
 *   - N_TIPPING_ALLOWLIST:       Comma-separated ContentSign-type contracts to allowlist
 *                                (mainnet: the four legacy ClickContentSign contracts).
 *   - N_TIPPING_COLLECTIONS:     Comma-separated factory collections (from `CollectionCreated`).
 *   - N_TIPPING_CREATORS:        Comma-separated creators, same order (`CollectionCreated.owner`).
 *                                Both may be empty on a fresh chain.
 */
contract SeedTippingZkSync is Script {
    function run() external {
        uint256 registryKey = vm.envUint("REGISTRY_PRIVATE_KEY");
        Tipping tipping = Tipping(vm.envAddress("N_TIPPING"));
        address[] memory allow = vm.envOr("N_TIPPING_ALLOWLIST", ",", new address[](0));
        address[] memory collections = vm.envOr("N_TIPPING_COLLECTIONS", ",", new address[](0));
        address[] memory creators = vm.envOr("N_TIPPING_CREATORS", ",", new address[](0));
        require(collections.length == creators.length, "collections/creators length mismatch");

        console.log("=== Seeding Tipping registry ===");
        console.log("Tipping:", address(tipping));
        console.log("Allowlist entries:", allow.length);
        console.log("Creator entries:", collections.length);

        vm.startBroadcast(registryKey);
        for (uint256 i; i < allow.length; i++) {
            if (tipping.contentSignAllowed(allow[i])) continue;
            tipping.setCollectionAllowed(allow[i], true);
            console.log("allowed:", allow[i]);
        }
        for (uint256 i; i < collections.length; i++) {
            require(creators[i] != address(0), "creator is zero");
            if (tipping.creatorOf(collections[i]) == creators[i]) continue;
            tipping.setCreator(collections[i], creators[i]);
            console.log("creator set:", collections[i], creators[i]);
        }
        vm.stopBroadcast();
    }
}
