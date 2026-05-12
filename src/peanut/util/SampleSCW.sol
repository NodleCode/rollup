// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

// Super simple smart contract wallet that implements EIP-1271
// Code taken from https://eips.ethereum.org/EIPS/eip-1271
contract SampleWallet {
    bytes4 internal constant MAGICVALUE = 0x1626ba7e;

    function isValidSignature(bytes32 _hash, bytes memory _signature) public pure returns (bytes4 magicValue) {
        if (bytes32(_signature) == _hash) return MAGICVALUE;
        return bytes4(0);
    }
}
