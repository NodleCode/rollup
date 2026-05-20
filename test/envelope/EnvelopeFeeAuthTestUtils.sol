// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {EnvelopeLinks} from "../../src/envelope/EnvelopeLinks.sol";

library EnvelopeFeeAuthTestUtils {
    function feeAuthorizationDigest(
        bytes32 salt,
        address vaultAddr,
        EnvelopeLinks.LinkRequest memory request,
        address feePayer,
        uint256 serviceFee,
        uint256 gaslessFee,
        bool gaslessSponsored,
        uint256 deadline
    ) internal view returns (bytes32) {
        bytes32 digest;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(0x40, add(ptr, 544))
            mstore(ptr, salt)
            mstore(add(ptr, 32), chainid())
            mstore(add(ptr, 64), vaultAddr)
            mstore(add(ptr, 96), feePayer)
            mstore(add(ptr, 128), mload(request))
            mstore(add(ptr, 160), mload(add(request, 32)))
            mstore(add(ptr, 192), mload(add(request, 64)))
            mstore(add(ptr, 224), mload(add(request, 96)))
            mstore(add(ptr, 256), mload(add(request, 128)))
            mstore(add(ptr, 288), mload(add(request, 160)))
            mstore(add(ptr, 320), mload(add(request, 192)))
            mstore(add(ptr, 352), mload(add(request, 224)))
            mstore(add(ptr, 384), mload(add(request, 256)))
            mstore(add(ptr, 416), serviceFee)
            mstore(add(ptr, 448), gaslessFee)
            mstore(add(ptr, 480), gaslessSponsored)
            mstore(add(ptr, 512), deadline)
            digest := keccak256(ptr, 544)
        }
        return MessageHashUtils.toEthSignedMessageHash(digest);
    }
}