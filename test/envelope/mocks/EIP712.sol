/**
 * SPDX-License-Identifier: MIT
 *
 * Copyright (c) 2018-2020 CENTRE SECZ
 */

pragma solidity 0.8.26;

import {ECRecover} from "./ECRecover.sol";

library EIP712 {
    function makeDomainSeparator(string memory name, string memory version) internal view returns (bytes32) {
        uint256 chainId;
        assembly {
            chainId := chainid()
        }
        return keccak256(
            abi.encode(
                // keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")
                0x8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39400f,
                keccak256(bytes(name)),
                keccak256(bytes(version)),
                chainId,
                address(this)
            )
        );
    }

    function recover(bytes32 domainSeparator, uint8 v, bytes32 r, bytes32 s, bytes memory typeHashAndData)
        internal
        pure
        returns (address)
    {
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, keccak256(typeHashAndData)));
        return ECRecover.recover(digest, v, r, s);
    }
}
