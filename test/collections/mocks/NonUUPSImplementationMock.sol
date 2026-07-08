// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title NonUUPSImplementationMock
 * @notice A bare contract used as an upgrade target to verify that
 *         `CollectionFactory.upgradeToAndCall` reverts with OZ's
 *         `ERC1967InvalidImplementation` (no `proxiableUUID`).
 */
contract NonUUPSImplementationMock {
    uint256 public sentinel = 1;
}
