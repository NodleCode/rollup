// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

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

/// @dev An ERC-1271 signer: valid when the digest was signed by its one owner key.
contract WalletSignerMock is IERC1271 {
    address internal immutable owner;

    constructor(address owner_) {
        owner = owner_;
    }

    function isValidSignature(bytes32 hash, bytes memory signature) external view returns (bytes4) {
        (address recovered,,) = ECDSA.tryRecover(hash, signature);
        return recovered == owner ? IERC1271.isValidSignature.selector : bytes4(0);
    }
}

contract TippingTest is Test {
    TokenMock internal nodl;
    TokenMock internal usdc;
    Tipping internal tipping;

    address internal constant ADMIN = address(0xAD);
    address internal constant ALICE = address(0xA1);
    address internal constant BOB = address(0xB0);
    address internal constant COLLECTION = address(0xC0111);
    uint256 internal constant TOKEN_ID = 7;

    uint256 internal signerKey;
    address internal signer;
    uint256 internal otherKey;

    function setUp() public {
        (signer, signerKey) = makeAddrAndKey("signer");
        (, otherKey) = makeAddrAndKey("other");
        nodl = new TokenMock("NODL");
        usdc = new TokenMock("USDC");
        tipping = new Tipping(ADMIN, signer);
        nodl.mint(ALICE, 1_000e18);
        usdc.mint(ALICE, 1_000e6);
        vm.startPrank(ALICE);
        nodl.approve(address(tipping), type(uint256).max);
        usdc.approve(address(tipping), type(uint256).max);
        vm.stopPrank();
    }

    // ───────── helpers ─────────

    function auth(address token, address recipient, uint256 amount)
        internal
        view
        returns (ITipping.TipAuthorization memory)
    {
        return ITipping.TipAuthorization({
            tipper: ALICE,
            token: token,
            collection: COLLECTION,
            tokenId: TOKEN_ID,
            recipient: recipient,
            amount: amount,
            deadline: block.timestamp + 300,
            nonce: keccak256(abi.encode(token, recipient, amount, block.timestamp))
        });
    }

    function copy(ITipping.TipAuthorization memory a) internal pure returns (ITipping.TipAuthorization memory b) {
        b = ITipping.TipAuthorization(
            a.tipper, a.token, a.collection, a.tokenId, a.recipient, a.amount, a.deadline, a.nonce
        );
    }

    /// @dev Signs, then calls `tip` as `who`. Signing is an external call, so it must happen
    ///      before any prank or expectEmit.
    function tipAs(address who, uint256 key, ITipping.TipAuthorization memory a) internal {
        bytes memory sig = sign(key, a);
        vm.prank(who);
        tipping.tip(a, sig);
    }

    /// @dev Signs first, then expects `tip` as `who` to revert with `data`.
    function expectTipRevert(address who, uint256 key, ITipping.TipAuthorization memory a, bytes memory data) internal {
        bytes memory sig = sign(key, a);
        vm.prank(who);
        vm.expectRevert(data);
        tipping.tip(a, sig);
    }

    function sign(uint256 key, ITipping.TipAuthorization memory a) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, tipping.hashAuthorization(a));
        return abi.encodePacked(r, s, v);
    }

    // ───────── Constructor ─────────

    function test_constructor_state() public view {
        assertEq(tipping.signer(), signer);
        assertEq(tipping.feeBps(), 0);
        assertEq(tipping.feeRecipient(), ADMIN);
        assertTrue(tipping.hasRole(tipping.DEFAULT_ADMIN_ROLE(), ADMIN));
    }

    function test_constructor_emitsInitialSettings() public {
        vm.expectEmit(true, true, true, true);
        emit ITipping.SignerUpdated(signer);
        vm.expectEmit(true, true, true, true);
        emit ITipping.FeeUpdated(0);
        vm.expectEmit(true, true, true, true);
        emit ITipping.FeeRecipientUpdated(ADMIN);
        new Tipping(ADMIN, signer);
    }

    function test_constructor_rejectsZeroAddresses() public {
        vm.expectRevert(ITipping.ZeroAddress.selector);
        new Tipping(address(0), signer);
        vm.expectRevert(ITipping.ZeroAddress.selector);
        new Tipping(ADMIN, address(0));
    }

    function test_eip712Domain() public view {
        (, string memory name, string memory version, uint256 chainId, address verifying,,) = tipping.eip712Domain();
        assertEq(name, "NodleTipping");
        assertEq(version, "1");
        assertEq(chainId, block.chainid);
        assertEq(verifying, address(tipping));
    }

    // ───────── Post tips ─────────

    function test_tip_paysRecipientAndMarksNonce() public {
        ITipping.TipAuthorization memory a = auth(address(nodl), BOB, 5e18);
        bytes memory sig = sign(signerKey, a);
        vm.expectEmit(true, true, true, true);
        emit ITipping.Tipped(ALICE, COLLECTION, TOKEN_ID, address(nodl), BOB, 5e18, 0);
        vm.prank(ALICE);
        tipping.tip(a, sig);
        assertEq(nodl.balanceOf(BOB), 5e18);
        assertEq(nodl.balanceOf(ALICE), 995e18);
        assertTrue(tipping.nonceUsed(a.nonce));
        // A zero fee means a single transfer, straight to the recipient.
        assertEq(nodl.transfers(), 1);
    }

    function test_tip_anyErc20() public {
        ITipping.TipAuthorization memory a = auth(address(usdc), BOB, 25e6);
        tipAs(ALICE, signerKey, a);
        assertEq(usdc.balanceOf(BOB), 25e6);
        assertEq(nodl.balanceOf(BOB), 0);
    }

    function test_tip_nonceCannotBeReplayed() public {
        ITipping.TipAuthorization memory a = auth(address(nodl), BOB, 5e18);
        bytes memory sig = sign(signerKey, a);
        vm.prank(ALICE);
        tipping.tip(a, sig);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(ITipping.NonceUsed.selector, a.nonce));
        tipping.tip(a, sig);
    }

    function test_tip_expiredReverts() public {
        ITipping.TipAuthorization memory a = auth(address(nodl), BOB, 5e18);
        bytes memory sig = sign(signerKey, a);
        vm.warp(a.deadline + 1);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(ITipping.Expired.selector, a.deadline));
        tipping.tip(a, sig);
        // Exactly at the deadline is still valid.
        vm.warp(a.deadline);
        vm.prank(ALICE);
        tipping.tip(a, sig);
        assertEq(nodl.balanceOf(BOB), 5e18);
    }

    function test_tip_wrongSignerReverts() public {
        ITipping.TipAuthorization memory a = auth(address(nodl), BOB, 5e18);
        expectTipRevert(ALICE, otherKey, a, abi.encodeWithSelector(ITipping.InvalidSignature.selector));
    }

    function test_tip_malformedSignatureReverts() public {
        ITipping.TipAuthorization memory a = auth(address(nodl), BOB, 5e18);
        vm.prank(ALICE);
        vm.expectRevert(ITipping.InvalidSignature.selector);
        tipping.tip(a, hex"deadbeef");
    }

    function test_tip_callerMustBeTipper() public {
        ITipping.TipAuthorization memory a = auth(address(nodl), BOB, 5e18);
        bytes memory sig = sign(signerKey, a);
        nodl.mint(address(0xC0), 10e18);
        vm.prank(address(0xC0));
        nodl.approve(address(tipping), type(uint256).max);
        vm.prank(address(0xC0));
        vm.expectRevert(ITipping.InvalidSignature.selector);
        tipping.tip(a, sig);
    }

    function test_tip_tamperedFieldsInvalidateSignature() public {
        ITipping.TipAuthorization memory a = auth(address(nodl), BOB, 5e18);
        bytes memory sig = sign(signerKey, a);

        ITipping.TipAuthorization memory t = copy(a);
        t.recipient = address(0xBAD);
        vm.prank(ALICE);
        vm.expectRevert(ITipping.InvalidSignature.selector);
        tipping.tip(t, sig);

        t = copy(a);
        t.amount = 500e18;
        vm.prank(ALICE);
        vm.expectRevert(ITipping.InvalidSignature.selector);
        tipping.tip(t, sig);

        t = copy(a);
        t.token = address(usdc);
        vm.prank(ALICE);
        vm.expectRevert(ITipping.InvalidSignature.selector);
        tipping.tip(t, sig);

        t = copy(a);
        t.tokenId = 8;
        vm.prank(ALICE);
        vm.expectRevert(ITipping.InvalidSignature.selector);
        tipping.tip(t, sig);

        t = copy(a);
        t.deadline += 1;
        vm.prank(ALICE);
        vm.expectRevert(ITipping.InvalidSignature.selector);
        tipping.tip(t, sig);
    }

    function test_tip_rotatedSignerInvalidatesOldSignatures() public {
        ITipping.TipAuthorization memory a = auth(address(nodl), BOB, 5e18);
        bytes memory sig = sign(signerKey, a);
        (address next, uint256 nextKey) = makeAddrAndKey("next");
        vm.prank(ADMIN);
        vm.expectEmit(true, true, true, true);
        emit ITipping.SignerUpdated(next);
        tipping.setSigner(next);
        vm.prank(ALICE);
        vm.expectRevert(ITipping.InvalidSignature.selector);
        tipping.tip(a, sig);
        tipAs(ALICE, nextKey, a);
        assertEq(nodl.balanceOf(BOB), 5e18);
    }

    function test_tip_contractSigner() public {
        WalletSignerMock wallet = new WalletSignerMock(signer);
        vm.prank(ADMIN);
        tipping.setSigner(address(wallet));
        ITipping.TipAuthorization memory a = auth(address(nodl), BOB, 5e18);
        tipAs(ALICE, signerKey, a);
        assertEq(nodl.balanceOf(BOB), 5e18);
        expectTipRevert(
            ALICE, otherKey, auth(address(nodl), BOB, 1e18), abi.encodeWithSelector(ITipping.InvalidSignature.selector)
        );
    }

    function test_tip_guards() public {
        ITipping.TipAuthorization memory a = auth(address(nodl), ALICE, 5e18);
        expectTipRevert(ALICE, signerKey, a, abi.encodeWithSelector(ITipping.SelfTip.selector));

        a = auth(address(nodl), BOB, 0);
        expectTipRevert(ALICE, signerKey, a, abi.encodeWithSelector(ITipping.ZeroAmount.selector));

        a = auth(address(nodl), address(0), 5e18);
        expectTipRevert(ALICE, signerKey, a, abi.encodeWithSelector(ITipping.ZeroAddress.selector));

        a = auth(address(0), BOB, 5e18);
        expectTipRevert(ALICE, signerKey, a, abi.encodeWithSelector(ITipping.ZeroAddress.selector));
    }

    function test_tip_insufficientAllowanceOrBalanceReverts() public {
        nodl.mint(address(0xC0), 10e18);
        ITipping.TipAuthorization memory a = auth(address(nodl), BOB, 2e18);
        a.tipper = address(0xC0);
        bytes memory sig = sign(signerKey, a);
        vm.prank(address(0xC0));
        vm.expectRevert();
        tipping.tip(a, sig);
        vm.prank(address(0xC0));
        nodl.approve(address(tipping), type(uint256).max);
        a.amount = 11e18;
        sig = sign(signerKey, a);
        vm.prank(address(0xC0));
        vm.expectRevert();
        tipping.tip(a, sig);
    }

    // ───────── Account tips ─────────

    function test_tipAccount_paysNamedAddress() public {
        vm.expectEmit(true, true, true, true);
        emit ITipping.AccountTipped(ALICE, BOB, address(usdc), 10e6, 0);
        vm.prank(ALICE);
        tipping.tipAccount(address(usdc), BOB, 10e6);
        assertEq(usdc.balanceOf(BOB), 10e6);
    }

    function test_tipAccount_guards() public {
        vm.startPrank(ALICE);
        vm.expectRevert(ITipping.SelfTip.selector);
        tipping.tipAccount(address(nodl), ALICE, 1e18);
        vm.expectRevert(ITipping.ZeroAmount.selector);
        tipping.tipAccount(address(nodl), BOB, 0);
        vm.expectRevert(ITipping.ZeroAddress.selector);
        tipping.tipAccount(address(nodl), address(0), 1e18);
        vm.expectRevert(ITipping.ZeroAddress.selector);
        tipping.tipAccount(address(0), BOB, 1e18);
        vm.stopPrank();
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

        ITipping.TipAuthorization memory a = auth(address(nodl), BOB, 100e18);
        bytes memory sig = sign(signerKey, a);
        vm.expectEmit(true, true, true, true);
        emit ITipping.Tipped(ALICE, COLLECTION, TOKEN_ID, address(nodl), BOB, 100e18, 2.5e18);
        vm.prank(ALICE);
        tipping.tip(a, sig);
        assertEq(nodl.balanceOf(BOB), 97.5e18);
        assertEq(nodl.balanceOf(address(0xFEE)), 2.5e18);
        assertEq(nodl.transfers(), 2);

        vm.prank(ALICE);
        tipping.tipAccount(address(usdc), BOB, 100e6);
        assertEq(usdc.balanceOf(BOB), 97.5e6);
        assertEq(usdc.balanceOf(address(0xFEE)), 2.5e6);

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
        vm.prank(ALICE);
        tipping.tipAccount(address(nodl), BOB, 9_999);
        assertEq(nodl.balanceOf(BOB), 9_999);
        assertEq(nodl.balanceOf(ADMIN), 0);
    }

    function test_feeRecipientCannotBeZeroOrSelf() public {
        vm.startPrank(ADMIN);
        vm.expectRevert(ITipping.ZeroAddress.selector);
        tipping.setFeeRecipient(address(0));
        vm.expectRevert(abi.encodeWithSelector(ITipping.InvalidFeeRecipient.selector, address(tipping)));
        tipping.setFeeRecipient(address(tipping));
        vm.stopPrank();
    }

    // ───────── Roles ─────────

    function test_adminOnly() public {
        bytes memory denied =
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, ALICE, bytes32(0));
        vm.startPrank(ALICE);
        vm.expectRevert(denied);
        tipping.setSigner(BOB);
        vm.expectRevert(denied);
        tipping.setFee(1);
        vm.expectRevert(denied);
        tipping.setFeeRecipient(BOB);
        vm.stopPrank();
        vm.prank(ADMIN);
        vm.expectRevert(ITipping.ZeroAddress.selector);
        tipping.setSigner(address(0));
    }

    // ───────── Fuzz ─────────

    /// @dev The immutability argument: tokens only ever leave the caller's own balance.
    function testFuzz_transferFromOnlyFromCaller(address tipper, uint256 amount, uint16 bps, bool viaAuth) public {
        vm.assume(
            tipper != address(0) && tipper != BOB && tipper != ADMIN && tipper != address(nodl)
                && tipper != address(tipping)
        );
        amount = bound(amount, 1, 1e30);
        bps = uint16(bound(bps, 0, 1000));
        vm.prank(ADMIN);
        tipping.setFee(bps);
        nodl.mint(tipper, amount);
        vm.prank(tipper);
        nodl.approve(address(tipping), amount);

        if (viaAuth) {
            ITipping.TipAuthorization memory a = auth(address(nodl), BOB, amount);
            a.tipper = tipper;
            bytes memory sig = sign(signerKey, a);
            vm.prank(tipper);
            tipping.tip(a, sig);
        } else {
            vm.prank(tipper);
            tipping.tipAccount(address(nodl), BOB, amount);
        }

        uint256 fee = (amount * bps) / 10_000;
        uint256 n = nodl.transfers();
        uint256 moved;
        for (uint256 i; i < n; i++) {
            assertEq(nodl.senders(i), tipper);
            moved += nodl.amounts(i);
        }
        assertEq(moved, amount);
        assertEq(nodl.balanceOf(tipper), 0);
        assertEq(nodl.balanceOf(BOB), amount - fee);
        assertEq(nodl.balanceOf(ADMIN), fee);
        assertEq(n, fee > 0 ? 2 : 1);
    }

    /// @dev Any single-bit change to the signed fields produces a different digest.
    function testFuzz_digestBindsEveryField(ITipping.TipAuthorization memory a, uint8 field, uint256 delta)
        public
        view
    {
        vm.assume(delta != 0);
        ITipping.TipAuthorization memory b = copy(a);
        field = uint8(bound(field, 0, 7));
        if (field == 0) b.tipper = address(uint160(a.tipper) ^ uint160(delta | 1));
        else if (field == 1) b.token = address(uint160(a.token) ^ uint160(delta | 1));
        else if (field == 2) b.collection = address(uint160(a.collection) ^ uint160(delta | 1));
        else if (field == 3) b.tokenId = a.tokenId ^ delta;
        else if (field == 4) b.recipient = address(uint160(a.recipient) ^ uint160(delta | 1));
        else if (field == 5) b.amount = a.amount ^ delta;
        else if (field == 6) b.deadline = a.deadline ^ delta;
        else b.nonce = a.nonce ^ bytes32(delta);
        assertTrue(tipping.hashAuthorization(a) != tipping.hashAuthorization(b));
    }
}
