// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {VestingWallet} from "../../src/finance/VestingWallet.sol";
import {NODL} from "../../src/NODL.sol";

contract VestingWalletTest is Test {
    NODL private nodl;
    VestingWallet private vestingWallet;

    address internal alice;
    address internal bob;

    function setUp() public {
        alice = vm.addr(1);
        bob = vm.addr(2);
        vm.startPrank(alice);

        nodl = new NODL();
        // this effectively is a grant of 1_000 NODL to the beneficiary,
        // vesting as 1 NODL per block for 1_000 blocks
        vestingWallet = new VestingWallet(IERC20(nodl), bob, 10, 1010);
        nodl.mint(address(vestingWallet), 1_000);

        vm.stopPrank();
    }

    function test_hasProperParameters() public {
        assertEq(vestingWallet.owner(), alice);
        assertEq(vestingWallet.beneficiary(), bob);
        assertEq(address(vestingWallet.token()), address(nodl));
        assertEq(vestingWallet.start(), 10);
        assertEq(vestingWallet.duration(), 1_010);
    }

    function test_cannotVestAmountEarly() public {
        assertEq(vestingWallet.vested(), 0);
        vm.expectRevert(VestingWallet.NoTokensAvailable.selector);
        vestingWallet.vest();
    }

    // function test_vest() public {}

    // vest tokens
    // revoke vesting
    // with cliff
}
