// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../../src/envelope/EnvelopeVault.sol";

contract EnvelopeVaultMFATest is Test {
    EnvelopeVault public vault;

    address public constant SAMPLE_ADDRESS = address(0x8fd379246834eac74B8419FfdA202CF8051F7A03);
    bytes32 public constant SAMPLE_PRIVKEY = 0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa;

    uint256 public constant MFA_PRIVKEY = uint256(keccak256("nodle.vault.mfa-authorizer"));
    address public MFA_AUTHORIZER;

    function setUp() public {
        MFA_AUTHORIZER = vm.addr(MFA_PRIVKEY);
        vault = new EnvelopeVault(MFA_AUTHORIZER, address(this), address(0));
    }

    function _signMfa(uint256 depositIndex, address recipient, uint256 deadline) internal view returns (bytes memory) {
        bytes32 digest = MessageHashUtils.toEthSignedMessageHash(
            keccak256(
                abi.encodePacked(
                    vault.ENVELOPE_SALT(), block.chainid, address(vault), depositIndex, recipient, deadline
                )
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(MFA_PRIVKEY, digest);
        return abi.encodePacked(r, s, v);
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
                    vault.OPEN_CLAIM_MODE()
                )
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(uint256(SAMPLE_PRIVKEY), digest);
        return abi.encodePacked(r, s, v);
    }

    function testMFADeposit() public {
        uint256 depositIndex =
            vault.createMFALinkFor{value: 1 ether}(address(0), 0, 1 ether, 0, SAMPLE_ADDRESS, address(0x1234));

        bytes memory withdrawalSig = _signWithdrawal(depositIndex, address(this));

        vm.expectRevert(EnvelopeVault.RequiresMfaAuthorization.selector);
        vault.claim(depositIndex, address(this), withdrawalSig);

        vm.expectRevert(EnvelopeVault.WrongMfaSignature.selector);
        vault.claimWithMFA(depositIndex, address(this), withdrawalSig, withdrawalSig, 0);

        bytes memory mfaSig = _signMfa(depositIndex, address(this), 0);
        vault.claimWithMFA(depositIndex, address(this), withdrawalSig, mfaSig, 0);
    }

    function testMFADepositWithDeadline() public {
        uint256 depositIndex =
            vault.createMFALinkFor{value: 1 ether}(address(0), 0, 1 ether, 0, SAMPLE_ADDRESS, address(0x1234));

        uint256 deadline = block.timestamp + 1 hours;
        bytes memory withdrawalSig = _signWithdrawal(depositIndex, address(this));
        bytes memory mfaSig = _signMfa(depositIndex, address(this), deadline);

        vault.claimWithMFA(depositIndex, address(this), withdrawalSig, mfaSig, deadline);
    }

    function test_RevertIf_MfaSignatureExpired() public {
        uint256 depositIndex =
            vault.createMFALinkFor{value: 1 ether}(address(0), 0, 1 ether, 0, SAMPLE_ADDRESS, address(0x1234));

        uint256 deadline = block.timestamp + 1 hours;
        bytes memory withdrawalSig = _signWithdrawal(depositIndex, address(this));
        bytes memory mfaSig = _signMfa(depositIndex, address(this), deadline);

        vm.warp(deadline + 1);

        vm.expectRevert(EnvelopeVault.MfaSignatureExpired.selector);
        vault.claimWithMFA(depositIndex, address(this), withdrawalSig, mfaSig, deadline);
    }

    receive() external payable {}
}
