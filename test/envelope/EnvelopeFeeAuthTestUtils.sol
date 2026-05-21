// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {EnvelopeLinks} from "../../src/envelope/EnvelopeLinks.sol";
import {EnvelopeEIP712Utils} from "./EnvelopeEIP712Utils.sol";

library EnvelopeFeeAuthTestUtils {
    function feeAuthorizationDigest(
        address vaultAddr,
        EnvelopeLinks.LinkRequest memory request,
        address feePayer,
        uint256 serviceFee,
        uint256 gaslessFee,
        bool gaslessSponsored,
        uint256 deadline
    ) internal view returns (bytes32) {
        return EnvelopeEIP712Utils.feeAuthDigest(
            vaultAddr, feePayer, request, serviceFee, gaslessFee, gaslessSponsored, deadline
        );
    }
}