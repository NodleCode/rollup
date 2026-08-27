// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.26;

import "./FundraisingTestBase.sol";
import {FeeOnTransferERC20} from "./mocks/FeeOnTransferERC20.sol";
import {ReentrantERC20} from "./mocks/ReentrantERC20.sol";
import {BlocklistERC20} from "./mocks/BlocklistERC20.sol";

/// @notice Getting money back out, including against tokens that misbehave.
contract RefundsTest is FundraisingTestBase {
    function _allow(address t) internal {
        vm.prank(admin);
        factory.setTokenAllowed(t, true);
    }

    function _paramsFor(address t, uint128 goal) internal view returns (FundraiserParams memory p) {
        p = defaultParams();
        p.token = t;
        p.goal = goal;
    }

    // ──────────────────────────────────────────────
    // The ordinary path
    // ──────────────────────────────────────────────

    function test_refundReturnsExactlyWhatWasContributed() public {
        Fundraiser f = createDefault();
        deposit(f, alice, 250e6);
        vm.prank(organizer);
        f.cancel();

        vm.prank(alice);
        f.refund();
        assertEq(balanceOf(f, alice), FUNDED);
        assertEq(f.contributions(alice), 0);
    }

    function test_secondRefundReverts() public {
        Fundraiser f = createDefault();
        deposit(f, alice, 250e6);
        vm.prank(organizer);
        f.cancel();

        vm.prank(alice);
        f.refund();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IFundraiser.NothingToRefund.selector, alice));
        f.refund();
    }

    function test_refundForSendsToContributorNotCaller() public {
        Fundraiser f = createDefault();
        deposit(f, alice, 250e6);
        vm.prank(organizer);
        f.cancel();

        uint256 strangerBefore = balanceOf(f, stranger);
        vm.prank(stranger);
        f.refundFor(alice);

        assertEq(balanceOf(f, alice), FUNDED);
        assertEq(balanceOf(f, stranger), strangerBefore, "caller must not receive the funds");
    }

    function test_refundForNonContributorReverts() public {
        Fundraiser f = createDefault();
        deposit(f, alice, 250e6);
        vm.prank(organizer);
        f.cancel();

        vm.expectRevert(abi.encodeWithSelector(IFundraiser.NothingToRefund.selector, carol));
        f.refundFor(carol);
    }

    // ──────────────────────────────────────────────
    // Fee-on-transfer: the insolvency balance-delta crediting prevents
    // ──────────────────────────────────────────────

    /// @dev Every contributor must be able to get out, including the last one. Crediting
    ///      the requested amount instead of the received amount is what breaks this.
    function test_feeOnTransfer_allContributorsCanRefundIncludingTheLast() public {
        FeeOnTransferERC20 fot = new FeeOnTransferERC20(100); // 1% burned per transfer
        _allow(address(fot));
        fot.mint(alice, FUNDED);
        fot.mint(bob, FUNDED);
        fot.mint(carol, FUNDED);

        Fundraiser f = create(_paramsFor(address(fot), GOAL));

        deposit(f, alice, 300e6);
        deposit(f, bob, 300e6);
        deposit(f, carol, 300e6);

        // credited is the amount that arrived, not the amount sent
        assertEq(f.contributions(alice), 297e6);
        assertEq(f.raised(), 891e6);
        assertEq(fot.balanceOf(address(f)), 891e6);

        vm.prank(organizer);
        f.cancel();

        vm.prank(alice);
        f.refund();
        vm.prank(bob);
        f.refund();
        vm.prank(carol);
        f.refund(); // the last one out must not be short
        assertEq(fot.balanceOf(address(f)), 0);
    }

    function test_feeOnTransfer_goalMeasuredInReceivedUnits() public {
        FeeOnTransferERC20 fot = new FeeOnTransferERC20(100);
        _allow(address(fot));
        fot.mint(alice, FUNDED);

        Fundraiser f = create(_paramsFor(address(fot), GOAL));
        deposit(f, alice, GOAL); // 1% is burned, so this does not reach the goal
        assertEq(f.raised(), 990e6);
        assertTrue(f.canUnpledge());

        vm.expectRevert(IFundraiser.NotFinalizable.selector);
        f.finalize();
    }

    // ──────────────────────────────────────────────
    // Reentrancy on every exit path
    // ──────────────────────────────────────────────

    function test_reentrancy_blockedOnRefund() public {
        ReentrantERC20 ree = new ReentrantERC20();
        _allow(address(ree));
        ree.mint(alice, FUNDED);

        Fundraiser f = create(_paramsFor(address(ree), GOAL));
        deposit(f, alice, 300e6);
        vm.prank(organizer);
        f.cancel();

        ree.arm(address(f), abi.encodeCall(IFundraiser.refund, ()));
        vm.prank(alice);
        f.refund();

        assertTrue(ree.attempted(), "the mock should have tried to reenter");
        assertFalse(ree.succeeded(), "reentrancy must be refused");
        assertEq(ree.balanceOf(address(f)), 0);
    }

    function test_reentrancy_blockedOnUnpledge() public {
        ReentrantERC20 ree = new ReentrantERC20();
        _allow(address(ree));
        ree.mint(alice, FUNDED);

        Fundraiser f = create(_paramsFor(address(ree), GOAL));
        deposit(f, alice, 300e6);

        ree.arm(address(f), abi.encodeCall(IFundraiser.unpledge, (100e6)));
        vm.prank(alice);
        f.unpledge(100e6);

        assertTrue(ree.attempted());
        assertFalse(ree.succeeded());
        assertEq(f.contributions(alice), 200e6);
    }

    function test_reentrancy_blockedOnWithdraw() public {
        ReentrantERC20 ree = new ReentrantERC20();
        _allow(address(ree));
        ree.mint(alice, FUNDED);

        Fundraiser f = create(_paramsFor(address(ree), GOAL));
        deposit(f, alice, GOAL);
        f.finalize();

        ree.arm(address(f), abi.encodeCall(IFundraiser.withdraw, ()));
        vm.prank(beneficiary);
        f.withdraw();

        assertTrue(ree.attempted());
        assertFalse(ree.succeeded());
        assertEq(ree.balanceOf(beneficiary), GOAL);
    }

    // ──────────────────────────────────────────────
    // Blocklisting
    // ──────────────────────────────────────────────

    /// @dev A blocked beneficiary would otherwise strand the entire raise. Only the
    ///      beneficiary itself can repoint, so this adds no custody.
    function test_blockedBeneficiaryRecoversViaSetPayoutAddress() public {
        BlocklistERC20 blk = new BlocklistERC20();
        _allow(address(blk));
        blk.mint(alice, FUNDED);

        Fundraiser f = create(_paramsFor(address(blk), GOAL));
        deposit(f, alice, GOAL);
        f.finalize();

        blk.setBlocked(beneficiary, true);
        vm.prank(beneficiary);
        vm.expectRevert(abi.encodeWithSelector(BlocklistERC20.Blocked.selector, beneficiary));
        f.withdraw();

        address rescue = makeAddr("rescuePayout");
        vm.prank(beneficiary);
        f.setPayoutAddress(rescue);
        vm.prank(rescue);
        f.withdraw();

        assertEq(blk.balanceOf(rescue), GOAL);
    }

    /// @dev A blocked contributor's funds stay put. That is the token's behavior, not
    ///      something the escrow should add an admin bypass for.
    function test_blockedContributorCannotRefund_othersUnaffected() public {
        BlocklistERC20 blk = new BlocklistERC20();
        _allow(address(blk));
        blk.mint(alice, FUNDED);
        blk.mint(bob, FUNDED);

        Fundraiser f = create(_paramsFor(address(blk), GOAL));
        deposit(f, alice, 300e6);
        deposit(f, bob, 200e6);

        vm.prank(organizer);
        f.cancel();

        blk.setBlocked(alice, true);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BlocklistERC20.Blocked.selector, alice));
        f.refund();

        vm.prank(bob);
        f.refund();
        assertEq(blk.balanceOf(bob), FUNDED);
        assertEq(f.contributions(alice), 300e6, "still owed");
    }
}
