// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {ERC20Mock} from "../envelope/mocks/ERC20Mock.sol";
import {FundraiserFactory} from "../../src/fundraising/FundraiserFactory.sol";
import {Fundraiser} from "../../src/fundraising/Fundraiser.sol";
import {FundraiserParams, OnMissed, Status} from "../../src/fundraising/interfaces/FundraisingTypes.sol";

/// @notice Drives a single fundraise through random sequences of every public action.
/// @dev Calls are wrapped in try/catch: a revert is a legitimate outcome (wrong state,
///      latched, nothing to refund), and what matters is that the invariants hold after
///      whatever did succeed.
contract FundraiserHandler is Test {
    Fundraiser public f;
    ERC20Mock public token;
    address public beneficiary;
    address public organizer;
    address[] public actors;

    // ghosts
    bool public goalWasReached;
    uint256 public beneficiaryReceived;
    Status public lastStatus;
    bool public sawIllegalTransition;

    constructor(Fundraiser f_, ERC20Mock token_, address organizer_, address beneficiary_, address[] memory actors_) {
        f = f_;
        token = token_;
        organizer = organizer_;
        beneficiary = beneficiary_;
        actors = actors_;
        lastStatus = f_.status();
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _sync() internal {
        if (f.raised() >= f.goal()) goalWasReached = true;

        Status current = f.status();
        if (current != lastStatus) {
            bool legal = (lastStatus == Status.Funding && (current == Status.Succeeded || current == Status.Refunding))
                || (lastStatus == Status.Succeeded && current == Status.Closed);
            if (!legal) sawIllegalTransition = true;
            lastStatus = current;
        }
    }

    function deposit(uint256 actorSeed, uint96 amount) external {
        address a = _actor(actorSeed);
        uint256 value = bound(uint256(amount), 1, 500e6);
        vm.startPrank(a);
        token.approve(address(f), value);
        try f.deposit(value) {} catch {}
        vm.stopPrank();
        _sync();
    }

    function unpledge(uint256 actorSeed, uint96 amount) external {
        address a = _actor(actorSeed);
        uint256 value = bound(uint256(amount), 1, 500e6);
        vm.prank(a);
        try f.unpledge(value) {} catch {}
        _sync();
    }

    function finalize(uint256 warpBy) external {
        vm.warp(block.timestamp + bound(warpBy, 0, 10 days));
        try f.finalize() {} catch {}
        _sync();
    }

    function cancel() external {
        vm.prank(organizer);
        try f.cancel() {} catch {}
        _sync();
    }

    function withdraw() external {
        uint256 before = token.balanceOf(beneficiary);
        vm.prank(beneficiary);
        try f.withdraw() {} catch {}
        beneficiaryReceived += token.balanceOf(beneficiary) - before;
        _sync();
    }

    function refund(uint256 actorSeed) external {
        vm.prank(_actor(actorSeed));
        try f.refund() {} catch {}
        _sync();
    }

    function refundFor(uint256 actorSeed) external {
        try f.refundFor(_actor(actorSeed)) {} catch {}
        _sync();
    }

    function sumContributions() external view returns (uint256 total) {
        for (uint256 i = 0; i < actors.length; ++i) {
            total += f.contributions(actors[i]);
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }
}

contract InvariantsTest is Test {
    FundraiserFactory factory;
    ERC20Mock token;
    Fundraiser fundraiser;
    FundraiserHandler handler;

    address admin = makeAddr("admin");
    address organizer = makeAddr("organizer");
    address beneficiary = makeAddr("beneficiary");

    uint128 constant GOAL = 1_000e6;

    function setUp() public {
        token = new ERC20Mock();
        address[] memory allowed = new address[](1);
        allowed[0] = address(token);
        factory = new FundraiserFactory(admin, 0, address(0), allowed);

        address[] memory actors = new address[](4);
        actors[0] = makeAddr("a1");
        actors[1] = makeAddr("a2");
        actors[2] = makeAddr("a3");
        actors[3] = makeAddr("a4");
        for (uint256 i = 0; i < actors.length; ++i) {
            token.mint(actors[i], 10_000e6);
        }

        vm.prank(organizer);
        fundraiser = Fundraiser(
            factory.createFundraiser(
                FundraiserParams({
                    name: "invariant fundraise",
                    token: address(token),
                    goal: GOAL,
                    deadline: uint40(block.timestamp + 30 days),
                    onMissed: OnMissed.Refund,
                    beneficiary: beneficiary,
                    minContribution: 0,
                    maxTotalContributions: 0
                }),
                bytes32("inv")
            )
        );

        handler = new FundraiserHandler(fundraiser, token, organizer, beneficiary, actors);
        targetContract(address(handler));
    }

    /// @dev What the contract records as owed matches what contributors are individually
    ///      owed. Any drift here is a bookkeeping bug that would surface as a refund that cannot be
    ///      refund.
    function invariant_contributionsSumToRaisedMinusRefunded() public view {
        assertEq(handler.sumContributions(), fundraiser.raised() - fundraiser.refunded());
    }

    /// @dev Solvency: the contract always holds at least what it still owes.
    function invariant_balanceCoversOutstandingLiability() public view {
        assertGe(token.balanceOf(address(fundraiser)), fundraiser.outstandingLiability());
    }

    /// @dev The goal latch, as a property rather than a boundary case: once reached, never
    ///      released.
    function invariant_goalOnceReachedStaysReached() public view {
        if (handler.goalWasReached()) {
            assertGe(fundraiser.raised(), fundraiser.goal());
            assertFalse(fundraiser.canUnpledge());
        }
    }

    /// @dev The exit is open exactly while the fundraise is collecting and below target.
    function invariant_canUnpledgeMatchesTheRule() public view {
        assertEq(
            fundraiser.canUnpledge(), fundraiser.status() == Status.Funding && fundraiser.raised() < fundraiser.goal()
        );
    }

    /// @dev Money reaches the beneficiary only through a successful raise.
    function invariant_beneficiaryOnlyPaidOnSuccess() public view {
        if (handler.beneficiaryReceived() > 0) {
            assertTrue(fundraiser.status() == Status.Closed);
            assertFalse(handler.sawIllegalTransition());
        }
    }

    function invariant_refundedNeverExceedsRaised() public view {
        assertLe(fundraiser.refunded(), fundraiser.raised());
    }

    function invariant_statusOnlyMovesAlongLegalEdges() public view {
        assertFalse(handler.sawIllegalTransition());
    }
}
