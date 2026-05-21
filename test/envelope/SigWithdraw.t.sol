// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../../src/envelope/EnvelopeLinks.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

contract TestSigWithdrawEther is Test {
    EnvelopeLinks public vault;

    uint256 constant LINK_PRIV = 0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa;
    address _pubkey20;
    address _recipientAddress = 0x6B3751c5b04Aa818EA90115AA06a4D9A36A16f02;

    receive() external payable {}

    function setUp() public {
        vault = new EnvelopeLinks(address(0), address(this), address(0));
        _pubkey20 = vm.addr(LINK_PRIV);
    }

    function _signOpen(uint256 idx, address recipient) internal view returns (bytes memory) {
        bytes32 digest = MessageHashUtils.toEthSignedMessageHash(
            keccak256(
                abi.encodePacked(
                    vault.ENVELOPE_SALT(), block.chainid, address(vault), idx, recipient, vault.OPEN_CLAIM_MODE()
                )
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(LINK_PRIV, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signBound(uint256 idx, address recipient) internal view returns (bytes memory) {
        bytes32 digest = MessageHashUtils.toEthSignedMessageHash(
            keccak256(
                abi.encodePacked(
                    vault.ENVELOPE_SALT(), block.chainid, address(vault), idx, recipient, vault.BOUND_CLAIM_MODE()
                )
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(LINK_PRIV, digest);
        return abi.encodePacked(r, s, v);
    }

    function testSigWithdrawEther(uint64 amount) public {
        vm.assume(amount > 0);
        uint256 depositIdx = vault.createLink{value: amount}(address(0), 0, amount, 0, _pubkey20);
        bytes memory sigAnybody = _signOpen(depositIdx, _recipientAddress);

        // Can't use claimAsBoundRecipient on unbound link
        vm.prank(_recipientAddress);
        vm.expectRevert(EnvelopeLinks.LinkNotRecipientBound.selector);
        vault.claimAsBoundRecipient(depositIdx, _recipientAddress, sigAnybody);

        // Anybody can withdraw with open-mode signature
        vault.claim(depositIdx, _recipientAddress, sigAnybody);
    }

    function testWithdrawDepositAsRecipient(uint64 amount) public {
        vm.assume(amount > 0);
        uint256 depositIdx = vault.createCustomLink{value: amount}(
            address(0), 0, amount, 0, _pubkey20, address(this), false, _recipientAddress, 0
        );
        bytes memory sigBound = _signBound(depositIdx, _recipientAddress);

        // Can't use open claim with bound-mode signature
        vm.expectRevert(EnvelopeLinks.WrongSignature.selector);
        vault.claim(depositIdx, _recipientAddress, sigBound);

        // Non-recipient caller is rejected
        vm.expectRevert(EnvelopeLinks.NotTheRecipient.selector);
        vault.claimAsBoundRecipient(depositIdx, _recipientAddress, sigBound);

        vm.prank(_recipientAddress);
        vault.claimAsBoundRecipient(depositIdx, _recipientAddress, sigBound);
    }
}
