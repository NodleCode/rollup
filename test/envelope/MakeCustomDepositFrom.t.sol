// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

// Tests for makeCustomDepositFrom — operator-orchestrated deposits where the
// caller (operator) is not the funder. Token pull comes from `_from` via the
// standard transferFrom allowance path. Used in the Mode B paymaster flow.

import {Test} from "forge-std/Test.sol";
import {EnvelopeVault} from "../../src/envelope/V4/EnvelopeVault.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {ERC721Mock} from "./mocks/ERC721Mock.sol";
import {ERC1155Mock} from "./mocks/ERC1155Mock.sol";
import {L2ECOMock} from "./mocks/L2ECOMock.sol";
import {ERC721Holder} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";

contract MakeCustomDepositFromTest is Test, ERC721Holder, ERC1155Holder {
    EnvelopeVault public vault;
    ERC20Mock public erc20;
    ERC721Mock public erc721;
    ERC1155Mock public erc1155;
    L2ECOMock public eco;

    address constant OPERATOR = address(0x000000000000000000000000000000000000f0F0);
    address constant USER = address(0x000000000000000000000000000000000000a11c);
    address constant PUBKEY20 = address(0xaBC5211D86a01c2dD50797ba7B5b32e3C1167F9f);

    function setUp() public {
        eco = new L2ECOMock(1);
        vault = new EnvelopeVault(address(eco), address(0));
        erc20 = new ERC20Mock();
        erc721 = new ERC721Mock();
        erc1155 = new ERC1155Mock();
    }

    // ─── Happy paths ──────────────────────────────────────────────────────

    function test_ERC20_pullsFromUser_creditsOnBehalfOf() public {
        erc20.mint(USER, 100);
        vm.prank(USER);
        erc20.approve(address(vault), 100);

        vm.prank(OPERATOR);
        uint256 idx = vault.makeCustomDepositFrom(
            USER,            // _from   — tokens come from here
            address(erc20),  // _tokenAddress
            1,               // _contractType (ERC20)
            100,             // _amount
            0,               // _tokenId
            PUBKEY20,        // _pubKey20
            USER,            // _onBehalfOf — credited as senderAddress
            false,           // _withMFA
            address(0),      // _recipient
            0                // _reclaimableAfter
        );

        assertEq(erc20.balanceOf(USER), 0, "user balance drained");
        assertEq(erc20.balanceOf(address(vault)), 100, "vault holds the tokens");
        assertEq(erc20.balanceOf(OPERATOR), 0, "operator never touched the tokens");

        EnvelopeVault.Deposit memory d = vault.getDeposit(idx);
        assertEq(d.amount, 100);
        assertEq(d.senderAddress, USER, "senderAddress reflects _onBehalfOf, not msg.sender");
        assertEq(d.pubKey20, PUBKEY20);
    }

    function test_ERC20_canReclaimViaWithdrawDepositSender() public {
        erc20.mint(USER, 50);
        vm.prank(USER);
        erc20.approve(address(vault), 50);

        vm.prank(OPERATOR);
        uint256 idx = vault.makeCustomDepositFrom(
            USER, address(erc20), 1, 50, 0, PUBKEY20, USER, false, address(0), 0
        );

        // User reclaims using the senderAddress credential — operator can't reclaim.
        vm.prank(USER);
        bool ok = vault.withdrawDepositSender(idx);
        assertTrue(ok);
        assertEq(erc20.balanceOf(USER), 50, "user reclaimed");
    }

    function test_ERC721_pullsFromUser() public {
        erc721.mint(USER, 7);
        vm.prank(USER);
        erc721.approve(address(vault), 7);

        vm.prank(OPERATOR);
        vault.makeCustomDepositFrom(
            USER, address(erc721), 2, 1, 7, PUBKEY20, USER, false, address(0), 0
        );

        assertEq(erc721.ownerOf(7), address(vault));
    }

    function test_ERC1155_pullsFromUser() public {
        erc1155.mint(USER, 1, 500, "");
        vm.prank(USER);
        erc1155.setApprovalForAll(address(vault), true);

        vm.prank(OPERATOR);
        vault.makeCustomDepositFrom(
            USER, address(erc1155), 3, 200, 1, PUBKEY20, USER, false, address(0), 0
        );

        assertEq(erc1155.balanceOf(USER, 1), 300);
        assertEq(erc1155.balanceOf(address(vault), 1), 200);
    }

    function test_L2ECO_pullsFromUserAndScalesByMultiplier() public {
        eco.setMultiplier(3);
        eco.mint(USER, 1_000);
        vm.prank(USER);
        eco.approve(address(vault), 1_000);

        vm.prank(OPERATOR);
        uint256 idx = vault.makeCustomDepositFrom(
            USER, address(eco), 4, 1_000, 0, PUBKEY20, USER, false, address(0), 0
        );

        // contractType==4 stores amount * multiplier; recipient gets back amount/multiplier on withdraw.
        EnvelopeVault.Deposit memory d = vault.getDeposit(idx);
        assertEq(d.amount, 3_000, "stored amount scaled by multiplier");
        assertEq(eco.balanceOf(address(vault)), 1_000, "vault holds the underlying transferred amount");
    }

    // ─── Reverts ──────────────────────────────────────────────────────────

    function test_RevertWhen_FromIsZero() public {
        vm.prank(OPERATOR);
        vm.expectRevert(bytes("FROM MUST BE NONZERO"));
        vault.makeCustomDepositFrom(
            address(0), address(erc20), 1, 1, 0, PUBKEY20, USER, false, address(0), 0
        );
    }

    function test_RevertWhen_NoAllowance() public {
        erc20.mint(USER, 100);
        // No approve call.

        vm.prank(OPERATOR);
        vm.expectRevert(); // ERC20InsufficientAllowance from OZ v5
        vault.makeCustomDepositFrom(
            USER, address(erc20), 1, 100, 0, PUBKEY20, USER, false, address(0), 0
        );
    }

    function test_RevertWhen_InsufficientBalance() public {
        erc20.mint(USER, 10);
        vm.prank(USER);
        erc20.approve(address(vault), 100);

        vm.prank(OPERATOR);
        vm.expectRevert(); // ERC20InsufficientBalance from OZ v5
        vault.makeCustomDepositFrom(
            USER, address(erc20), 1, 100, 0, PUBKEY20, USER, false, address(0), 0
        );
    }

    function test_RevertWhen_ETHContractType() public {
        vm.prank(OPERATOR);
        vm.expectRevert(bytes("INVALID CONTRACT TYPE FOR FROM-DEPOSIT"));
        vault.makeCustomDepositFrom(
            USER, address(0), 0, 1 ether, 0, PUBKEY20, USER, false, address(0), 0
        );
    }

    function test_RevertWhen_InvalidContractType() public {
        vm.prank(OPERATOR);
        vm.expectRevert(bytes("INVALID CONTRACT TYPE FOR FROM-DEPOSIT"));
        vault.makeCustomDepositFrom(
            USER, address(erc20), 5, 1, 0, PUBKEY20, USER, false, address(0), 0
        );
    }

    function test_RevertWhen_ECOAsContractType1() public {
        eco.mint(USER, 100);
        vm.prank(USER);
        eco.approve(address(vault), 100);

        vm.prank(OPERATOR);
        vm.expectRevert(bytes("ECO DEPOSITS MUST USE _contractType 4"));
        vault.makeCustomDepositFrom(
            USER, address(eco), 1, 100, 0, PUBKEY20, USER, false, address(0), 0
        );
    }

    function test_RevertWhen_NoAuthorizationFields() public {
        erc20.mint(USER, 100);
        vm.prank(USER);
        erc20.approve(address(vault), 100);

        vm.prank(OPERATOR);
        vm.expectRevert(bytes("DEPOSIT MUST HAVE AUTH"));
        vault.makeCustomDepositFrom(
            USER, address(erc20), 1, 100, 0,
            address(0),  // no pubKey20
            USER,
            false,
            address(0),  // no recipient
            0
        );
    }

    // ─── Regression: original makeCustomDeposit semantics unchanged ────────

    function test_OriginalMakeCustomDepositStillPullsFromMsgSender() public {
        erc20.mint(OPERATOR, 100);
        vm.prank(OPERATOR);
        erc20.approve(address(vault), 100);

        vm.prank(OPERATOR);
        vault.makeCustomDeposit(
            address(erc20), 1, 100, 0, PUBKEY20,
            USER,        // _onBehalfOf
            false, address(0), 0,
            false, ""    // 3009 disabled
        );

        assertEq(erc20.balanceOf(OPERATOR), 0, "old function still pulls from msg.sender");
        assertEq(erc20.balanceOf(address(vault)), 100);
    }
}
