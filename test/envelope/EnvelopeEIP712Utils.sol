// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {EnvelopeLinks} from "../../src/envelope/EnvelopeLinks.sol";

/// @dev Shared EIP-712 digest helpers for EnvelopeLinks test suites.
library EnvelopeEIP712Utils {
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    bytes32 internal constant NAME_HASH = keccak256("EnvelopeLinks");
    bytes32 internal constant VERSION_HASH = keccak256("5");

    function domainSeparator(address vaultAddr) internal view returns (bytes32) {
        return keccak256(abi.encode(DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, vaultAddr));
    }

    function claimDigest(address vaultAddr, uint256 index, address recipient, bytes32 mode)
        internal
        view
        returns (bytes32)
    {
        bytes32 structHash =
            keccak256(abi.encode(EnvelopeLinks(payable(vaultAddr)).CLAIM_TYPEHASH(), index, recipient, mode));
        return _hashTypedData(vaultAddr, structHash);
    }

    function mfaDigest(address vaultAddr, uint256 index, address recipient, uint256 deadline)
        internal
        view
        returns (bytes32)
    {
        bytes32 structHash =
            keccak256(abi.encode(EnvelopeLinks(payable(vaultAddr)).MFA_APPROVAL_TYPEHASH(), index, recipient, deadline));
        return _hashTypedData(vaultAddr, structHash);
    }

    function feeAuthDigest(
        address vaultAddr,
        address feePayer,
        EnvelopeLinks.LinkRequest memory request,
        uint256 serviceFee,
        uint256 gaslessFee,
        bool gaslessSponsored,
        uint256 deadline
    ) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                EnvelopeLinks(payable(vaultAddr)).FEE_AUTHORIZATION_TYPEHASH(),
                feePayer,
                request.tokenAddress,
                request.contractType,
                request.amount,
                request.tokenId,
                request.claimKey,
                request.onBehalfOf,
                request.withMFA,
                request.recipient,
                request.reclaimableAfter,
                serviceFee,
                gaslessFee,
                gaslessSponsored,
                deadline
            )
        );
        return _hashTypedData(vaultAddr, structHash);
    }

    function _hashTypedData(address vaultAddr, bytes32 structHash) private view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator(vaultAddr), structHash));
    }
}
