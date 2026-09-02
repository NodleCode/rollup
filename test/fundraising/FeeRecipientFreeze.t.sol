// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.26;

import "./FundraisingTestBase.sol";
import {BlocklistERC20} from "./mocks/BlocklistERC20.sol";

/// @notice The fee recipient must never sit on the beneficiary's critical path.
/// @dev Paying the fee inline made a blocked recipient able to strand the whole pot,
///      recoverable only by an admin rotating the recipient — which put resolution behind
///      admin cooperation, the one dependency this design exists to remove. The fee is now
///      accrued and pulled separately.
contract FeeRecipientFreezeTest is FundraisingTestBase {
    BlocklistERC20 internal blk;

    function _feeBearingFundraise() internal returns (Fundraiser f) {
        blk = new BlocklistERC20();
        vm.prank(admin);
        factory.setTokenAllowed(address(blk), true);
        blk.mint(alice, FUNDED);

        vm.prank(admin);
        factory.setFeeParams(100, feeSink); // 1%, as deployed

        FundraiserParams memory p = defaultParams();
        p.token = address(blk);
        f = create(p);

        vm.startPrank(alice);
        blk.approve(address(f), GOAL);
        f.deposit(GOAL);
        vm.stopPrank();
        f.finalize();
    }

    /// @dev The case that used to brick the pot forever.
    function test_blockedFeeRecipientCannotStopTheBeneficiaryBeingPaid() public {
        Fundraiser f = _feeBearingFundraise();
        blk.setBlocked(feeSink, true);

        vm.prank(beneficiary);
        f.withdraw();

        assertEq(blk.balanceOf(beneficiary), GOAL - 10e6, "beneficiary paid in full");
        assertEq(uint8(f.status()), uint8(Status.Closed));
        assertEq(f.feeOwed(), 10e6, "fee accrued, not lost");

        // Collecting still fails while the recipient is blocked — but that costs the
        // protocol its fee and nobody else anything.
        vm.expectRevert(abi.encodeWithSelector(BlocklistERC20.Blocked.selector, feeSink));
        f.collectFee();
    }

    /// @dev And the fee is recoverable once the recipient can receive again.
    function test_feeIsCollectableAfterTheRecipientIsRotated() public {
        Fundraiser f = _feeBearingFundraise();
        blk.setBlocked(feeSink, true);
        vm.prank(beneficiary);
        f.withdraw();

        address newSink = makeAddr("newSink");
        vm.prank(admin);
        factory.setFeeParams(100, newSink);

        f.collectFee(); // anyone may call; funds go to the recipient
        assertEq(blk.balanceOf(newSink), 10e6);
        assertEq(f.feeOwed(), 0);

        vm.expectRevert(IFundraiser.NoFeeOwed.selector);
        f.collectFee();
    }

    /// @dev An uncollected fee is owed, so the admin cannot sweep it as surplus.
    function test_uncollectedFeeIsNotSurplus() public {
        Fundraiser f = _feeBearingFundraise();
        vm.prank(beneficiary);
        f.withdraw();
        assertEq(f.feeOwed(), 10e6);

        vm.prank(admin);
        vm.expectRevert(IFundraiser.NoSurplus.selector);
        f.rescueSurplus(address(blk), admin);
    }

    /// @dev With no recipient configured the beneficiary keeps everything, as before.
    function test_noRecipientMeansNoFee() public {
        FundraiserParams memory p = defaultParams();
        Fundraiser f = create(p); // factory fee is 0 with a zero recipient
        deposit(f, alice, GOAL);
        f.finalize();

        vm.prank(beneficiary);
        f.withdraw();
        assertEq(balanceOf(f, beneficiary), FUNDED + GOAL);
        assertEq(f.feeOwed(), 0);
    }
}
