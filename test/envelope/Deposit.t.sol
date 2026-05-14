// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.19;

//////////////////////////////
// A few integration tests for the EnvelopeVault contract
//////////////////////////////

import "forge-std/Test.sol";
import "../../src/envelope/V4/PeanutV4.4.sol";
import "./mocks/ERC20Mock.sol";
import "./mocks/ERC721Mock.sol";
import "./mocks/ERC1155Mock.sol";
import "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";

contract EnvelopeVaultDepositTest is Test, ERC1155Holder, ERC721Holder {
    EnvelopeVault public vault;
    ERC20Mock public testToken;
    ERC721Mock public testToken721;
    ERC1155Mock public testToken1155;

    // a dummy private/public keypair to test withdrawals
    address public constant PUBKEY20 = address(0xaBC5211D86a01c2dD50797ba7B5b32e3C1167F9f);
    bytes32 public constant PRIVKEY = 0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa;

    function setUp() public {
        console.log("Setting up test");
        vault = new EnvelopeVault(address(0), address(0));
        testToken = new ERC20Mock();
        testToken721 = new ERC721Mock();
        testToken1155 = new ERC1155Mock();
    }

    // make contract payable
    receive() external payable {}

    // Make a deposit, withdraw the deposit.
    // check invariants
    function testDepositEther(uint64 amount, address randomAddress) public {
        vm.assume(amount > 0);
        vault.makeDeposit{value: amount}(randomAddress, 0, amount, 0, PUBKEY20);
    }

    function testDepositERC20(uint64 amount) public {
        vm.assume(amount > 0);
        // mint tokens to the contract
        testToken.mint(address(this), amount);
        // approve the contract to spend the tokens
        testToken.approve(address(vault), amount);
        // console log allowance and amount
        console.log("Allowance: ", testToken.allowance(address(this), address(vault)));
        console.log("Amount: ", amount);
        vault.makeDeposit(address(testToken), 1, amount, 0, PUBKEY20);
    }

    // Test for ERC721 Token
    function testDepositERC721(uint64 tokenId) public {
        // mint a token to the contract
        testToken721.mint(address(this), tokenId);
        // approve the contract to spend the tokens
        testToken721.approve(address(vault), tokenId);
        vault.makeDeposit(address(testToken721), 2, 1, tokenId, PUBKEY20);
    }

    // Test for ERC1155 Token
    function testDepositERC1155(uint64 tokenId, uint64 amount) public {
        vm.assume(amount > 0);
        // mint tokens to the contract
        testToken1155.mint(address(this), tokenId, amount, "");
        // approve the contract to spend the tokens
        testToken1155.setApprovalForAll(address(vault), true);
        vault.makeDeposit(address(testToken1155), 3, amount, tokenId, PUBKEY20);
    }
}
