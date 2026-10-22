// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {ERC1155Supply} from "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155Supply.sol";
import {ERC2981} from "@openzeppelin/contracts/token/common/ERC2981.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {Tipping} from "../../src/tipping/Tipping.sol";
import {ITipping} from "../../src/tipping/ITipping.sol";

contract TokenMock is ERC20 {
    constructor() ERC20("NODL", "NODL") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract ContentSignMock is ERC721 {
    constructor() ERC721("CS", "CS") {}
    function mint(address to, uint256 id) external { _mint(to, id); }
}

/// @dev Mirrors what the tipping contract reads from a factory collection: OWNER_ROLE, ERC-2981.
contract Collection721Mock is ERC721, ERC2981, AccessControl {
    bytes32 public constant OWNER_ROLE = keccak256("OWNER_ROLE");
    constructor(address owner) ERC721("C", "C") { _grantRole(OWNER_ROLE, owner); }
    function mint(address to, uint256 id) external { _mint(to, id); }
    function setRoyalty(address r, uint96 bps) external { _setDefaultRoyalty(r, bps); }
    function supportsInterface(bytes4 i) public view override(ERC721, ERC2981, AccessControl) returns (bool) {
        return super.supportsInterface(i);
    }
}

contract Collection1155Mock is ERC1155Supply, ERC2981 {
    constructor() ERC1155("") {}
    function mint(address to, uint256 id, uint256 n) external { _mint(to, id, n, ""); }
    function setRoyalty(address r, uint96 bps) external { _setDefaultRoyalty(r, bps); }
    function supportsInterface(bytes4 i) public view override(ERC1155, ERC2981) returns (bool) {
        return super.supportsInterface(i);
    }
}

contract TippingTest is Test {
    TokenMock internal nodl;
    Tipping internal tipping;
    ContentSignMock internal cs;
    Collection721Mock internal c721;
    Collection1155Mock internal c1155;

    address internal constant ADMIN = address(0xAD);
    address internal constant REGISTRY = address(0x09);
    address internal constant CREATOR = address(0xCAFE);
    address internal constant ALICE = address(0xA1);
    address internal constant BOB = address(0xB0);
    address internal constant SPLITTER = address(0x5111);
    uint256 internal constant MIN = 1e18;

    function setUp() public {
        nodl = new TokenMock();
        tipping = new Tipping(address(nodl), ADMIN, REGISTRY, MIN);
        cs = new ContentSignMock();
        c721 = new Collection721Mock(CREATOR);
        c1155 = new Collection1155Mock();
        nodl.mint(ALICE, 1_000e18);
        vm.prank(ALICE);
        nodl.approve(address(tipping), type(uint256).max);
        vm.prank(REGISTRY);
        tipping.setCollectionAllowed(address(cs), true);
        vm.prank(REGISTRY);
        tipping.setCreator(address(c1155), CREATOR);
    }

    function test_contentSign_tipGoesToOwner() public {
        cs.mint(BOB, 7);
        vm.expectEmit(true, true, true, true);
        emit ITipping.Tipped(ALICE, address(cs), 7, BOB, 5e18, 0);
        vm.prank(ALICE);
        tipping.tip(address(cs), 7, 5e18);
        assertEq(nodl.balanceOf(BOB), 5e18);
    }

    function test_contentSign_unmintedReverts() public {
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(ITipping.UnknownToken.selector, address(cs), 1));
        tipping.tip(address(cs), 1, 5e18);
    }

    function test_registerCollection_ownerOnly() public {
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(ITipping.NotCollectionOwner.selector, address(c721), ALICE));
        tipping.registerCollection(address(c721));
        vm.prank(CREATOR);
        tipping.registerCollection(address(c721));
        assertEq(tipping.creatorOf(address(c721)), CREATOR);
        vm.prank(CREATOR);
        vm.expectRevert(abi.encodeWithSelector(ITipping.AlreadyRegistered.selector, address(c721)));
        tipping.registerCollection(address(c721));
    }

    function test_zeroAmountRevertsEvenWithZeroMinimum() public {
        vm.prank(ADMIN);
        tipping.setMinTipAmount(0);
        cs.mint(BOB, 1);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(ITipping.BelowMinimum.selector, 0, 0));
        tipping.tip(address(cs), 1, 0);
    }

    function test_feeRecipientCannotBeSelfOrToken() public {
        vm.startPrank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(ITipping.InvalidFeeRecipient.selector, address(tipping)));
        tipping.setFeeRecipient(address(tipping));
        vm.expectRevert(abi.encodeWithSelector(ITipping.InvalidFeeRecipient.selector, address(nodl)));
        tipping.setFeeRecipient(address(nodl));
        vm.stopPrank();
    }

    function test_factory721_royaltyReceiverElseCreator() public {
        vm.prank(CREATOR);
        tipping.registerCollection(address(c721));
        c721.mint(BOB, 1);
        vm.prank(ALICE);
        tipping.tip(address(c721), 1, 2e18);
        assertEq(nodl.balanceOf(CREATOR), 2e18);
        c721.setRoyalty(SPLITTER, 500);
        vm.prank(ALICE);
        tipping.tip(address(c721), 1, 2e18);
        assertEq(nodl.balanceOf(SPLITTER), 2e18);
    }

    function test_factory1155_zeroSupplyReverts_thenResolves() public {
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(ITipping.UnknownToken.selector, address(c1155), 3));
        tipping.tip(address(c1155), 3, 2e18);
        c1155.mint(BOB, 3, 10);
        vm.prank(ALICE);
        tipping.tip(address(c1155), 3, 2e18);
        assertEq(nodl.balanceOf(CREATOR), 2e18);
    }

    function test_unknownCollectionReverts() public {
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(ITipping.UnknownCollection.selector, address(0x1234)));
        tipping.tip(address(0x1234), 1, 2e18);
    }

    function test_selfTipAndDustRevert() public {
        cs.mint(ALICE, 9);
        vm.startPrank(ALICE);
        vm.expectRevert(ITipping.SelfTip.selector);
        tipping.tip(address(cs), 9, 2e18);
        vm.expectRevert(abi.encodeWithSelector(ITipping.BelowMinimum.selector, 1, MIN));
        tipping.tip(address(cs), 9, 1);
        vm.stopPrank();
    }

    function test_feeSplitAndCap() public {
        vm.prank(ADMIN);
        tipping.setFee(250);
        vm.prank(ADMIN);
        tipping.setFeeRecipient(address(0xFEE));
        cs.mint(BOB, 1);
        vm.prank(ALICE);
        tipping.tip(address(cs), 1, 100e18);
        assertEq(nodl.balanceOf(BOB), 97.5e18);
        assertEq(nodl.balanceOf(address(0xFEE)), 2.5e18);
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(ITipping.FeeTooHigh.selector, 1001));
        tipping.setFee(1001);
    }

    function test_pauseBlocksTips() public {
        vm.prank(ADMIN);
        tipping.pause();
        cs.mint(BOB, 1);
        vm.prank(ALICE);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        tipping.tip(address(cs), 1, 2e18);
    }

    function test_rolesSeparated() public {
        bytes32 registryRole = tipping.REGISTRY_ROLE();
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, ADMIN, registryRole));
        tipping.setCollectionAllowed(address(cs), false);
        vm.prank(REGISTRY);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, REGISTRY, bytes32(0)));
        tipping.setFee(1);
    }
}
