// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../../src/envelope/V4/EnvelopeVault.sol";
import "./mocks/ERC20Mock.sol";
import "./mocks/ERC721Mock.sol";
import "./mocks/ERC1155Mock.sol";

contract EnvelopeVaultTest is Test {
    EnvelopeVault public vault;
    ERC20Mock public testToken;
    ERC721Mock public testToken721;
    ERC1155Mock public testToken1155;

    // a dummy private/public keypair to test withdrawals
    address public constant PUBKEY20 = address(0xaBC5211D86a01c2dD50797ba7B5b32e3C1167F9f);

    address public constant SAMPLE_ADDRESS = address(0x8fd379246834eac74B8419FfdA202CF8051F7A03);
    bytes32 public constant SAMPLE_PRIVKEY = 0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa;

    // For EIP-3009 testing
    // keccak256("ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)")
    bytes32 public constant RECEIVE_WITH_AUTHORIZATION_TYPEHASH =
        0xd099cc98ef71107a616c4f0f941f04c322d8e254fe26b3c6668db87aae413de8;
    bytes32 public DOMAIN_SEPARATOR = 0xcaa2ce1a5703ccbe253a34eb3166df60a705c561b44b192061e28f2a985be2ca;

    function setUp() public {
        console.log("Setting up test");
        testToken = new ERC20Mock();
        testToken721 = new ERC721Mock();
        testToken1155 = new ERC1155Mock();
        vault = new EnvelopeVault(address(0));

        // Mint tokens for test accounts
        testToken.mint(address(this), 1000);
        testToken721.mint(address(this), 1);

        // Approve EnvelopeVault to spend tokens
        testToken.approve(address(vault), 1000);
        testToken721.setApprovalForAll(address(vault), true);
    }

    function testContractCreation() public {
        assertTrue(address(vault) != address(0), "Contract creation failed");
    }

    function testMakeDepositERC20() public {
        uint256 amount = 100;

        uint256 depositIndex = vault.makeDeposit(address(testToken), 1, amount, 0, PUBKEY20);

        assertEq(depositIndex, 0, "Deposit failed");
        assertEq(vault.getDepositCount(), 1, "Deposit count mismatch");
    }

    function testMakeSelflessDepositERC20() public {
        uint256 amount = 100;

        // Make a deposit on behalf of SAMPLE_ADDRESS
        uint256 depositIndex = vault.makeSelflessDeposit(address(testToken), 1, amount, 0, PUBKEY20, SAMPLE_ADDRESS);

        // Deposit was made on behalf of other address, so we can't withdraw
        vm.expectRevert(EnvelopeVault.NotTheSender.selector);
        vault.withdrawDepositSender(depositIndex);

        vm.prank(SAMPLE_ADDRESS); // selfless deposit's owner can reclaim
        vault.withdrawDepositSender(depositIndex);
    }

    function testMakeDepositERC721() public {
        uint256 tokenId = 1;

        uint256 depositIndex = vault.makeDeposit(address(testToken721), 2, 1, tokenId, PUBKEY20);

        assertEq(depositIndex, 0, "Deposit failed");
        assertEq(vault.getDepositCount(), 1, "Deposit count mismatch");
    }

    // test sender withdrawal
    function testSenderTimeWithdraw() public {
        uint256 amount = 1000;

        assertEq(testToken.balanceOf(address(vault)), 0, "Contract balance mismatch");
        uint256 depositIndex = vault.makeDeposit(address(testToken), 1, amount, 0, PUBKEY20);

        assertEq(depositIndex, 0, "Deposit failed");
        assertEq(vault.getDepositCount(), 1, "Deposit count mismatch");
        assertEq(testToken.balanceOf(address(vault)), 1000, "Contract balance mismatch");

        // wait 25 hours
        vm.warp(block.timestamp + 25 hours);

        // Withdraw the deposit
        vault.withdrawDepositSender(depositIndex);

        // Check that the contract has the correct balance
        assertEq(testToken.balanceOf(address(vault)), 0, "Contract balance mismatch");
        assertEq(testToken.balanceOf(address(this)), 1000, "Sender balance mismatch");
    }
}
