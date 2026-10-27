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

/// @dev Records every `transferFrom` so tests can prove the contract only ever pulls from the caller.
contract TokenMock is ERC20 {
    address[] public froms;
    address[] public tos;
    uint256[] public amounts;

    constructor() ERC20("NODL", "NODL") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        froms.push(from);
        tos.push(to);
        amounts.push(value);
        return super.transferFrom(from, to, value);
    }

    function transfers() external view returns (uint256) {
        return froms.length;
    }
}

contract ContentSignMock is ERC721 {
    constructor() ERC721("CS", "CS") {}

    function mint(address to, uint256 id) external {
        _mint(to, id);
    }
}

/// @dev Mirrors what the tipping contract reads from a factory collection: OWNER_ROLE, ERC-2981.
contract Collection721Mock is ERC721, ERC2981, AccessControl {
    bytes32 public constant OWNER_ROLE = keccak256("OWNER_ROLE");

    constructor(address owner) ERC721("C", "C") {
        _grantRole(OWNER_ROLE, owner);
    }

    function mint(address to, uint256 id) external {
        _mint(to, id);
    }

    function setRoyalty(address r, uint96 bps) external {
        _setDefaultRoyalty(r, bps);
    }

    function deleteRoyalty() external {
        _deleteDefaultRoyalty();
    }

    function supportsInterface(bytes4 i) public view override(ERC721, ERC2981, AccessControl) returns (bool) {
        return super.supportsInterface(i);
    }
}

contract Collection1155Mock is ERC1155Supply, ERC2981 {
    constructor() ERC1155("") {}

    function mint(address to, uint256 id, uint256 n) external {
        _mint(to, id, n, "");
    }

    function setRoyalty(address r, uint96 bps) external {
        _setDefaultRoyalty(r, bps);
    }

    function supportsInterface(bytes4 i) public view override(ERC1155, ERC2981) returns (bool) {
        return super.supportsInterface(i);
    }
}

/// @dev Burns all forwarded gas on every call: the lookup gas cap must contain it.
contract GasBombMock {
    fallback() external {
        while (true) {}
    }
}

/// @dev Returns malformed data (too short) for every call.
contract ShortReturnMock {
    fallback() external {
        assembly {
            mstore(0, 1)
            return(0, 8)
        }
    }
}

/// @dev `hasRole` reports true for everyone: any such contract can be registered by anyone.
contract OpenOwnerMock {
    function hasRole(bytes32, address) external pure returns (bool) {
        return true;
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

    // ───────── Constructor ─────────

    function test_constructor_state() public view {
        assertEq(tipping.nodl(), address(nodl));
        assertEq(tipping.minTipAmount(), MIN);
        assertEq(tipping.feeBps(), 0);
        assertEq(tipping.feeRecipient(), ADMIN);
        assertTrue(tipping.hasRole(tipping.DEFAULT_ADMIN_ROLE(), ADMIN));
        assertTrue(tipping.hasRole(tipping.REGISTRY_ROLE(), REGISTRY));
        assertFalse(tipping.paused());
        assertEq(tipping.COLLECTION_OWNER_ROLE(), keccak256("OWNER_ROLE"));
    }

    function test_constructor_emitsInitialSettings() public {
        vm.expectEmit(true, true, true, true);
        emit ITipping.MinTipUpdated(3);
        vm.expectEmit(true, true, true, true);
        emit ITipping.FeeUpdated(0);
        vm.expectEmit(true, true, true, true);
        emit ITipping.FeeRecipientUpdated(ADMIN);
        new Tipping(address(nodl), ADMIN, REGISTRY, 3);
    }

    function test_constructor_rejectsZeroAddresses() public {
        vm.expectRevert(ITipping.ZeroAddress.selector);
        new Tipping(address(0), ADMIN, REGISTRY, MIN);
        vm.expectRevert(ITipping.ZeroAddress.selector);
        new Tipping(address(nodl), address(0), REGISTRY, MIN);
        vm.expectRevert(ITipping.ZeroAddress.selector);
        new Tipping(address(nodl), ADMIN, address(0), MIN);
    }

    // ───────── ContentSign path ─────────

    function test_contentSign_tipGoesToOwner() public {
        cs.mint(BOB, 7);
        assertEq(tipping.resolveRecipient(address(cs), 7), BOB);
        vm.expectEmit(true, true, true, true);
        emit ITipping.Tipped(ALICE, address(cs), 7, BOB, 5e18, 0);
        vm.prank(ALICE);
        tipping.tip(address(cs), 7, 5e18);
        assertEq(nodl.balanceOf(BOB), 5e18);
        assertEq(nodl.balanceOf(ALICE), 995e18);
        // A zero fee means a single transfer, straight to the recipient.
        assertEq(nodl.transfers(), 1);
    }

    function test_contentSign_unmintedReverts() public {
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(ITipping.UnknownToken.selector, address(cs), 1));
        tipping.tip(address(cs), 1, 5e18);
    }

    function test_contentSign_burnedTokenReverts() public {
        // ERC721 `ownerOf` reverts for a burned token; an owner-less success is covered by the mock below.
        cs.mint(BOB, 2);
        vm.prank(BOB);
        cs.transferFrom(BOB, address(0xDEAD), 2);
        assertEq(tipping.resolveRecipient(address(cs), 2), address(0xDEAD));
    }

    function test_contentSign_zeroOwnerReverts() public {
        // A contract whose `ownerOf` answers address(0) is not a valid recipient.
        ZeroOwnerMock z = new ZeroOwnerMock();
        vm.prank(REGISTRY);
        tipping.setCollectionAllowed(address(z), true);
        vm.expectRevert(abi.encodeWithSelector(ITipping.NoRecipient.selector, address(z), 1));
        tipping.resolveRecipient(address(z), 1);
    }

    function test_contentSign_disallowedFallsThroughToRegistry() public {
        cs.mint(BOB, 7);
        vm.prank(REGISTRY);
        vm.expectEmit(true, true, true, true);
        emit ITipping.CollectionAllowed(address(cs), false);
        tipping.setCollectionAllowed(address(cs), false);
        assertFalse(tipping.contentSignAllowed(address(cs)));
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(ITipping.UnknownCollection.selector, address(cs)));
        tipping.tip(address(cs), 7, 5e18);
    }

    // ───────── Factory path ─────────

    function test_factory721_royaltyReceiverElseCreator() public {
        vm.prank(CREATOR);
        tipping.registerCollection(address(c721));
        c721.mint(BOB, 1);
        assertEq(tipping.resolveRecipient(address(c721), 1), CREATOR);
        vm.prank(ALICE);
        tipping.tip(address(c721), 1, 2e18);
        assertEq(nodl.balanceOf(CREATOR), 2e18);

        c721.setRoyalty(SPLITTER, 500);
        assertEq(tipping.resolveRecipient(address(c721), 1), SPLITTER);
        vm.prank(ALICE);
        tipping.tip(address(c721), 1, 2e18);
        assertEq(nodl.balanceOf(SPLITTER), 2e18);

        // Deleting the royalty makes `royaltyInfo` answer address(0): back to the creator.
        c721.deleteRoyalty();
        assertEq(tipping.resolveRecipient(address(c721), 1), CREATOR);
    }

    function test_factory721_unmintedTokenStillResolves() public {
        // ERC-721 ids are not supply-checked: the creator is paid for any id of a registered collection.
        vm.prank(CREATOR);
        tipping.registerCollection(address(c721));
        assertEq(tipping.resolveRecipient(address(c721), 999), CREATOR);
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

    function test_factory1155_royaltyReceiver() public {
        c1155.mint(BOB, 3, 10);
        c1155.setRoyalty(SPLITTER, 100);
        assertEq(tipping.resolveRecipient(address(c1155), 3), SPLITTER);
    }

    function test_registeredContractWithoutErc165ResolvesToCreator() public {
        // No `supportsInterface`, no `royaltyInfo`: every lookup fails softly and the creator is paid.
        vm.prank(REGISTRY);
        tipping.setCreator(address(nodl), CREATOR);
        assertEq(tipping.resolveRecipient(address(nodl), 1), CREATOR);
    }

    function test_registeredContractWithShortReturnsResolvesToCreator() public {
        ShortReturnMock s = new ShortReturnMock();
        vm.prank(REGISTRY);
        tipping.setCreator(address(s), CREATOR);
        assertEq(tipping.resolveRecipient(address(s), 1), CREATOR);
        vm.prank(REGISTRY);
        tipping.setCollectionAllowed(address(s), true);
        vm.expectRevert(abi.encodeWithSelector(ITipping.UnknownToken.selector, address(s), 1));
        tipping.resolveRecipient(address(s), 1);
    }

    function test_unknownCollectionReverts() public {
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(ITipping.UnknownCollection.selector, address(0x1234)));
        tipping.tip(address(0x1234), 1, 2e18);
        // An ERC-2981 contract that nobody registered is unknown too: the registry is the gate.
        vm.expectRevert(abi.encodeWithSelector(ITipping.UnknownCollection.selector, address(c721)));
        tipping.resolveRecipient(address(c721), 1);
    }

    function test_lookupGasIsCapped() public {
        GasBombMock bomb = new GasBombMock();
        vm.prank(REGISTRY);
        tipping.setCollectionAllowed(address(bomb), true);
        uint256 before = gasleft();
        vm.expectRevert(abi.encodeWithSelector(ITipping.UnknownToken.selector, address(bomb), 1));
        tipping.resolveRecipient(address(bomb), 1);
        assertLt(before - gasleft(), 3 * tipping.LOOKUP_GAS());

        vm.prank(REGISTRY);
        tipping.setCollectionAllowed(address(bomb), false);
        vm.prank(REGISTRY);
        tipping.setCreator(address(bomb), CREATOR);
        before = gasleft();
        // supportsInterface and royaltyInfo both burn their cap; the creator is still resolved.
        assertEq(tipping.resolveRecipient(address(bomb), 1), CREATOR);
        assertLt(before - gasleft(), 4 * tipping.LOOKUP_GAS());
    }

    // ───────── Registry ─────────

    function test_registerCollection_ownerOnly() public {
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(ITipping.NotCollectionOwner.selector, address(c721), ALICE));
        tipping.registerCollection(address(c721));
        vm.prank(CREATOR);
        vm.expectEmit(true, true, true, true);
        emit ITipping.CreatorSet(address(c721), CREATOR);
        tipping.registerCollection(address(c721));
        assertEq(tipping.creatorOf(address(c721)), CREATOR);
        vm.prank(CREATOR);
        vm.expectRevert(abi.encodeWithSelector(ITipping.AlreadyRegistered.selector, address(c721)));
        tipping.registerCollection(address(c721));
    }

    function test_registerCollection_rejectsZeroAndEoa() public {
        vm.expectRevert(ITipping.ZeroAddress.selector);
        tipping.registerCollection(address(0));
        // An EOA answers every staticcall with empty data.
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(ITipping.NotCollectionOwner.selector, address(0xE0A), ALICE));
        tipping.registerCollection(address(0xE0A));
    }

    function test_registerCollection_anyContractAttestingOwnerRole() public {
        OpenOwnerMock open = new OpenOwnerMock();
        vm.prank(BOB);
        tipping.registerCollection(address(open));
        assertEq(tipping.creatorOf(address(open)), BOB);
    }

    function test_registryEntryWinsAndCanBeCleared() public {
        vm.prank(REGISTRY);
        tipping.setCreator(address(c721), SPLITTER);
        vm.prank(CREATOR);
        vm.expectRevert(abi.encodeWithSelector(ITipping.AlreadyRegistered.selector, address(c721)));
        tipping.registerCollection(address(c721));

        vm.prank(REGISTRY);
        vm.expectEmit(true, true, true, true);
        emit ITipping.CreatorSet(address(c721), address(0));
        tipping.setCreator(address(c721), address(0));
        vm.expectRevert(abi.encodeWithSelector(ITipping.UnknownCollection.selector, address(c721)));
        tipping.resolveRecipient(address(c721), 1);

        vm.prank(CREATOR);
        tipping.registerCollection(address(c721));
        assertEq(tipping.creatorOf(address(c721)), CREATOR);
    }

    function test_registrySettersRejectZeroCollection() public {
        vm.startPrank(REGISTRY);
        vm.expectRevert(ITipping.ZeroAddress.selector);
        tipping.setCreator(address(0), CREATOR);
        vm.expectRevert(ITipping.ZeroAddress.selector);
        tipping.setCollectionAllowed(address(0), true);
        vm.stopPrank();
    }

    // ───────── Guards ─────────

    function test_zeroAmountRevertsEvenWithZeroMinimum() public {
        vm.prank(ADMIN);
        vm.expectEmit(true, true, true, true);
        emit ITipping.MinTipUpdated(0);
        tipping.setMinTipAmount(0);
        cs.mint(BOB, 1);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(ITipping.BelowMinimum.selector, 0, 0));
        tipping.tip(address(cs), 1, 0);
        // One wei is fine once the minimum is zero.
        vm.prank(ALICE);
        tipping.tip(address(cs), 1, 1);
        assertEq(nodl.balanceOf(BOB), 1);
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

    function test_insufficientAllowanceOrBalanceReverts() public {
        cs.mint(BOB, 1);
        nodl.mint(address(0xC0), 10e18);
        vm.prank(address(0xC0));
        vm.expectRevert();
        tipping.tip(address(cs), 1, 2e18);
        vm.prank(address(0xC0));
        nodl.approve(address(tipping), type(uint256).max);
        vm.prank(address(0xC0));
        vm.expectRevert();
        tipping.tip(address(cs), 1, 11e18);
    }

    function test_pauseBlocksTips() public {
        vm.prank(ADMIN);
        vm.expectEmit(true, true, true, true);
        emit Pausable.Paused(ADMIN);
        tipping.pause();
        cs.mint(BOB, 1);
        vm.prank(ALICE);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        tipping.tip(address(cs), 1, 2e18);
        // Resolution stays readable while paused; the registry keeps working.
        assertEq(tipping.resolveRecipient(address(cs), 1), BOB);
        vm.prank(REGISTRY);
        tipping.setCreator(address(c721), CREATOR);

        vm.prank(ADMIN);
        vm.expectEmit(true, true, true, true);
        emit Pausable.Unpaused(ADMIN);
        tipping.unpause();
        vm.prank(ALICE);
        tipping.tip(address(cs), 1, 2e18);
        assertEq(nodl.balanceOf(BOB), 2e18);
    }

    // ───────── Fees ─────────

    function test_feeSplitAndCap() public {
        vm.prank(ADMIN);
        vm.expectEmit(true, true, true, true);
        emit ITipping.FeeUpdated(250);
        tipping.setFee(250);
        vm.prank(ADMIN);
        vm.expectEmit(true, true, true, true);
        emit ITipping.FeeRecipientUpdated(address(0xFEE));
        tipping.setFeeRecipient(address(0xFEE));
        cs.mint(BOB, 1);
        vm.expectEmit(true, true, true, true);
        emit ITipping.Tipped(ALICE, address(cs), 1, BOB, 100e18, 2.5e18);
        vm.prank(ALICE);
        tipping.tip(address(cs), 1, 100e18);
        assertEq(nodl.balanceOf(BOB), 97.5e18);
        assertEq(nodl.balanceOf(address(0xFEE)), 2.5e18);
        assertEq(nodl.transfers(), 2);

        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(ITipping.FeeTooHigh.selector, 1001));
        tipping.setFee(1001);
        vm.prank(ADMIN);
        tipping.setFee(1000);
        assertEq(tipping.feeBps(), 1000);
    }

    function test_feeRoundsDownInFavourOfRecipient() public {
        vm.prank(ADMIN);
        tipping.setFee(1); // 0.01%
        vm.prank(ADMIN);
        tipping.setMinTipAmount(0);
        cs.mint(BOB, 1);
        vm.prank(ALICE);
        tipping.tip(address(cs), 1, 9_999);
        assertEq(nodl.balanceOf(BOB), 9_999);
        assertEq(nodl.balanceOf(ADMIN), 0);
    }

    function test_feeRecipientCannotBeZeroSelfOrToken() public {
        vm.startPrank(ADMIN);
        vm.expectRevert(ITipping.ZeroAddress.selector);
        tipping.setFeeRecipient(address(0));
        vm.expectRevert(abi.encodeWithSelector(ITipping.InvalidFeeRecipient.selector, address(tipping)));
        tipping.setFeeRecipient(address(tipping));
        vm.expectRevert(abi.encodeWithSelector(ITipping.InvalidFeeRecipient.selector, address(nodl)));
        tipping.setFeeRecipient(address(nodl));
        vm.stopPrank();
    }

    // ───────── Roles ─────────

    function test_rolesSeparated() public {
        bytes32 registryRole = tipping.REGISTRY_ROLE();
        vm.startPrank(ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, ADMIN, registryRole)
        );
        tipping.setCollectionAllowed(address(cs), false);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, ADMIN, registryRole)
        );
        tipping.setCreator(address(c721), CREATOR);
        vm.stopPrank();

        vm.startPrank(REGISTRY);
        bytes memory denied =
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, REGISTRY, bytes32(0));
        vm.expectRevert(denied);
        tipping.setFee(1);
        vm.expectRevert(denied);
        tipping.setFeeRecipient(address(0xFEE));
        vm.expectRevert(denied);
        tipping.setMinTipAmount(1);
        vm.expectRevert(denied);
        tipping.pause();
        vm.expectRevert(denied);
        tipping.unpause();
        vm.stopPrank();
    }

    // ───────── Fuzz ─────────

    /// @dev The immutability argument: NODL only ever leaves the caller's own balance.
    function testFuzz_transferFromOnlyFromCaller(address tipper, uint256 amount, uint16 bps) public {
        vm.assume(
            tipper != address(0) && tipper != BOB && tipper != ADMIN && tipper != address(nodl)
                && tipper != address(tipping)
        );
        amount = bound(amount, MIN, 1e30);
        bps = uint16(bound(bps, 0, 1000));
        vm.prank(ADMIN);
        tipping.setFee(bps);
        cs.mint(BOB, 1);
        nodl.mint(tipper, amount);
        vm.prank(tipper);
        nodl.approve(address(tipping), amount);

        vm.prank(tipper);
        tipping.tip(address(cs), 1, amount);

        uint256 fee = (amount * bps) / 10_000;
        uint256 n = nodl.transfers();
        uint256 moved;
        for (uint256 i; i < n; i++) {
            assertEq(nodl.froms(i), tipper);
            moved += nodl.amounts(i);
        }
        assertEq(moved, amount);
        assertEq(nodl.balanceOf(tipper), 0);
        assertEq(nodl.balanceOf(BOB), amount - fee);
        assertEq(nodl.balanceOf(ADMIN), fee);
        assertEq(n, fee > 0 ? 2 : 1);
    }

    function testFuzz_belowMinimumReverts(uint256 minimum, uint256 amount) public {
        minimum = bound(minimum, 1, 1e30);
        amount = bound(amount, 0, minimum - 1);
        vm.prank(ADMIN);
        tipping.setMinTipAmount(minimum);
        cs.mint(BOB, 1);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(ITipping.BelowMinimum.selector, amount, minimum));
        tipping.tip(address(cs), 1, amount);
    }
}

/// @dev `ownerOf` succeeds with address(0): the resolver must not pay the zero address.
contract ZeroOwnerMock {
    function ownerOf(uint256) external pure returns (address) {
        return address(0);
    }
}
