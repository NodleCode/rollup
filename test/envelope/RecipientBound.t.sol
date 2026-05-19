// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../../src/envelope/V4/EnvelopeVault.sol";
import "./mocks/ERC20Mock.sol";
import "./mocks/ERC721Mock.sol";
import "./mocks/ERC1155Mock.sol";

contract RecipientBoundTest is Test {
    EnvelopeVault public vault;
    ERC20Mock public testToken;
    ERC721Mock public testToken721;
    ERC1155Mock public testToken1155;

    // a dummy private/public keypair to test withdrawals
    address public constant PUBKEY20 = address(0xaBC5211D86a01c2dD50797ba7B5b32e3C1167F9f);

    address public constant SAMPLE_ADDRESS = address(0x8fd379246834eac74B8419FfdA202CF8051F7A03);
    bytes32 public constant SAMPLE_PRIVKEY = 0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa;

    function setUp() public {
        console.log("Setting up test");
        testToken = new ERC20Mock();
        vault = new EnvelopeVault(address(0));
        testToken.mint(address(this), 1000);
        testToken.approve(address(vault), 1000);
    }

    function testRecipientBoundDeposit() public {
        uint256 depositIndex = vault.makeCustomDeposit(
            address(testToken),
            1, // contract type - erc 20
            1000, // amount
            0, // tokenId. Not used for erc20 deposits.
            address(0), // pubKey20. Not used for recipient-bound deposits.
            address(this), // the depositor
            false, // no MFA
            SAMPLE_ADDRESS, // recipient
            0, // no timelock for reclaiming
            false, // not a 3009 deposit
            bytes("") // not a 3009 deposit
        );
        require(testToken.balanceOf(address(this)) == 0, "TOKEN WAS NOT CHARGED!");
        require(testToken.balanceOf(SAMPLE_ADDRESS) == 0, "SAMPLE_ADDRESS MUST NOT HAVE TOKENS AT START!");

        // Should not be able to withdraw to anybody except SAMPLE_ADDRESS
        vm.expectRevert(EnvelopeVault.WrongRecipient.selector);
        vault.withdrawDeposit(depositIndex, address(this), bytes(""));

        vault.withdrawDeposit(depositIndex, SAMPLE_ADDRESS, bytes(""));
        require(testToken.balanceOf(SAMPLE_ADDRESS) == 1000, "SAMPLE_ADDRESS SHOULD HAVE RECEIVED TOKENS!");
   }

    /*
     * Reclaim an address-bound deposit.
    */
   function testRecipientBoundReclaim() public {
        uint256 depositIndex = vault.makeCustomDeposit(
            address(testToken),
            1, // contract type - erc 20
            1000, // amount
            0, // tokenId. Not used for erc20 deposits.
            address(0), // pubKey20. Not used for recipient-bound deposits.
            address(this), // the depositor
            false, // no MFA
            SAMPLE_ADDRESS, // recipient
            uint40(block.timestamp + 10), // the sender will be able to reclaim in 10 seconds
            false, // not a 3009 deposit
            bytes("") // not a 3009 deposit
        );
        require(testToken.balanceOf(address(this)) == 0, "TOKEN WAS NOT CHARGED!");

        // Try to reclaim, but it's too early
        vm.expectRevert(EnvelopeVault.TooEarlyToReclaim.selector);
        vault.withdrawDepositSender(depositIndex);

        vm.warp(block.timestamp + 11); // advance past reclaimableAfter
        vault.withdrawDepositSender(depositIndex);
        require(testToken.balanceOf(address(this)) == 1000, "WAS NOT REFUNDED!");
   }
}
