// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.20;

import {BasePaymaster} from "../paymasters/BasePaymaster.sol";

contract MockPaymaster is BasePaymaster {
    event MockPaymasterCalled();

    constructor(
        address admin,
        address withdrawer
    ) BasePaymaster(admin, withdrawer) {}

    function _validateAndPayGeneralFlow(
        address,
        address,
        uint256
    ) internal override {
        // this is a mock, do nothing for now
        emit MockPaymasterCalled();
    }

    function _validateAndPayApprovalBasedFlow(
        address,
        address,
        address,
        uint256,
        bytes memory,
        uint256
    ) internal override {
        // this is a mock, do nothing for now
        emit MockPaymasterCalled();
    }
}
