// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {CollectionFactory} from "../../../src/collections/CollectionFactory.sol";

/**
 * @title CollectionFactoryV2Mock
 * @notice UUPS upgrade target used by `CollectionFactory.t.sol` to verify that:
 *         (a) the upgrade actually changes the EIP-1967 implementation slot,
 *         (b) pre-upgrade storage (admin/operator roles, impl pointers,
 *             collectionByExternalId entries) reads correctly post-upgrade.
 * @dev    Adds one trivial public function whose presence post-upgrade proves
 *         the proxy genuinely delegated to new code rather than no-opping.
 */
contract CollectionFactoryV2Mock is CollectionFactory {
    function v2Sentinel() external pure returns (uint256) {
        return 4242;
    }
}
