// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../../src/envelope/V4/EnvelopeVault.sol";

contract EnvelopeVaultMFATest is Test {
    EnvelopeVault public vault;

    // a dummy private/public keypair to test withdrawals
    address public constant SAMPLE_ADDRESS = address(0x8fd379246834eac74B8419FfdA202CF8051F7A03);
    bytes32 public constant SAMPLE_PRIVKEY = 0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa;

    // Upstream Squirrel-Labs MFA authorizer address. The hardcoded `authorization` blob below
    // was signed by the corresponding offline private key — keep both together.
    address public constant LEGACY_MFA_AUTHORIZER = 0x3B14D43Bf521EF7FD9600533bEB73B6e9178DE7C;

    function setUp() public {
        vault = new EnvelopeVault(address(0), LEGACY_MFA_AUTHORIZER);
    }

    function testMFADeposit() public {
      uint256 depositIndex = vault.makeSelflessMFADeposit{value: 1}(
        0x0000000000000000000000000000000000000000,
        0,
        1,
        0,
        SAMPLE_ADDRESS,
        0x0000000000000000000000000000000000001234);

        bytes32 digest = MessageHashUtils.toEthSignedMessageHash(
            keccak256(
                abi.encodePacked(
                    vault.ENVELOPE_SALT(),
                    block.chainid,
                    address(vault),
                    depositIndex,
                    address(this), // recipient
                    vault.ANYONE_WITHDRAWAL_MODE()
                )
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(uint256(SAMPLE_PRIVKEY), digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        // Withdrawing without authorization, so should fail
        vm.expectRevert("REQUIRES AUTHORIZATION");
        vault.withdrawDeposit(depositIndex, address(this), signature);

        // Withdrawing with incorrect authorization signature
        vm.expectRevert("WRONG MFA SIGNATURE");
        vault.withdrawMFADeposit(depositIndex, address(this), signature, signature);

        // Authorization is correct! Withdrawal has to be successful!
        bytes memory authorization = hex"41caae599d693a31ea45aab95c8d166e9709cb450f1c76a2b06306ee61cb28b37ed0cad0d47d055580ce204ac9973b671a0970d02f9ee6572a9234f3130707321c";
        vault.withdrawMFADeposit(depositIndex, address(this), signature, authorization);
    }

    receive () payable external {}
}