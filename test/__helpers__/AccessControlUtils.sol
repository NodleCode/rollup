// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.20;

import {Vm} from "forge-std/Vm.sol";
import {IAccessControl} from "openzeppelin-contracts/contracts/access/IAccessControl.sol";

library AccessControlUtils {
    function expectRevert_AccessControlUnauthorizedAccount(
        Vm vm,
        address user,
        bytes32 role
    ) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                user,
                role
            )
        );
    }
}
