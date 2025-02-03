// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import {ClickBounty} from "../../src/contentsign/ClickBounty.sol";
import {BaseContentSign} from "../../src/contentsign/BaseContentSign.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Errors, IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import "../__helpers__/AccessControlUtils.sol";

contract MockERC20 is ERC20 {
    constructor(uint256 deployMeAward) ERC20("MockToken", "MTK") {
        _mint(msg.sender, deployMeAward);
    }
}

contract MockContentSign is BaseContentSign {
    constructor() BaseContentSign("MockContentSign", "MCS") {}

    function _userIsWhitelisted(address) internal pure override returns (bool) {
        return true;
    }
}

contract ClickBountyTest is Test {
    using AccessControlUtils for Vm;

    ClickBounty public clickBounty;
    MockERC20 public token;
    MockContentSign public contentSign;

    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");
    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;

    uint256 public constant INITIAL_FEE = 100;

    address public admin = address(0xA1);
    address public oracle = address(0xB1);
    address public user1 = address(0xC1);
    address public user2 = address(0xC2);

    function setUp() public {
        token = new MockERC20(1000 * INITIAL_FEE);
        contentSign = new MockContentSign();
        clickBounty = new ClickBounty(oracle, address(token), address(contentSign), INITIAL_FEE, admin);

        // Let user have enough tokens to pay for fees
        token.transfer(user1, 100 * INITIAL_FEE);
        // Let clickBounty have an initial budget
        token.transfer(address(clickBounty), 200 * INITIAL_FEE);
    }

    function testRolesAssigned() public view {
        bool adminHasRole = clickBounty.hasRole(DEFAULT_ADMIN_ROLE, admin);
        assertTrue(adminHasRole, "Admin should have DEFAULT_ADMIN_ROLE");

        bool oracleHasRole = clickBounty.hasRole(ORACLE_ROLE, oracle);
        assertTrue(oracleHasRole, "Oracle should have ORACLE_ROLE");
    }

    function testInitialState() public view {
        uint256 fee = clickBounty.entryFee();
        assertEq(fee, INITIAL_FEE, "Initial entry fee must be 100");

        (ClickBounty.URIBounty[] memory lb) = clickBounty.getLeaderboard();
        assertEq(lb.length, 0, "Initial leaderboard should be empty");
    }

    function testSetEntryFeeByAdmin() public {
        vm.prank(admin);
        clickBounty.setEntryFee(500);

        assertEq(clickBounty.entryFee(), 500, "Entry fee should update to 500");
    }

    function testSetEntryFeeFailNotAdmin() public {
        vm.expectRevert_AccessControlUnauthorizedAccount(user1, DEFAULT_ADMIN_ROLE);
        vm.prank(user1);
        clickBounty.setEntryFee(300);
    }

    function testWithdrawByAdmin() public {
        uint256 depositAmount = 500;
        token.approve(address(clickBounty), depositAmount);
        token.transfer(address(clickBounty), depositAmount);

        vm.prank(admin);
        clickBounty.withdraw(user2, depositAmount);

        uint256 user2Balance = token.balanceOf(user2);
        assertEq(user2Balance, depositAmount, "user2 balance should reflect withdrawn amount");
    }

    function testWithdrawFailNotAdmin() public {
        vm.expectRevert_AccessControlUnauthorizedAccount(user1, DEFAULT_ADMIN_ROLE);
        vm.prank(user1);
        clickBounty.withdraw(user1, 500);
    }

    function testAwardBountyFailsIfNotOracle() public {
        vm.prank(user1);
        vm.expectRevert_AccessControlUnauthorizedAccount(user1, ORACLE_ROLE);
        clickBounty.awardBounty(1, 500);
    }

    function testAwardBountyFailsZeroAmount() public {
        contentSign.safeMint(user1, "tokenURI_100");
        uint256 tokenId = contentSign.nextTokenId() - 1;

        vm.prank(oracle);
        vm.expectRevert(abi.encodeWithSelector(ClickBounty.ZeroBounty.selector, tokenId));
        clickBounty.awardBounty(tokenId, 0);
    }

    function testAwardBountyAmountMatchingEntryFee() public {
        contentSign.safeMint(user1, "tokenURIAwardMatchingFee");
        uint256 tokenId = contentSign.nextTokenId() - 1;
        uint256 fee = clickBounty.entryFee();

        vm.startPrank(user1);
        token.approve(address(clickBounty), fee);
        (bool feePaidBeforeCharge,) = clickBounty.bounties(tokenId);
        assertEq(feePaidBeforeCharge, false);
        clickBounty.payEntryFee(tokenId);
        (bool feePaidAfterCharge,) = clickBounty.bounties(tokenId);
        assertEq(feePaidAfterCharge, true);
        vm.stopPrank();

        vm.prank(oracle);
        clickBounty.awardBounty(tokenId, fee);

        (, uint256 bountyAmount) = clickBounty.bounties(tokenId);
        assertEq(bountyAmount, fee, "Bounty must be given to token owner");
    }

    function testAwardBountyAmountLessThanFee() public {
        contentSign.safeMint(user1, "tokenURIAmountLessThanFee");
        uint256 tokenId = contentSign.nextTokenId() - 1;
        uint256 fee = clickBounty.entryFee();

        vm.startPrank(user1);
        token.approve(address(clickBounty), fee);
        uint256 contractBalanceBeforeAward = token.balanceOf(address(clickBounty));
        uint256 user1BalanceBeforeAward = token.balanceOf(user1);
        clickBounty.payEntryFee(tokenId);
        vm.stopPrank();

        vm.prank(oracle);
        clickBounty.awardBounty(tokenId, fee - 1);

        assertEq(token.balanceOf(address(clickBounty)), contractBalanceBeforeAward + 1, "Pool should increase by 1");
        assertEq(token.balanceOf(user1), user1BalanceBeforeAward - 1, "User1 should have been refunded partially");
    }

    function testAwardBountyAmountWhenFeeNotPaid() public {
        contentSign.safeMint(user1, "tokenURIAmountLessThanFeeNoApproval");
        uint256 tokenId = contentSign.nextTokenId() - 1;
        uint256 fee = clickBounty.entryFee();

        vm.prank(oracle);
        vm.expectRevert(abi.encodeWithSelector(ClickBounty.FeeNotPaid.selector, tokenId));
        clickBounty.awardBounty(tokenId, fee - 1);
    }

    function testAwardBountyAmountGreaterThanFee() public {
        contentSign.safeMint(user1, "tokenURIAmountGreaterThanFee");
        uint256 tokenId = contentSign.nextTokenId() - 1;
        uint256 fee = clickBounty.entryFee();

        uint256 contractBalanceBeforeAward = token.balanceOf(address(clickBounty));
        uint256 user1BalanceBeforeAward = token.balanceOf(user1);

        vm.startPrank(user1);
        token.approve(address(clickBounty), fee);
        clickBounty.payEntryFee(tokenId);
        vm.stopPrank();

        vm.prank(oracle);
        clickBounty.awardBounty(tokenId, fee + 1);

        assertEq(token.balanceOf(address(clickBounty)), contractBalanceBeforeAward - 1, "Pool should decrease by 1");
        assertEq(token.balanceOf(user1), user1BalanceBeforeAward + 1, "User1 should have been refunded partially");
    }

    function testAwardBountyFailsIFTokenAlreadyPaid() public {
        contentSign.safeMint(user1, "tokenURIAlreadyPaid");
        uint256 tokenId = contentSign.nextTokenId() - 1;
        uint256 fee = clickBounty.entryFee();

        vm.startPrank(user1);
        token.approve(address(clickBounty), fee);
        clickBounty.payEntryFee(tokenId);
        vm.stopPrank();

        vm.prank(oracle);
        clickBounty.awardBounty(tokenId, fee);

        vm.prank(oracle);
        vm.expectRevert(abi.encodeWithSelector(ClickBounty.BountyAlreadyPaid.selector, tokenId));
        clickBounty.awardBounty(tokenId, fee);
    }

    function testPayEntryFeeFailsIfTokenDoesNotExist() public {
        uint256 randomNonExistingTokenId = 1451;

        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, randomNonExistingTokenId));
        clickBounty.payEntryFee(randomNonExistingTokenId);
    }

    function testPayEntryFeeFailsIfNotEnoughAllowance() public {
        contentSign.safeMint(user1, "tokenURIInsufficientAllowance");
        uint256 tokenId = contentSign.nextTokenId() - 1;
        uint256 fee = clickBounty.entryFee();

        vm.startPrank(user1);
        token.approve(address(clickBounty), fee - 1);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(clickBounty), fee - 1, fee)
        );
        clickBounty.payEntryFee(tokenId);
        vm.stopPrank();
    }

    function testPayEntryFeeFailsIfNonOwner() public {
        contentSign.safeMint(user1, "tokenURINotOwner");
        uint256 tokenId = contentSign.nextTokenId() - 1;
        uint256 fee = clickBounty.entryFee();

        vm.prank(user1);
        token.approve(address(clickBounty), fee);

        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(ClickBounty.OnlyOwnerCanPayEntryFee.selector, tokenId));
        clickBounty.payEntryFee(tokenId);
    }

    function testpayEntryFeeFailsIfFeeAlreadyPaid() public {
        contentSign.safeMint(user1, "tokenURIAlreadyPaid");
        uint256 tokenId = contentSign.nextTokenId() - 1;
        uint256 fee = clickBounty.entryFee();

        vm.startPrank(user1);
        token.approve(address(clickBounty), 2 * fee);
        clickBounty.payEntryFee(tokenId);
        vm.expectRevert(abi.encodeWithSelector(ClickBounty.FeeAlreadyPaid.selector, tokenId));
        clickBounty.payEntryFee(tokenId);
        vm.stopPrank();
    }

    function testLeaderboardReplacement() public {
        uint256 lb_size = clickBounty.LEADERBOARD_SIZE();
        uint256 tokenId = contentSign.nextTokenId();

        ClickBounty _clickBounty = new ClickBounty(oracle, address(token), address(contentSign), INITIAL_FEE, admin);
        (ClickBounty.URIBounty[] memory initialLeaderboard) = clickBounty.getLeaderboard();
        assertEq(initialLeaderboard.length, 0, "Leaderboard should have 0 entries initially");

        token.transfer(address(_clickBounty), 10000);

        vm.prank(user1);
        token.approve(address(_clickBounty), 10 * INITIAL_FEE);

        for (uint256 i = 1; i <= lb_size; i++) {
            contentSign.safeMint(user1, string.concat("tokenURI_", vm.toString(i)));
            vm.prank(user1);
            _clickBounty.payEntryFee(tokenId);
            vm.prank(oracle);
            _clickBounty.awardBounty(tokenId++, 100 * i);
        }

        (ClickBounty.URIBounty[] memory lb) = _clickBounty.getLeaderboard();
        assertEq(lb.length, lb_size, "Leaderboard should be full");

        {
            // Bounties we expect: 100, 200, 300, 400, 500
            bool has100;
            bool has200;
            bool has300;
            bool has400;
            bool has500;
            for (uint256 i = 0; i < lb_size; i++) {
                uint256 bountyValue = lb[i].bounty;
                if (bountyValue == 100) has100 = true;
                if (bountyValue == 200) has200 = true;
                if (bountyValue == 300) has300 = true;
                if (bountyValue == 400) has400 = true;
                if (bountyValue == 500) has500 = true;
            }
            assertTrue(has100 && has200 && has300 && has400 && has500, "Expected bounties not found in leaderboard");
        }

        // This token's bounty should replace the token with 100 bounty
        contentSign.safeMint(user1, "tokenURI_6");
        vm.prank(user1);
        _clickBounty.payEntryFee(tokenId);
        vm.prank(oracle);
        _clickBounty.awardBounty(tokenId++, 250);

        // This token's bounty should not be enough to replace the new minimum which is 200
        contentSign.safeMint(user1, "tokenURI_7");
        vm.prank(user1);
        _clickBounty.payEntryFee(tokenId);
        vm.prank(oracle);
        _clickBounty.awardBounty(tokenId++, 170);

        (ClickBounty.URIBounty[] memory lbFinal) = _clickBounty.getLeaderboard();
        assertEq(lbFinal.length, lb_size, "Leaderboard should remain full");

        {
            // Bounties we expect: 200, 250, 300, 400, 500
            bool has200;
            bool has250;
            bool has300;
            bool has400;
            bool has500;
            for (uint256 i = 0; i < lb_size; i++) {
                uint256 bountyValue = lbFinal[i].bounty;
                if (bountyValue == 200) has200 = true;
                if (bountyValue == 250) has250 = true;
                if (bountyValue == 300) has300 = true;
                if (bountyValue == 400) has400 = true;
                if (bountyValue == 500) has500 = true;
            }
            assertTrue(has200 && has250 && has300 && has400 && has500, "Expected bounties not found in leaderboard");
        }
    }
}
