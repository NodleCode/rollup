// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {ERC1155Supply} from "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155Supply.sol";
import {ERC2981} from "@openzeppelin/contracts/token/common/ERC2981.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {Tipping} from "../../src/tipping/Tipping.sol";
import {ITipping} from "../../src/tipping/ITipping.sol";

/// @dev Records every `transferFrom` so tests can prove the contract only ever pulls from the caller.
contract TokenMock is ERC20 {
    address[] public senders;
    uint256[] public amounts;

    constructor(string memory sym) ERC20(sym, sym) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        senders.push(from);
        amounts.push(value);
        return super.transferFrom(from, to, value);
    }

    function transfers() external view returns (uint256) {
        return senders.length;
    }
}

/// @dev A Click-style post: plain ERC-721, transferable, no royalties.
contract Post721 is ERC721 {
    constructor() ERC721("Click", "CLK") {}

    function mint(address to, uint256 id) external {
        _mint(to, id);
    }

    function burn(uint256 id) external {
        _burn(id);
    }
}

/// @dev A factory-style edition: ERC-1155 with supply tracking and a default royalty receiver.
contract Edition1155 is ERC1155Supply, ERC2981 {
    constructor() ERC1155("ipfs://x") {}

    function mint(address to, uint256 id, uint256 amount) external {
        _mint(to, id, amount, "");
    }

    function burn(address from, uint256 id, uint256 amount) external {
        _burn(from, id, amount);
    }

    function setRoyalty(address receiver, uint96 bps) external {
        if (receiver == address(0)) _deleteDefaultRoyalty();
        else _setDefaultRoyalty(receiver, bps);
    }

    function supportsInterface(bytes4 id) public view override(ERC1155, ERC2981) returns (bool) {
        return super.supportsInterface(id);
    }
}

/// @dev A Nodle-style edition: supply tracking, OWNER_ROLE held by the creator, no royalty.
contract NodleEdition1155 is ERC1155Supply, AccessControl {
    bytes32 public constant OWNER_ROLE = keccak256("OWNER_ROLE");

    constructor(address owner_) ERC1155("ipfs://n") {
        _grantRole(OWNER_ROLE, owner_);
    }

    function mint(address to, uint256 id, uint256 amount) external {
        _mint(to, id, amount, "");
    }

    function supportsInterface(bytes4 id) public view override(ERC1155, AccessControl) returns (bool) {
        return super.supportsInterface(id);
    }
}

/// @dev A third-party Ownable edition: no roles, no royalty, no supply tracking.
contract Ownable1155 is ERC1155, Ownable {
    constructor(address owner_) ERC1155("ipfs://o") Ownable(owner_) {}

    function mint(address to, uint256 id, uint256 amount) external {
        _mint(to, id, amount, "");
    }
}

/// @dev An ERC-1155 that tracks no supply, pays no royalties and has no owner (nothing to verify against).
contract Bare1155 is ERC1155 {
    constructor() ERC1155("ipfs://y") {}

    function mint(address to, uint256 id, uint256 amount) external {
        _mint(to, id, amount, "");
    }
}

/// @dev A hostile "collection": ownerOf tries to re-enter the tipping contract.
contract ReentrantCollection {
    Tipping internal immutable tipping;
    address internal immutable token;

    constructor(Tipping t, address tok) {
        tipping = t;
        token = tok;
    }

    function ownerOf(uint256) external returns (address) {
        tipping.tipAccount(token, address(0xBEEF), 1);
        return address(this);
    }
}

contract TippingTest is Test {
    TokenMock internal nodl;
    TokenMock internal usdc;
    Post721 internal post;
    Edition1155 internal edition;
    NodleEdition1155 internal nodleEdition;
    Ownable1155 internal ownable;
    Bare1155 internal bare;
    Tipping internal tipping;

    address internal constant ADMIN = address(0xAD);
    address internal constant ALICE = address(0xA1);
    address internal constant BOB = address(0xB0);
    address internal constant CREATOR = address(0xC4);
    uint256 internal constant POST_ID = 7;
    uint256 internal constant EDITION_ID = 0;

    function setUp() public {
        nodl = new TokenMock("NODL");
        usdc = new TokenMock("USDC");
        post = new Post721();
        edition = new Edition1155();
        bare = new Bare1155();
        nodleEdition = new NodleEdition1155(CREATOR);
        ownable = new Ownable1155(CREATOR);
        tipping = new Tipping(ADMIN);

        post.mint(BOB, POST_ID);
        edition.mint(ALICE, EDITION_ID, 100);
        edition.setRoyalty(CREATOR, 500);
        bare.mint(BOB, 1, 1);
        nodleEdition.mint(ALICE, EDITION_ID, 10);
        ownable.mint(ALICE, EDITION_ID, 10);

        nodl.mint(ALICE, 1_000e18);
        usdc.mint(ALICE, 1_000e6);
        vm.startPrank(ALICE);
        nodl.approve(address(tipping), type(uint256).max);
        usdc.approve(address(tipping), type(uint256).max);
        vm.stopPrank();
    }

    function tipPost(address who, uint256 amount) internal {
        address owner = post.ownerOf(POST_ID); // before the prank: an external call would consume it
        vm.prank(who);
        tipping.tip(address(post), ITipping.Standard.ERC721, POST_ID, owner, address(nodl), amount);
    }

    function notRecipient(address collection, uint256 id, address who) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(ITipping.NotRecipient.selector, collection, id, who);
    }

    // ───────── Constructor ─────────

    function test_constructor_state() public view {
        assertEq(tipping.feeBps(), 0);
        assertEq(tipping.feeRecipient(), ADMIN);
        assertTrue(tipping.hasRole(tipping.DEFAULT_ADMIN_ROLE(), ADMIN));
    }

    function test_constructor_emitsInitialSettings() public {
        vm.expectEmit(true, true, true, true);
        emit ITipping.FeeUpdated(0);
        vm.expectEmit(true, true, true, true);
        emit ITipping.FeeRecipientUpdated(ADMIN);
        new Tipping(ADMIN);
    }

    function test_constructor_rejectsZeroAdmin() public {
        vm.expectRevert(ITipping.ZeroAddress.selector);
        new Tipping(address(0));
    }

    // ───────── ERC-721 posts ─────────

    function test_tip721_paysCurrentOwner() public {
        vm.expectEmit(true, true, true, true);
        emit ITipping.Tipped(ALICE, address(post), POST_ID, address(nodl), BOB, 5e18, 0);
        tipPost(ALICE, 5e18);
        assertEq(nodl.balanceOf(BOB), 5e18);
        assertEq(nodl.balanceOf(ALICE), 995e18);
        assertEq(nodl.transfers(), 1);
    }

    function test_tip721_followsTransfers() public {
        vm.prank(BOB);
        post.transferFrom(BOB, CREATOR, POST_ID);
        assertTrue(tipping.isRecipient(address(post), ITipping.Standard.ERC721, POST_ID, CREATOR));
        assertFalse(tipping.isRecipient(address(post), ITipping.Standard.ERC721, POST_ID, BOB));
        tipPost(ALICE, 1e18);
        assertEq(nodl.balanceOf(CREATOR), 1e18);
        assertEq(nodl.balanceOf(BOB), 0);
        // The previous owner is no longer a valid recipient.
        vm.prank(ALICE);
        vm.expectRevert(notRecipient(address(post), POST_ID, BOB));
        tipping.tip(address(post), ITipping.Standard.ERC721, POST_ID, BOB, address(nodl), 1e18);
    }

    function test_tip721_neverMintedOrBurnedIsInvalid() public {
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(ITipping.InvalidToken.selector, address(post), 99));
        tipping.tip(address(post), ITipping.Standard.ERC721, 99, BOB, address(nodl), 1e18);

        post.burn(POST_ID);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(ITipping.InvalidToken.selector, address(post), POST_ID));
        tipping.tip(address(post), ITipping.Standard.ERC721, POST_ID, BOB, address(nodl), 1e18);
    }

    function test_tip721_ownerCannotTipOwnPost() public {
        nodl.mint(BOB, 1e18);
        vm.prank(BOB);
        nodl.approve(address(tipping), 1e18);
        vm.prank(BOB);
        vm.expectRevert(ITipping.SelfTip.selector);
        tipping.tip(address(post), ITipping.Standard.ERC721, POST_ID, BOB, address(nodl), 1e18);
    }

    function test_tip_anyErc20() public {
        vm.prank(ALICE);
        tipping.tip(address(post), ITipping.Standard.ERC721, POST_ID, BOB, address(usdc), 3e6);
        assertEq(usdc.balanceOf(BOB), 3e6);
    }

    // ───────── ERC-1155 editions ─────────

    function test_tip1155_paysRoyaltyReceiver() public {
        vm.expectEmit(true, true, true, true);
        emit ITipping.Tipped(ALICE, address(edition), EDITION_ID, address(nodl), CREATOR, 2e18, 0);
        vm.prank(ALICE);
        tipping.tip(address(edition), ITipping.Standard.ERC1155, EDITION_ID, CREATOR, address(nodl), 2e18);
        assertEq(nodl.balanceOf(CREATOR), 2e18);
        assertTrue(tipping.isRecipient(address(edition), ITipping.Standard.ERC1155, EDITION_ID, CREATOR));
        assertFalse(tipping.isRecipient(address(edition), ITipping.Standard.ERC1155, EDITION_ID, ALICE));
    }

    function test_tip1155_zeroSupplyIsInvalid() public {
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(ITipping.InvalidToken.selector, address(edition), 42));
        tipping.tip(address(edition), ITipping.Standard.ERC1155, 42, CREATOR, address(nodl), 1e18);

        edition.burn(ALICE, EDITION_ID, 100);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(ITipping.InvalidToken.selector, address(edition), EDITION_ID));
        tipping.tip(address(edition), ITipping.Standard.ERC1155, EDITION_ID, CREATOR, address(nodl), 1e18);
    }

    function test_tip1155_royaltyReceiverIsTheOnlyProofOnThisEdition() public {
        // Someone else than the royalty receiver is refused.
        vm.prank(ALICE);
        vm.expectRevert(notRecipient(address(edition), EDITION_ID, BOB));
        tipping.tip(address(edition), ITipping.Standard.ERC1155, EDITION_ID, BOB, address(nodl), 1e18);
        // With the royalty removed nobody can be verified any more.
        edition.setRoyalty(address(0), 0);
        vm.prank(ALICE);
        vm.expectRevert(notRecipient(address(edition), EDITION_ID, CREATOR));
        tipping.tip(address(edition), ITipping.Standard.ERC1155, EDITION_ID, CREATOR, address(nodl), 1e18);
        // No supply extension, no roles, no owner, no ERC-2981: nothing to verify against.
        vm.prank(ALICE);
        vm.expectRevert(notRecipient(address(bare), 1, BOB));
        tipping.tip(address(bare), ITipping.Standard.ERC1155, 1, BOB, address(nodl), 1e18);
    }

    function test_tip1155_nodleEditionPaysItsOwnerRoleHolder() public {
        // Nodle collections: no royalty, but the creator holds OWNER_ROLE.
        assertTrue(tipping.isRecipient(address(nodleEdition), ITipping.Standard.ERC1155, EDITION_ID, CREATOR));
        assertFalse(tipping.isRecipient(address(nodleEdition), ITipping.Standard.ERC1155, EDITION_ID, ALICE));
        vm.expectEmit(true, true, true, true);
        emit ITipping.Tipped(ALICE, address(nodleEdition), EDITION_ID, address(nodl), CREATOR, 3e18, 0);
        vm.prank(ALICE);
        tipping.tip(address(nodleEdition), ITipping.Standard.ERC1155, EDITION_ID, CREATOR, address(nodl), 3e18);
        assertEq(nodl.balanceOf(CREATOR), 3e18);
        // A holder of the edition is not its owner.
        vm.prank(ALICE);
        vm.expectRevert(notRecipient(address(nodleEdition), EDITION_ID, ALICE));
        tipping.tip(address(nodleEdition), ITipping.Standard.ERC1155, EDITION_ID, ALICE, address(nodl), 1e18);
        // An id never minted on a supply-tracking edition is invalid.
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(ITipping.InvalidToken.selector, address(nodleEdition), 5));
        tipping.tip(address(nodleEdition), ITipping.Standard.ERC1155, 5, CREATOR, address(nodl), 1e18);
    }

    function test_tip1155_ownableEditionPaysItsOwner() public {
        assertTrue(tipping.isRecipient(address(ownable), ITipping.Standard.ERC1155, EDITION_ID, CREATOR));
        vm.prank(ALICE);
        tipping.tip(address(ownable), ITipping.Standard.ERC1155, EDITION_ID, CREATOR, address(nodl), 1e18);
        assertEq(nodl.balanceOf(CREATOR), 1e18);
        vm.prank(ALICE);
        vm.expectRevert(notRecipient(address(ownable), EDITION_ID, BOB));
        tipping.tip(address(ownable), ITipping.Standard.ERC1155, EDITION_ID, BOB, address(nodl), 1e18);
    }

    function test_tip_zeroRecipientIsNotARecipient() public {
        vm.prank(ALICE);
        vm.expectRevert(notRecipient(address(post), POST_ID, address(0)));
        tipping.tip(address(post), ITipping.Standard.ERC721, POST_ID, address(0), address(nodl), 1e18);
        assertFalse(tipping.isRecipient(address(nodleEdition), ITipping.Standard.ERC1155, EDITION_ID, address(0)));
    }

    function test_tip1155_royaltyReceiverCannotTipItself() public {
        nodl.mint(CREATOR, 1e18);
        vm.startPrank(CREATOR);
        nodl.approve(address(tipping), 1e18);
        vm.expectRevert(ITipping.SelfTip.selector);
        tipping.tip(address(edition), ITipping.Standard.ERC1155, EDITION_ID, CREATOR, address(nodl), 1e18);
        vm.stopPrank();
    }

    // ───────── Resolution guards ─────────

    function test_tip_wrongStandardFailsToResolve() public {
        // ERC-1155 path on a plain ERC-721: no totalSupply, no royaltyInfo.
        vm.prank(ALICE);
        vm.expectRevert(notRecipient(address(post), POST_ID, BOB));
        tipping.tip(address(post), ITipping.Standard.ERC1155, POST_ID, BOB, address(nodl), 1e18);
        // ERC-721 path on an ERC-1155: no ownerOf.
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(ITipping.InvalidToken.selector, address(edition), EDITION_ID));
        tipping.tip(address(edition), ITipping.Standard.ERC721, EDITION_ID, CREATOR, address(nodl), 1e18);
    }

    function test_tip_collectionMustBeAContract() public {
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(ITipping.NotAContract.selector, address(0xD00D)));
        tipping.tip(address(0xD00D), ITipping.Standard.ERC721, 1, BOB, address(nodl), 1e18);
        vm.expectRevert(abi.encodeWithSelector(ITipping.NotAContract.selector, address(0)));
        tipping.isRecipient(address(0), ITipping.Standard.ERC721, 1, BOB);
    }

    function test_tip_lookupIsStaticAndCannotReenter() public {
        ReentrantCollection evil = new ReentrantCollection(tipping, address(nodl));
        // ownerOf is declared view on IERC721, so the call is a STATICCALL: the reentrant
        // tipAccount inside it reverts, the try/catch turns that into InvalidToken.
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(ITipping.InvalidToken.selector, address(evil), 1));
        tipping.tip(address(evil), ITipping.Standard.ERC721, 1, address(evil), address(nodl), 1e18);
        assertEq(nodl.transfers(), 0);
    }

    function test_tip_guards() public {
        vm.startPrank(ALICE);
        vm.expectRevert(ITipping.ZeroAddress.selector);
        tipping.tip(address(post), ITipping.Standard.ERC721, POST_ID, BOB, address(0), 1e18);
        vm.expectRevert(ITipping.ZeroAmount.selector);
        tipping.tip(address(post), ITipping.Standard.ERC721, POST_ID, BOB, address(nodl), 0);
        vm.stopPrank();
    }

    function test_tip_insufficientAllowanceOrBalanceReverts() public {
        vm.prank(ALICE);
        nodl.approve(address(tipping), 1e18);
        vm.prank(ALICE);
        vm.expectRevert();
        tipping.tip(address(post), ITipping.Standard.ERC721, POST_ID, BOB, address(nodl), 2e18);
        vm.prank(ALICE);
        nodl.approve(address(tipping), type(uint256).max);
        vm.prank(ALICE);
        vm.expectRevert();
        tipping.tip(address(post), ITipping.Standard.ERC721, POST_ID, BOB, address(nodl), 1_001e18);
    }

    // ───────── Account tips ─────────

    function test_tipAccount_paysNamedAddress() public {
        vm.expectEmit(true, true, true, true);
        emit ITipping.AccountTipped(ALICE, BOB, address(nodl), 4e18, 0);
        vm.prank(ALICE);
        tipping.tipAccount(address(nodl), BOB, 4e18);
        assertEq(nodl.balanceOf(BOB), 4e18);
    }

    function test_tipAccount_guards() public {
        vm.startPrank(ALICE);
        vm.expectRevert(ITipping.ZeroAddress.selector);
        tipping.tipAccount(address(nodl), address(0), 1e18);
        vm.expectRevert(ITipping.ZeroAddress.selector);
        tipping.tipAccount(address(0), BOB, 1e18);
        vm.expectRevert(ITipping.ZeroAmount.selector);
        tipping.tipAccount(address(nodl), BOB, 0);
        vm.expectRevert(ITipping.SelfTip.selector);
        tipping.tipAccount(address(nodl), ALICE, 1e18);
        vm.stopPrank();
    }

    // ───────── Fees ─────────

    function test_feeSplitAndCap() public {
        vm.prank(ADMIN);
        vm.expectEmit(true, true, true, true);
        emit ITipping.FeeUpdated(250);
        tipping.setFee(250);

        vm.expectEmit(true, true, true, true);
        emit ITipping.Tipped(ALICE, address(post), POST_ID, address(nodl), BOB, 100e18, 2.5e18);
        tipPost(ALICE, 100e18);
        assertEq(nodl.balanceOf(BOB), 97.5e18);
        // The fee accrues in the contract; the fee recipient is paid on withdraw, not per tip.
        assertEq(nodl.balanceOf(address(tipping)), 2.5e18);
        assertEq(nodl.balanceOf(ADMIN), 0);
        assertEq(nodl.transfers(), 2);

        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(ITipping.FeeTooHigh.selector, uint16(1001)));
        tipping.setFee(1001);
        vm.prank(ADMIN);
        tipping.setFee(1000);
        assertEq(tipping.feeBps(), 1000);
    }

    function test_withdrawFees_anyoneSendsAccruedToFeeRecipient() public {
        vm.prank(ADMIN);
        tipping.setFee(1000);
        vm.prank(ADMIN);
        tipping.setFeeRecipient(CREATOR);
        tipPost(ALICE, 50e18);
        vm.prank(ALICE);
        tipping.tipAccount(address(nodl), BOB, 10e18);
        assertEq(nodl.balanceOf(address(tipping)), 6e18);

        vm.expectEmit(true, true, true, true);
        emit ITipping.FeesWithdrawn(address(nodl), CREATOR, 6e18);
        vm.prank(BOB); // permissionless
        tipping.withdrawFees(address(nodl));
        assertEq(nodl.balanceOf(CREATOR), 6e18);
        assertEq(nodl.balanceOf(address(tipping)), 0);

        // Nothing accrued: revert rather than emit a zero withdrawal.
        vm.expectRevert(ITipping.ZeroAmount.selector);
        tipping.withdrawFees(address(nodl));
        vm.expectRevert(ITipping.ZeroAddress.selector);
        tipping.withdrawFees(address(0));
        // Stray tokens sent directly are recoverable the same way.
        usdc.mint(address(tipping), 7e6);
        tipping.withdrawFees(address(usdc));
        assertEq(usdc.balanceOf(CREATOR), 7e6);
    }

    function test_feeRoundsDownInFavourOfRecipient() public {
        vm.prank(ADMIN);
        tipping.setFee(1);
        vm.prank(ALICE);
        tipping.tipAccount(address(nodl), BOB, 9_999);
        assertEq(nodl.balanceOf(BOB), 9_999);
        assertEq(nodl.balanceOf(address(tipping)), 0);
        assertEq(nodl.transfers(), 1);
    }

    function test_feeRecipientCannotBeZeroOrSelf() public {
        vm.startPrank(ADMIN);
        vm.expectRevert(ITipping.ZeroAddress.selector);
        tipping.setFeeRecipient(address(0));
        vm.expectRevert(abi.encodeWithSelector(ITipping.InvalidFeeRecipient.selector, address(tipping)));
        tipping.setFeeRecipient(address(tipping));
        vm.expectEmit(true, true, true, true);
        emit ITipping.FeeRecipientUpdated(BOB);
        tipping.setFeeRecipient(BOB);
        vm.stopPrank();
        assertEq(tipping.feeRecipient(), BOB);
    }

    function test_adminOnly() public {
        bytes memory denied =
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, ALICE, bytes32(0));
        vm.startPrank(ALICE);
        vm.expectRevert(denied);
        tipping.setFee(1);
        vm.expectRevert(denied);
        tipping.setFeeRecipient(BOB);
        vm.stopPrank();
    }

    // ───────── Invariant ─────────

    /// @dev Whatever the path, token or fee, every transferFrom has `from == msg.sender`.
    function testFuzz_transferFromOnlyFromCaller(address tipper, uint256 amount, uint16 bps, uint8 path) public {
        vm.assume(tipper != address(0) && tipper != BOB && tipper != CREATOR && tipper != address(tipping));
        vm.assume(tipper.code.length == 0);
        amount = bound(amount, 1, 1e30);
        bps = uint16(bound(bps, 0, 1000));
        vm.prank(ADMIN);
        tipping.setFee(bps);
        nodl.mint(tipper, amount);
        vm.prank(tipper);
        nodl.approve(address(tipping), amount);

        vm.prank(tipper);
        if (path % 3 == 0) tipping.tip(address(post), ITipping.Standard.ERC721, POST_ID, BOB, address(nodl), amount);
        else if (path % 3 == 1) tipping.tip(address(edition), ITipping.Standard.ERC1155, EDITION_ID, CREATOR, address(nodl), amount);
        else tipping.tipAccount(address(nodl), BOB, amount);

        uint256 n = nodl.transfers();
        assertTrue(n == 1 || n == 2);
        uint256 total;
        for (uint256 i = 0; i < n; i++) {
            assertEq(nodl.senders(i), tipper);
            total += nodl.amounts(i);
        }
        assertEq(total, amount);
        assertEq(nodl.balanceOf(tipper), 0);
    }
}
