// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../../src/envelope/V4/EnvelopeVault.sol";

contract EnvelopeVaultMFATest is Test {
    EnvelopeVault public vault;

    // a dummy private/public keypair to test withdrawals
    address public constant SAMPLE_ADDRESS = address(0x8fd379246834eac74B8419FfdA202CF8051F7A03);
    bytes32 public constant SAMPLE_PRIVKEY = 0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa;

    // MFA authorizer key pair for testing
    uint256 public constant MFA_PRIVKEY = uint256(keccak256("nodle.vault.mfa-authorizer"));
    address public MFA_AUTHORIZER;

    function setUp() public {
        MFA_AUTHORIZER = vm.addr(MFA_PRIVKEY);
        vault = new EnvelopeVault(MFA_AUTHORIZER, address(this));
    }

    function _signMfa(uint256 depositIndex, address recipient, uint256 serviceFee, uint256 gasAbsorptionFee, uint256 deadline)
        internal
        view
        returns (bytes memory)
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
                    gasAbsorptionFee,
                    deadline
                )
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(MFA_PRIVKEY, digest);
        return abi.encodePacked(r, s, v);
    }

    function testMFADeposit() public {
        uint256 depositIndex = vault.makeSelflessMFADeposit{value: 1 ether}(
            address(0),
            0,
            1 ether,
            0,
            SAMPLE_ADDRESS,
            address(0x1234)
        );

        // Build withdrawal signature
        bytes32 wdDigest = MessageHashUtils.toEthSignedMessageHash(
            keccak256(
                abi.encodePacked(
                    vault.ENVELOPE_SALT(),
                    block.chainid,
                    address(vault),
                    depositIndex,
                    address(this),
                    vault.ANYONE_WITHDRAWAL_MODE()
                )
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(uint256(SAMPLE_PRIVKEY), wdDigest);
        bytes memory signature = abi.encodePacked(r, s, v);

        // Withdrawing without authorization should fail
        vm.expectRevert(EnvelopeVault.RequiresMfaAuthorization.selector);
        vault.withdrawDeposit(depositIndex, address(this), signature);

        // Withdrawing with incorrect MFA signature should fail
        vm.expectRevert(EnvelopeVault.WrongMfaSignature.selector);
        vault.withdrawMFADeposit(depositIndex, address(this), signature, signature, 0, 0, 0);

        // Correct MFA authorization with zero fees and no deadline
        bytes memory mfaSig = _signMfa(depositIndex, address(this), 0, 0, 0);
        vault.withdrawMFADeposit(depositIndex, address(this), signature, mfaSig, 0, 0, 0);
    }

    function testMFADepositWithFees() public {
        uint256 depositAmount = 1 ether;
        uint256 serviceFee = 0.01 ether;
        uint256 gasAbsorptionFee = 0.005 ether;

        uint256 depositIndex = vault.makeSelflessMFADeposit{value: depositAmount}(
            address(0),
            0,
            depositAmount,
            0,
            SAMPLE_ADDRESS,
            address(0x1234)
        );

        // Build withdrawal signature
        bytes32 wdDigest = MessageHashUtils.toEthSignedMessageHash(
            keccak256(
                abi.encodePacked(
                    vault.ENVELOPE_SALT(),
                    block.chainid,
                    address(vault),
                    depositIndex,
                    address(this),
                    vault.ANYONE_WITHDRAWAL_MODE()
                )
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(uint256(SAMPLE_PRIVKEY), wdDigest);
        bytes memory signature = abi.encodePacked(r, s, v);

        // MFA signature with fees and no deadline
        bytes memory mfaSig = _signMfa(depositIndex, address(this), serviceFee, gasAbsorptionFee, 0);

        uint256 balBefore = address(this).balance;
        vault.withdrawMFADeposit(depositIndex, address(this), signature, mfaSig, serviceFee, gasAbsorptionFee, 0);
        uint256 balAfter = address(this).balance;

        // Recipient gets deposit minus fees
        assertEq(balAfter - balBefore, depositAmount - serviceFee - gasAbsorptionFee);

        // Fees accumulated in contract
        assertEq(vault.accumulatedFees(address(0)), serviceFee + gasAbsorptionFee);
    }

    function testWithdrawFeesOnlyOwner() public {
        // Make deposit + withdraw with fees to accumulate some
        uint256 depositAmount = 1 ether;
        uint256 serviceFee = 0.01 ether;

        uint256 depositIndex = vault.makeSelflessMFADeposit{value: depositAmount}(
            address(0), 0, depositAmount, 0, SAMPLE_ADDRESS, address(0x1234)
        );

        bytes32 wdDigest = MessageHashUtils.toEthSignedMessageHash(
            keccak256(
                abi.encodePacked(
                    vault.ENVELOPE_SALT(), block.chainid, address(vault),
                    depositIndex, address(this), vault.ANYONE_WITHDRAWAL_MODE()
                )
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(uint256(SAMPLE_PRIVKEY), wdDigest);
        bytes memory signature = abi.encodePacked(r, s, v);
        bytes memory mfaSig = _signMfa(depositIndex, address(this), serviceFee, 0, 0);
        vault.withdrawMFADeposit(depositIndex, address(this), signature, mfaSig, serviceFee, 0, 0);

        // Non-owner cannot withdraw fees
        vm.prank(address(0xdead));
        vm.expectRevert();
        vault.withdrawFees(address(0));

        // Owner can withdraw
        uint256 balBefore = address(this).balance;
        vault.withdrawFees(address(0));
        assertEq(address(this).balance - balBefore, serviceFee);
        assertEq(vault.accumulatedFees(address(0)), 0);
    }

    function test_RevertIf_FeeExceedsDeposit() public {
        uint256 depositAmount = 0.01 ether;

        uint256 depositIndex = vault.makeSelflessMFADeposit{value: depositAmount}(
            address(0), 0, depositAmount, 0, SAMPLE_ADDRESS, address(0x1234)
        );

        bytes32 wdDigest = MessageHashUtils.toEthSignedMessageHash(
            keccak256(
                abi.encodePacked(
                    vault.ENVELOPE_SALT(), block.chainid, address(vault),
                    depositIndex, address(this), vault.ANYONE_WITHDRAWAL_MODE()
                )
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(uint256(SAMPLE_PRIVKEY), wdDigest);
        bytes memory signature = abi.encodePacked(r, s, v);

        // Fee exceeds deposit
        uint256 bigFee = 1 ether;
        bytes memory mfaSig = _signMfa(depositIndex, address(this), bigFee, 0, 0);
        vm.expectRevert(EnvelopeVault.FeeExceedsDepositAmount.selector);
        vault.withdrawMFADeposit(depositIndex, address(this), signature, mfaSig, bigFee, 0, 0);
    }

    receive() payable external {}
}
