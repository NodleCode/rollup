// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC20Mock} from "../envelope/mocks/ERC20Mock.sol";
import {FundraiserFactory} from "../../src/fundraising/FundraiserFactory.sol";
import {Fundraiser} from "../../src/fundraising/Fundraiser.sol";
import {IFundraiser} from "../../src/fundraising/interfaces/IFundraiser.sol";
import {IFundraiserFactory} from "../../src/fundraising/interfaces/IFundraiserFactory.sol";
import {FundraiserParams, OnMissed, Status} from "../../src/fundraising/interfaces/FundraisingTypes.sol";

/// @notice Smoke coverage for the factory while the full suite is still to come.
contract FundraiserFactorySmokeTest is Test {
    FundraiserFactory factory;
    ERC20Mock token;
    ERC20Mock otherToken;

    address admin = address(0xAD);
    address organizer = address(0x0A);
    address beneficiary = address(0xBE);
    address alice = address(0xA1);
    address feeSink = address(0xFEE);

    uint128 constant GOAL = 1_000e6;

    function setUp() public {
        token = new ERC20Mock();
        otherToken = new ERC20Mock();
        address[] memory allowed = new address[](1);
        allowed[0] = address(token);
        factory = new FundraiserFactory(admin, 0, address(0), allowed);
        token.mint(alice, 10_000e6);
    }

    function _params(uint128 goal) internal view returns (FundraiserParams memory) {
        return FundraiserParams({
            name: "Lisbon trip",
            token: address(token),
            goal: goal,
            deadline: uint40(block.timestamp + 30 days),
            onMissed: OnMissed.Refund,
            beneficiary: beneficiary,
            minContribution: 0,
            maxTotalContributions: 0
        });
    }

    function _create() internal returns (Fundraiser f) {
        vm.prank(organizer);
        f = Fundraiser(factory.createFundraiser(_params(GOAL), bytes32("group-1")));
    }

    function test_anyoneCanCreate_andRegistryRecordsIt() public {
        address nobody = address(0x9999);
        vm.prank(nobody);
        address f = factory.createFundraiser(_params(GOAL), bytes32("any-group"));

        assertTrue(factory.isFundraiser(f));
        assertEq(Fundraiser(f).organizer(), nobody);
        assertFalse(factory.isFundraiser(address(0xdead)));
    }

    function test_rejectsTokenNotOnAllowList() public {
        FundraiserParams memory p = _params(GOAL);
        p.token = address(otherToken);
        vm.expectRevert(abi.encodeWithSelector(IFundraiserFactory.TokenNotAllowed.selector, address(otherToken)));
        factory.createFundraiser(p, bytes32(0));
    }

    function test_deListingDoesNotFreezeLiveFundraises() public {
        Fundraiser f = _create();

        vm.prank(admin);
        factory.setTokenAllowed(address(token), false);

        // the live fundraise carries on regardless
        vm.startPrank(alice);
        token.approve(address(f), GOAL);
        f.deposit(GOAL);
        vm.stopPrank();
        assertEq(f.raised(), GOAL);
    }

    function test_feeRateIsSnapshotAtCreation() public {
        vm.prank(admin);
        factory.setFeeParams(100, feeSink); // 1%

        Fundraiser f = _create();
        assertEq(f.feeBps(), 100);

        // raising the global rate afterward must not reach this fundraise
        vm.prank(admin);
        factory.setFeeParams(500, feeSink);
        assertEq(f.feeBps(), 100);

        vm.startPrank(alice);
        token.approve(address(f), GOAL);
        f.deposit(GOAL);
        vm.stopPrank();

        f.finalize();
        vm.prank(beneficiary);
        f.withdraw();

        assertEq(token.balanceOf(feeSink), 10e6); // 1% of 1,000, not 5%
        assertEq(token.balanceOf(beneficiary), GOAL - 10e6);
    }

    function test_adminGating() public {
        vm.expectRevert();
        factory.setTokenAllowed(address(otherToken), true);

        vm.expectRevert();
        factory.setFeeParams(10, feeSink);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IFundraiserFactory.FeeTooHigh.selector, uint16(501), uint16(500)));
        factory.setFeeParams(501, feeSink);
    }

    function test_rescueSurplus_boundedToNonEscrowFunds() public {
        Fundraiser f = _create();

        vm.startPrank(alice);
        token.approve(address(f), 400e6);
        f.deposit(400e6);
        vm.stopPrank();

        // someone mis-sends straight to the contract
        token.mint(address(f), 25e6);

        vm.prank(address(0x1234));
        vm.expectRevert(abi.encodeWithSelector(IFundraiser.NotFactoryAdmin.selector, address(0x1234)));
        f.rescueSurplus(address(token), admin);

        vm.prank(admin);
        f.rescueSurplus(address(token), admin);

        assertEq(token.balanceOf(admin), 25e6); // only the mis-send moved
        assertEq(token.balanceOf(address(f)), 400e6); // the escrow is untouched
        assertEq(f.contributions(alice), 400e6);

        // nothing left over to take
        vm.prank(admin);
        vm.expectRevert(IFundraiser.NoSurplus.selector);
        f.rescueSurplus(address(token), admin);
    }

    function test_unclaimedRefundsAreNotSurplus() public {
        Fundraiser f = _create();

        vm.startPrank(alice);
        token.approve(address(f), 400e6);
        f.deposit(400e6);
        vm.stopPrank();

        vm.prank(organizer);
        f.cancel();
        assertEq(uint8(f.status()), uint8(Status.Refunding));

        // alice has not claimed; her money is a liability, not surplus
        vm.prank(admin);
        vm.expectRevert(IFundraiser.NoSurplus.selector);
        f.rescueSurplus(address(token), admin);
    }
}
