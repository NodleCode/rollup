/**
 * SPDX-License-Identifier: MIT
 *
 * Copyright (c) 2018-2020 CENTRE SECZ
 */

pragma solidity ^0.8.23;

contract EIP712Domain {
    /**
     * @dev EIP712 Domain Separator
     * @dev The value is the current DOMAIN_SEPARATOR of USDC on Polygon (used by tests as a fixed value)
     */
    bytes32 public DOMAIN_SEPARATOR = 0xcaa2ce1a5703ccbe253a34eb3166df60a705c561b44b192061e28f2a985be2ca;
}
