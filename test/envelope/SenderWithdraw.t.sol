// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../../src/envelope/V4/EnvelopeVault.sol";
import "./mocks/ERC20Mock.sol";
import "./mocks/ERC721Mock.sol";
import "./mocks/ERC1155Mock.sol";
import "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";

contract TestSenderWithdrawEther is Test {
    EnvelopeVault public vault;
    // a dummy private/public keypair to test withdrawals
    address public constant PUBKEY20 = address(0xaBC5211D86a01c2dD50797ba7B5b32e3C1167F9f);
    bytes32 public constant PRIVKEY = 0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa;

    receive() external payable {} // necessary to receive ether

    function setUp() public {
        console.log("Setting up test");
        vault = new EnvelopeVault(address(0), address(this));
    }

    function testSenderWithdrawEther(uint64 amount) public {
        vm.assume(amount > 0);
        uint256 depositIdx = vault.makeDeposit{value: amount}(address(0), 0, amount, 0, PUBKEY20);

        // Withdraw the deposit
        vault.withdrawDepositSender(depositIdx);
    }
}

contract TestSenderWithdrawErc20 is Test {
    EnvelopeVault public vault;
    ERC20Mock public testToken;

    // a dummy private/public keypair to test withdrawals
    address public constant PUBKEY20 = address(0xaBC5211D86a01c2dD50797ba7B5b32e3C1167F9f);
    bytes32 public constant PRIVKEY = 0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa;

    uint256 _depositIdx;

    // apparently not possible to fuzz test in setUp() function?
    function setUp() public {
        console.log("Setting up test");
        vault = new EnvelopeVault(address(0), address(this));
        testToken = new ERC20Mock(); // contractType 1

        // Mint tokens for test accounts (larger than uint128)
        testToken.mint(address(this), 2 ** 130);

        // Approve the contract to spend the tokens
        testToken.approve(address(vault), 2 ** 130);

        // Make a deposit
        uint256 amount = 2 ** 128;
        _depositIdx = vault.makeDeposit(address(testToken), 1, amount, 0, PUBKEY20);
    }

    function testSenderWithdrawErc20() public {
        // Withdraw the deposit
        vault.withdrawDepositSender(_depositIdx);
    }
}

contract TestSenderWithdrawErc721 is Test, ERC721Holder {
    EnvelopeVault public vault;
    ERC721Mock public testToken;

    // a dummy private/public keypair to test withdrawals
    address public constant PUBKEY20 = address(0xaBC5211D86a01c2dD50797ba7B5b32e3C1167F9f);
    bytes32 public constant PRIVKEY = 0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa;

    uint256 _depositIdx;
    uint256 _tokenId = 1; // tokenId used for ERC721

    // apparently not possible to fuzz test in setUp() function?
    function setUp() public {
        console.log("Setting up test");
        vault = new EnvelopeVault(address(0), address(this));
        testToken = new ERC721Mock(); // contractType 2

        // Mint token for test
        testToken.mint(address(this), _tokenId);

        // Approve the contract to spend the tokens
        testToken.approve(address(vault), _tokenId);

        // Make a deposit
        _depositIdx = vault.makeDeposit(address(testToken), 2, 1, _tokenId, PUBKEY20);
    }

    function testSenderWithdrawErc721() public {
        // Withdraw the deposit
        vault.withdrawDepositSender(_depositIdx);
    }
}

contract TestSenderWithdrawErc1155 is Test, ERC1155Holder {
    EnvelopeVault public vault;
    ERC1155Mock public testToken;

    // a dummy private/public keypair to test withdrawals
    address public constant PUBKEY20 = address(0xaBC5211D86a01c2dD50797ba7B5b32e3C1167F9f);
    bytes32 public constant PRIVKEY = 0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa;

    uint256 _depositIdx;
    uint256 _tokenId = 1;

    function setUp() public {
        console.log("Setting up test");
        vault = new EnvelopeVault(address(0), address(this));
        testToken = new ERC1155Mock();

        // Mint tokens
        testToken.mint(address(this), _tokenId, 100, "");
        testToken.setApprovalForAll(address(vault), true);

        // Make a deposit
        _depositIdx = vault.makeDeposit(address(testToken), 3, 100, _tokenId, PUBKEY20);
    }

    function testSenderWithdrawErc1155() public {
        // Withdraw the deposit
        vault.withdrawDepositSender(_depositIdx);
    }
}
