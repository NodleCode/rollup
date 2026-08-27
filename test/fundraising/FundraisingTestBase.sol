// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {ERC20Mock} from "../envelope/mocks/ERC20Mock.sol";
import {FundraiserFactory} from "../../src/fundraising/FundraiserFactory.sol";
import {Fundraiser} from "../../src/fundraising/Fundraiser.sol";
import {IFundraiser} from "../../src/fundraising/interfaces/IFundraiser.sol";
import {IFundraiserFactory} from "../../src/fundraising/interfaces/IFundraiserFactory.sol";
import {FundraiserParams, OnMissed, Status} from "../../src/fundraising/interfaces/FundraisingTypes.sol";

/// @notice Shared fixture: a factory, an allow-listed token, and named actors.
abstract contract FundraisingTestBase is Test {
    FundraiserFactory internal factory;
    ERC20Mock internal token;

    address internal admin = makeAddr("admin");
    address internal organizer = makeAddr("organizer");
    address internal beneficiary = makeAddr("beneficiary");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal stranger = makeAddr("stranger");
    address internal feeSink = makeAddr("feeSink");

    uint128 internal constant GOAL = 1_000e6;
    uint256 internal constant FUNDED = 10_000e6;

    function setUp() public virtual {
        token = new ERC20Mock();
        address[] memory allowed = new address[](1);
        allowed[0] = address(token);
        factory = new FundraiserFactory(admin, 0, address(0), allowed);

        address[6] memory actors = [alice, bob, carol, stranger, organizer, beneficiary];
        for (uint256 i = 0; i < actors.length; ++i) {
            token.mint(actors[i], FUNDED);
        }
    }

    // ── fixture helpers ───────────────────────────

    function defaultParams() internal view returns (FundraiserParams memory) {
        return FundraiserParams({
            name: "Lisbon trip, March",
            token: address(token),
            goal: GOAL,
            deadline: uint40(block.timestamp + 30 days),
            onMissed: OnMissed.Refund,
            beneficiary: beneficiary,
            minContribution: 0,
            maxTotalContributions: 0
        });
    }

    function create(FundraiserParams memory p) internal returns (Fundraiser) {
        vm.prank(organizer);
        return Fundraiser(factory.createFundraiser(p, bytes32("group-1")));
    }

    function createDefault() internal returns (Fundraiser) {
        return create(defaultParams());
    }

    function deposit(Fundraiser f, address who, uint256 amount) internal {
        vm.startPrank(who);
        IERC20Like(f.token()).approve(address(f), amount);
        f.deposit(amount);
        vm.stopPrank();
    }

    function balanceOf(Fundraiser f, address who) internal view returns (uint256) {
        return IERC20Like(f.token()).balanceOf(who);
    }
}

interface IERC20Like {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}
