// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../../src/envelope/V4/EnvelopeVault.sol";
import "../../src/envelope/util/IPaymaster.sol";

contract MockPaymaster is IPaymaster {
    bool public shouldRevert;
    uint256 public lastFee;
    address public lastOperator;

    function validateSponsoredOperation(address operator, uint256 fee) external {
        if (shouldRevert) revert("paymaster: denied");
        lastOperator = operator;
        lastFee = fee;
    }

    function setRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    receive() external payable {}
}

contract EnvelopeVaultSponsoredTest is Test {
    EnvelopeVault public vault;
    MockPaymaster public paymaster;

    // Link keypair
    uint256 public constant LINK_PRIVKEY = uint256(keccak256("link-key"));
    address public LINK_PUBKEY;

    // MFA authorizer
    uint256 public constant MFA_PRIVKEY = uint256(keccak256("nodle.vault.mfa-authorizer"));
    address public MFA_AUTHORIZER;

    // Sender (depositor) keypair for sponsored reclaim
    uint256 public constant SENDER_PRIVKEY = uint256(keccak256("sender-key"));
    address public SENDER;

    // Operator (relayer) who submits the tx
    address public constant OPERATOR = address(0xBEEF);

    function setUp() public {
        LINK_PUBKEY = vm.addr(LINK_PRIVKEY);
        MFA_AUTHORIZER = vm.addr(MFA_PRIVKEY);
        SENDER = vm.addr(SENDER_PRIVKEY);

        vault = new EnvelopeVault(MFA_AUTHORIZER, address(this));
        paymaster = new MockPaymaster();

        vm.deal(SENDER, 10 ether);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Helpers
    // ═══════════════════════════════════════════════════════════════════════════

    function _makeDeposit(uint256 amount, bool withMFA) internal returns (uint256) {
        return vault.makeCustomDeposit{value: amount}(
            address(0), 0, amount, 0, LINK_PUBKEY, SENDER, withMFA, address(0), 0
        );
    }

    function _signWithdrawal(uint256 depositIndex, address recipient) internal view returns (bytes memory) {
        bytes32 digest = MessageHashUtils.toEthSignedMessageHash(
            keccak256(
                abi.encodePacked(
                    vault.ENVELOPE_SALT(),
                    block.chainid,
                    address(vault),
                    depositIndex,
                    recipient,
                    vault.ANYONE_WITHDRAWAL_MODE()
                )
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(LINK_PRIVKEY, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signMfa(uint256 depositIndex, address recipient, uint256 serviceFee, uint256 gasAbsorptionFee)
        internal view returns (bytes memory)
    {
        bytes32 digest = MessageHashUtils.toEthSignedMessageHash(
            keccak256(
                abi.encodePacked(
                    vault.ENVELOPE_SALT(),
                    block.chainid,
                    address(vault),
                    depositIndex,
                    recipient,
                    serviceFee,
                    gasAbsorptionFee
                )
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(MFA_PRIVKEY, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signGaslessReclaim(uint256 depositIndex) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                vault.GASLESS_RECLAIM_TYPEHASH(),
                depositIndex
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", vault.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SENDER_PRIVKEY, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signMfaForReclaim(uint256 depositIndex, address signer, uint256 gasAbsorptionFee)
        internal view returns (bytes memory)
    {
        bytes32 digest = MessageHashUtils.toEthSignedMessageHash(
            keccak256(
                abi.encodePacked(
                    vault.ENVELOPE_SALT(),
                    block.chainid,
                    address(vault),
                    depositIndex,
                    signer,
                    gasAbsorptionFee
                )
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(MFA_PRIVKEY, digest);
        return abi.encodePacked(r, s, v);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // withdrawMFADepositSponsored tests
    // ═══════════════════════════════════════════════════════════════════════════

    function test_WithdrawMFADepositSponsored() public {
        uint256 depositAmount = 1 ether;
        uint256 serviceFee = 0.01 ether;
        uint256 gasAbsorptionFee = 0.005 ether;

        vm.prank(SENDER);
        uint256 idx = _makeDeposit(depositAmount, true);

        bytes memory linkSig = _signWithdrawal(idx, address(this));
        bytes memory mfaSig = _signMfa(idx, address(this), serviceFee, gasAbsorptionFee);

        uint256 balBefore = address(this).balance;
        vm.prank(OPERATOR);
        vault.withdrawMFADepositSponsored(
            idx, address(this), linkSig, mfaSig, serviceFee, gasAbsorptionFee, address(paymaster)
        );
        uint256 balAfter = address(this).balance;

        // Recipient gets deposit minus both fees
        assertEq(balAfter - balBefore, depositAmount - serviceFee - gasAbsorptionFee);

        // Service fee accumulated
        assertEq(vault.accumulatedFees(address(0)), serviceFee);

        // Gas absorption fee sent to paymaster
        assertEq(address(paymaster).balance, gasAbsorptionFee);

        // Paymaster was called with correct args
        assertEq(paymaster.lastOperator(), OPERATOR);
        assertEq(paymaster.lastFee(), gasAbsorptionFee);
    }

    function test_RevertIf_SponsoredClaimPaymasterDenies() public {
        vm.prank(SENDER);
        uint256 idx = _makeDeposit(1 ether, true);

        bytes memory linkSig = _signWithdrawal(idx, address(this));
        bytes memory mfaSig = _signMfa(idx, address(this), 0, 0.01 ether);

        paymaster.setRevert(true);

        vm.prank(OPERATOR);
        vm.expectRevert("paymaster: denied");
        vault.withdrawMFADepositSponsored(
            idx, address(this), linkSig, mfaSig, 0, 0.01 ether, address(paymaster)
        );
    }

    function test_RevertIf_SponsoredClaimFeeExceedsDeposit() public {
        vm.prank(SENDER);
        uint256 idx = _makeDeposit(1 ether, true);

        uint256 bigFee = 2 ether;
        bytes memory linkSig = _signWithdrawal(idx, address(this));
        bytes memory mfaSig = _signMfa(idx, address(this), bigFee, 0);

        vm.prank(OPERATOR);
        vm.expectRevert(EnvelopeVault.FeeExceedsDepositAmount.selector);
        vault.withdrawMFADepositSponsored(
            idx, address(this), linkSig, mfaSig, bigFee, 0, address(paymaster)
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // withdrawDepositSenderSponsored tests
    // ═══════════════════════════════════════════════════════════════════════════

    function test_WithdrawDepositSenderSponsored() public {
        uint256 depositAmount = 1 ether;
        uint256 gasAbsorptionFee = 0.01 ether;

        vm.prank(SENDER);
        uint256 idx = _makeDeposit(depositAmount, false);

        EnvelopeVault.GaslessReclaim memory reclaim = EnvelopeVault.GaslessReclaim({
            depositIndex: idx
        });

        bytes memory senderSig = _signGaslessReclaim(idx);
        bytes memory mfaSig = _signMfaForReclaim(idx, SENDER, gasAbsorptionFee);

        uint256 senderBalBefore = SENDER.balance;

        vm.prank(OPERATOR);
        vault.withdrawDepositSenderSponsored(reclaim, SENDER, senderSig, mfaSig, gasAbsorptionFee, address(paymaster));

        // Sender gets deposit minus gas fee
        uint256 senderBalAfter = SENDER.balance;
        assertEq(senderBalAfter - senderBalBefore, depositAmount - gasAbsorptionFee);

        // Gas fee sent to paymaster
        assertEq(address(paymaster).balance, gasAbsorptionFee);

        // Paymaster validated
        assertEq(paymaster.lastOperator(), OPERATOR);
        assertEq(paymaster.lastFee(), gasAbsorptionFee);
    }

    function test_RevertIf_SponsoredReclaimWrongSender() public {
        vm.prank(SENDER);
        uint256 idx = _makeDeposit(1 ether, false);

        EnvelopeVault.GaslessReclaim memory reclaim = EnvelopeVault.GaslessReclaim({
            depositIndex: idx
        });

        // Sign with a different key (not the depositor)
        uint256 wrongKey = uint256(keccak256("wrong-key"));
        address wrongSigner = vm.addr(wrongKey);

        bytes32 structHash = keccak256(abi.encode(vault.GASLESS_RECLAIM_TYPEHASH(), idx));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", vault.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongKey, digest);
        bytes memory wrongSig = abi.encodePacked(r, s, v);

        bytes memory mfaSig = _signMfaForReclaim(idx, wrongSigner, 0);

        vm.prank(OPERATOR);
        vm.expectRevert(EnvelopeVault.NotTheSender.selector);
        vault.withdrawDepositSenderSponsored(reclaim, wrongSigner, wrongSig, mfaSig, 0, address(paymaster));
    }

    function test_RevertIf_SponsoredReclaimPaymasterDenies() public {
        vm.prank(SENDER);
        uint256 idx = _makeDeposit(1 ether, false);

        EnvelopeVault.GaslessReclaim memory reclaim = EnvelopeVault.GaslessReclaim({
            depositIndex: idx
        });

        bytes memory senderSig = _signGaslessReclaim(idx);
        bytes memory mfaSig = _signMfaForReclaim(idx, SENDER, 0.01 ether);

        paymaster.setRevert(true);

        vm.prank(OPERATOR);
        vm.expectRevert("paymaster: denied");
        vault.withdrawDepositSenderSponsored(reclaim, SENDER, senderSig, mfaSig, 0.01 ether, address(paymaster));
    }

    receive() external payable {}
}
