// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.26;

import "./FundraisingTestBase.sol";

/// @notice The factory's own surface: the allow-list, the fee parameters, the registry,
///         and the bounds on what an admin can reach.
contract FactoryTest is FundraisingTestBase {
    ERC20Mock internal otherToken;

    function setUp() public override {
        super.setUp();
        otherToken = new ERC20Mock();
    }

    // ──────────────────────────────────────────────
    // Allow-list
    // ──────────────────────────────────────────────

    function test_rejectsTokenNotOnAllowList() public {
        FundraiserParams memory p = defaultParams();
        p.token = address(otherToken);
        vm.expectRevert(abi.encodeWithSelector(IFundraiserFactory.TokenNotAllowed.selector, address(otherToken)));
        create(p);
    }

    /// @dev De-listing must stop new fundraises choosing a token without becoming a freeze
    ///      switch over live ones.
    function test_deListingDoesNotTouchLiveFundraises() public {
        Fundraiser f = createDefault();
        deposit(f, alice, 400e6);

        vm.prank(admin);
        factory.setTokenAllowed(address(token), false);

        deposit(f, bob, 100e6); // deposits continue
        vm.prank(alice);
        f.unpledge(100e6); // so do withdrawals

        vm.prank(organizer);
        f.cancel();
        vm.prank(bob);
        f.refund(); // and refunds

        assertEq(balanceOf(f, bob), FUNDED);

        // but a new one cannot be created with it
        vm.expectRevert(abi.encodeWithSelector(IFundraiserFactory.TokenNotAllowed.selector, address(token)));
        create(defaultParams());
    }

    // ──────────────────────────────────────────────
    // Fees
    // ──────────────────────────────────────────────

    /// @dev The property that makes the fee safe: a later rate change cannot reach a
    ///      fundraise whose contributors already committed under the old one.
    function test_feeRateIsSnapshotAtCreation() public {
        vm.prank(admin);
        factory.setFeeParams(100, feeSink); // 1%

        Fundraiser f = createDefault();
        assertEq(f.feeBps(), 100);

        vm.prank(admin);
        factory.setFeeParams(500, feeSink); // raised afterward
        assertEq(f.feeBps(), 100, "in-flight fundraise must keep its rate");

        deposit(f, alice, GOAL);
        f.finalize();
        vm.prank(beneficiary);
        f.withdraw();
        f.collectFee();

        assertEq(balanceOf(f, feeSink), 10e6); // 1%, not 5%
    }

    /// @dev The recipient is read live, so a lost collection key can be rotated without
    ///      touching live fundraises. It cannot change how much anyone receives.
    function test_feeRecipientIsReadLive() public {
        vm.prank(admin);
        factory.setFeeParams(100, feeSink);

        Fundraiser f = createDefault();
        deposit(f, alice, GOAL);
        f.finalize();

        address newSink = makeAddr("newSink");
        vm.prank(admin);
        factory.setFeeParams(100, newSink);

        vm.prank(beneficiary);
        f.withdraw();
        f.collectFee();

        // Collection reads the recipient live, so a rotation still redirects the fee —
        // without the recipient ever sitting on the beneficiary's critical path.
        assertEq(balanceOf(f, newSink), 10e6);
        assertEq(balanceOf(f, feeSink), 0);
    }

    function test_feeCapIsEnforced() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IFundraiserFactory.FeeTooHigh.selector, uint16(501), uint16(500)));
        factory.setFeeParams(501, feeSink);

        vm.prank(admin);
        factory.setFeeParams(500, feeSink); // exactly at the cap is fine
        assertEq(factory.feeBps(), 500);
    }

    function test_rejectsNonZeroFeeWithNoRecipient() public {
        vm.prank(admin);
        vm.expectRevert(IFundraiserFactory.ZeroAddress.selector);
        factory.setFeeParams(100, address(0));
    }

    // ──────────────────────────────────────────────
    // Admin bounds
    // ──────────────────────────────────────────────

    function test_adminFunctionsAreGated() public {
        vm.prank(alice);
        vm.expectRevert();
        factory.setTokenAllowed(address(otherToken), true);

        vm.prank(alice);
        vm.expectRevert();
        factory.setFeeParams(10, feeSink);
    }

    /// @dev The admin has no lever over a live fundraise at all.
    function test_adminCannotTouchALiveFundraise() public {
        Fundraiser f = createDefault();
        deposit(f, alice, 400e6);

        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(IFundraiser.NotOrganizer.selector, admin));
        f.cancel();
        vm.expectRevert(abi.encodeWithSelector(IFundraiser.InvalidState.selector, Status.Funding));
        f.withdraw();
        vm.stopPrank();
    }

    // ──────────────────────────────────────────────
    // Surplus rescue
    // ──────────────────────────────────────────────

    function test_rescueSurplus_onlyReachesNonEscrowFunds() public {
        Fundraiser f = createDefault();
        deposit(f, alice, 400e6);

        token.mint(address(f), 25e6); // a mis-send

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IFundraiser.NotFactoryAdmin.selector, alice));
        f.rescueSurplus(address(token), alice);

        vm.prank(admin);
        f.rescueSurplus(address(token), admin);

        assertEq(balanceOf(f, admin), 25e6);
        assertEq(balanceOf(f, address(f)), 400e6, "escrow untouched");
        assertEq(f.contributions(alice), 400e6);

        vm.prank(admin);
        vm.expectRevert(IFundraiser.NoSurplus.selector);
        f.rescueSurplus(address(token), admin);
    }

    function test_unclaimedRefundsAreNeverSurplus() public {
        Fundraiser f = createDefault();
        deposit(f, alice, 400e6);
        vm.prank(organizer);
        f.cancel();

        vm.prank(admin);
        vm.expectRevert(IFundraiser.NoSurplus.selector);
        f.rescueSurplus(address(token), admin);

        // still true long after everyone has forgotten about it
        vm.warp(block.timestamp + 3650 days);
        vm.prank(admin);
        vm.expectRevert(IFundraiser.NoSurplus.selector);
        f.rescueSurplus(address(token), admin);
    }

    function test_rescueOfAnUnrelatedTokenTakesTheWholeBalance() public {
        Fundraiser f = createDefault();
        deposit(f, alice, 400e6);
        otherToken.mint(address(f), 77e6); // airdrop

        vm.prank(admin);
        f.rescueSurplus(address(otherToken), admin);
        assertEq(otherToken.balanceOf(admin), 77e6);
        assertEq(balanceOf(f, address(f)), 400e6);
    }

    // ──────────────────────────────────────────────
    // Registry
    // ──────────────────────────────────────────────

    function test_registryRecordsOnlyWhatItDeployed() public {
        Fundraiser f = createDefault();
        assertTrue(factory.isFundraiser(address(f)));
        assertFalse(factory.isFundraiser(address(0xdead)));
        assertFalse(factory.isFundraiser(address(token)));
    }
}
