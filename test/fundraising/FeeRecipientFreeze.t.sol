// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.26;

import "./FundraisingTestBase.sol";
import {BlocklistERC20} from "./mocks/BlocklistERC20.sol";

/// @notice Can a blocked fee recipient prevent a beneficiary being paid?
contract FeeRecipientFreezeTest is FundraisingTestBase {
    function test_blockedFeeRecipient_bricksWithdrawForever() public {
        BlocklistERC20 blk = new BlocklistERC20();
        vm.prank(admin);
        factory.setTokenAllowed(address(blk), true);
        blk.mint(alice, FUNDED);

        // 1% fee, as deployed on mainnet
        vm.prank(admin);
        factory.setFeeParams(100, feeSink);

        FundraiserParams memory p = defaultParams();
        p.token = address(blk);
        Fundraiser f = create(p);
        assertEq(f.feeBps(), 100);

        vm.startPrank(alice);
        blk.approve(address(f), GOAL);
        f.deposit(GOAL);
        vm.stopPrank();
        f.finalize();
        assertEq(uint8(f.status()), uint8(Status.Succeeded));

        // The fee recipient becomes unable to receive the token.
        blk.setBlocked(feeSink, true);

        vm.prank(beneficiary);
        vm.expectRevert(abi.encodeWithSelector(BlocklistERC20.Blocked.selector, feeSink));
        f.withdraw();

        // The beneficiary is not blocked and is owed the money, but cannot take it.
        assertEq(blk.balanceOf(beneficiary), 0);
        assertEq(blk.balanceOf(address(f)), GOAL, "the whole pot is stuck");

        // setPayoutAddress does not help: it is the fee leg that reverts.
        address rescue = makeAddr("rescue");
        vm.prank(beneficiary);
        f.setPayoutAddress(rescue);
        vm.prank(rescue);
        vm.expectRevert(abi.encodeWithSelector(BlocklistERC20.Blocked.selector, feeSink));
        f.withdraw();
    }

    /// @dev And the admin can lift it — which is the part that matters: resolution now
    ///      depends on admin cooperation, which the design says it never does.
    function test_adminRotatingTheRecipientUnsticksIt() public {
        BlocklistERC20 blk = new BlocklistERC20();
        vm.prank(admin);
        factory.setTokenAllowed(address(blk), true);
        blk.mint(alice, FUNDED);
        vm.prank(admin);
        factory.setFeeParams(100, feeSink);

        FundraiserParams memory p = defaultParams();
        p.token = address(blk);
        Fundraiser f = create(p);

        vm.startPrank(alice);
        blk.approve(address(f), GOAL);
        f.deposit(GOAL);
        vm.stopPrank();
        f.finalize();

        blk.setBlocked(feeSink, true);
        vm.prank(beneficiary);
        vm.expectRevert();
        f.withdraw();

        address newSink = makeAddr("newSink");
        vm.prank(admin);
        factory.setFeeParams(100, newSink);

        vm.prank(beneficiary);
        f.withdraw();
        assertEq(blk.balanceOf(beneficiary), GOAL - 10e6);
    }
}
