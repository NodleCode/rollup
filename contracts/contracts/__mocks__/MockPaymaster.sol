// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.20;

import "../paymasters/BasePaymaster.sol";

contract MockPaymaster is BasePaymaster {
    constructor(address admin, address withdrawer) BasePaymaster(admin, withdrawer) {}

    function _validateAndPayGeneralFlow(
        address from,
        address to,
        uint256 requiredETH
    ) internal override {
        // this is a mock, do nothing for now
    }

    function _validateAndPayApprovalBasedFlow(
        address from,
        address to,
        address token,
        uint256 tokenAmount,
        bytes memory data,
        uint256 requiredETH
    ) internal override {
        // this is a mock, do nothing for now
    }
}
