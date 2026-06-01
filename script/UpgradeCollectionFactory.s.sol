// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";

import {CollectionFactory} from "../src/collections/CollectionFactory.sol";
import {UserCollection721} from "../src/collections/UserCollection721.sol";
import {UserCollection1155} from "../src/collections/UserCollection1155.sol";

/**
 * @title UpgradeCollectionFactory
 * @notice Three-mode upgrade script for the user collections system.
 * @dev See `src/collections/doc/spec/user-collections-specification.md` (§9.4).
 *
 *      **Modes**:
 *        - `UPGRADE_FACTORY`: deploys a fresh `CollectionFactory` logic
 *          contract and calls `upgradeToAndCall` on the existing proxy. Pass
 *          `REINIT_DATA` to invoke a `reinitializer(N)` migration in the same tx.
 *        - `SET_IMPL_721`: deploys a fresh `UserCollection721` implementation
 *          and calls `setImplementation721` on the proxy. Affects future clones
 *          only — existing clones remain on the previous implementation.
 *        - `SET_IMPL_1155`: same as above for `UserCollection1155`.
 *
 *      **Pre-Upgrade Checklist (factory upgrade)**:
 *        1. Snapshot storage layout: `forge inspect CollectionFactory storageLayout`
 *           and compare against the committed
 *           `src/collections/layouts/CollectionFactory.v1.json` baseline.
 *           Verify slot index AND byte offset for sub-word fields (lock bools).
 *        2. Run all collections tests: `forge test --match-path "test/collections/**"`.
 *        3. Test on a fork: re-run this script with `--fork-url $RPC_URL` first.
 *        4. After broadcast, verify the new EIP-1967 implementation slot via
 *           `cast implementation $FACTORY_PROXY` and confirm role/state preservation.
 *
 *      **Pre-Upgrade Checklist (setImplementation*)**:
 *        1. Snapshot the new clone implementation's layout against the
 *           previous `UserCollection<721|1155>` baseline.
 *        2. Confirm the post-`setImplementation*` `cast call` matches the new
 *           implementation address.
 *
 * Usage (zkSync Era — the `--zksync` flag is REQUIRED; without it forge compiles
 * and deploys EVM bytecode, which is the wrong VM and will not register the new
 * implementation as a factoryDep):
 *   ACTION=UPGRADE_FACTORY FACTORY_PROXY=0x... \
 *       forge script script/UpgradeCollectionFactory.s.sol --rpc-url $RPC_URL --zksync --broadcast --slow
 *
 *   ACTION=SET_IMPL_721 FACTORY_PROXY=0x... \
 *       forge script script/UpgradeCollectionFactory.s.sol --rpc-url $RPC_URL --zksync --broadcast --slow
 *
 *   ACTION=SET_IMPL_1155 FACTORY_PROXY=0x... \
 *       forge script script/UpgradeCollectionFactory.s.sol --rpc-url $RPC_URL --zksync --broadcast --slow
 *
 *   RECOMMENDED: run via the orchestration wrapper
 *   `ops/upgrade_collection_factory_zksync.sh <testnet|mainnet> <ACTION> [--broadcast]`,
 *   which handles the `--zksync` compile (including the temp move/restore of
 *   L1-only files like `SwarmRegistryL1Upgradeable` that zksolc cannot compile),
 *   the pre-upgrade storage-layout diff against the committed baseline, the
 *   admin-key check, the mainnet guard, and the post-broadcast asserts +
 *   source verification. Invoking this Forge script directly requires doing
 *   that move/restore yourself first.
 *
 * Environment Variables:
 *   - DEPLOYER_PRIVATE_KEY: Private key of the address holding `DEFAULT_ADMIN_ROLE` on the factory proxy.
 *   - FACTORY_PROXY:        Address of the deployed `CollectionFactory` ERC1967 proxy.
 *   - ACTION:               One of `UPGRADE_FACTORY`, `SET_IMPL_721`, `SET_IMPL_1155`.
 *   - REINIT_DATA:          (UPGRADE_FACTORY only, optional) ABI-encoded reinitializer call.
 */
contract UpgradeCollectionFactory is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address proxyAddress = vm.envAddress("FACTORY_PROXY");
        string memory action = vm.envString("ACTION");

        require(proxyAddress != address(0), "FACTORY_PROXY is zero");

        console.log("=== Collections Upgrade ===");
        console.log("Action:", action);
        console.log("Factory Proxy:", proxyAddress);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        bytes32 actionHash = keccak256(bytes(action));
        address newImpl;
        if (actionHash == keccak256("UPGRADE_FACTORY")) {
            bytes memory reinitData = vm.envOr("REINIT_DATA", bytes(""));
            newImpl = _upgradeFactory(proxyAddress, reinitData);
        } else if (actionHash == keccak256("SET_IMPL_721")) {
            newImpl = _setImpl721(proxyAddress);
        } else if (actionHash == keccak256("SET_IMPL_1155")) {
            newImpl = _setImpl1155(proxyAddress);
        } else {
            revert("Invalid ACTION. Use UPGRADE_FACTORY, SET_IMPL_721, or SET_IMPL_1155.");
        }

        vm.stopBroadcast();

        console.log("");
        console.log("=== Upgrade Complete ===");
        console.log("New Implementation:", newImpl);
        console.log("Proxy (unchanged):", proxyAddress);
    }

    function _upgradeFactory(address proxy, bytes memory reinitData) internal returns (address impl) {
        console.log("Deploying new CollectionFactory logic...");
        impl = address(new CollectionFactory());
        console.log("New factory implementation:", impl);

        CollectionFactory factory = CollectionFactory(proxy);
        if (reinitData.length > 0) {
            console.log("Calling upgradeToAndCall with reinitializer...");
            factory.upgradeToAndCall(impl, reinitData);
        } else {
            console.log("Calling upgradeToAndCall...");
            factory.upgradeToAndCall(impl, "");
        }
    }

    function _setImpl721(address proxy) internal returns (address impl) {
        console.log("Deploying new UserCollection721 implementation...");
        impl = address(new UserCollection721());
        console.log("New 721 implementation:", impl);

        CollectionFactory factory = CollectionFactory(proxy);
        factory.setImplementation721(impl);
        console.log("setImplementation721 broadcast.");
    }

    function _setImpl1155(address proxy) internal returns (address impl) {
        console.log("Deploying new UserCollection1155 implementation...");
        impl = address(new UserCollection1155());
        console.log("New 1155 implementation:", impl);

        CollectionFactory factory = CollectionFactory(proxy);
        factory.setImplementation1155(impl);
        console.log("setImplementation1155 broadcast.");
    }
}
