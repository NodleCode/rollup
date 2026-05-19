// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import {EnvelopeVault} from "../../src/envelope/V4/EnvelopeVault.sol";
import "./mocks/ERC20Mock.sol";
import "./mocks/ERC721Mock.sol";
import "./mocks/ERC1155Mock.sol";
import "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

contract EnvelopeBatchingTest is Test, ERC1155Holder, ERC721Holder {
    EnvelopeVault public vault;
    EnvelopeVault public feeVault;
    ERC20Mock public testToken;
    ERC20Mock public feeToken;
    ERC721Mock public testToken721;
    ERC1155Mock public testToken1155;

    address public constant PUBKEY20 = address(0xaBC5211D86a01c2dD50797ba7B5b32e3C1167F9f);
    uint256 public constant LINK_PRIVKEY = uint256(keccak256("batch-link-key"));
    uint256 public constant BACKEND_PRIVKEY = uint256(keccak256("batch-backend-authorizer"));
    address public constant RECIPIENT = address(0xB0B);
    address public linkPubKey;
    address public backendAuthorizer;

    function setUp() public {
        linkPubKey = vm.addr(LINK_PRIVKEY);
        backendAuthorizer = vm.addr(BACKEND_PRIVKEY);

        vault = new EnvelopeVault(address(0), address(this), address(0));
        testToken = new ERC20Mock();
        feeToken = new ERC20Mock();
        feeVault = new EnvelopeVault(backendAuthorizer, address(this), address(feeToken));
        testToken721 = new ERC721Mock();
        testToken1155 = new ERC1155Mock();
    }

    receive() external payable {}

    function testMakeBatchDepositEth() public {
        uint256 amount = 100;
        uint256 numDeposits = 10;
        address[] memory pubKeys20 = _pubKeys(numDeposits, PUBKEY20);

        uint256[] memory depositIndexes =
            vault.makeBatchDeposit{value: amount * numDeposits}(address(0), 0, amount, 0, pubKeys20);

        assertEq(depositIndexes.length, numDeposits);
        assertEq(vault.getDepositCount(), numDeposits);
        for (uint256 i = 0; i < numDeposits; ++i) {
            EnvelopeVault.Deposit memory deposit = vault.getDeposit(depositIndexes[i]);
            assertEq(deposit.amount, amount);
            assertEq(deposit.senderAddress, address(this));
        }
    }

    function testMakeBatchDepositERC20() public {
        uint256 amount = 100;
        uint256 numDeposits = 10;
        address[] memory pubKeys20 = _pubKeys(numDeposits, PUBKEY20);

        testToken.mint(address(this), amount * numDeposits);
        testToken.approve(address(vault), amount * numDeposits);

        uint256[] memory depositIndexes = vault.makeBatchDeposit(address(testToken), 1, amount, 0, pubKeys20);

        assertEq(depositIndexes.length, numDeposits);
        assertEq(testToken.balanceOf(address(vault)), amount * numDeposits);
    }

    function test_RevertIf_MakeBatchDepositERC721SameShape() public {
        address[] memory pubKeys20 = _pubKeys(2, PUBKEY20);

        vm.expectRevert(EnvelopeVault.Erc721BatchNotSupported.selector);
        vault.makeBatchDeposit(address(testToken721), 2, 1, 1, pubKeys20);
    }

    function testMakeBatchDepositERC1155() public {
        uint256 numDeposits = 10;
        address[] memory pubKeys20 = _pubKeys(numDeposits, PUBKEY20);

        testToken1155.mint(address(this), 1, numDeposits, "");
        testToken1155.setApprovalForAll(address(vault), true);

        uint256[] memory depositIndexes = vault.makeBatchDeposit(address(testToken1155), 3, 1, 1, pubKeys20);

        assertEq(depositIndexes.length, numDeposits);
        assertEq(testToken1155.balanceOf(address(vault), 1), numDeposits);
    }

    function test_RevertIf_BatchERC20DepositNotApproved() public {
        uint256 amount = 100;
        uint256 numDeposits = 10;
        address[] memory pubKeys20 = _pubKeys(numDeposits, PUBKEY20);
        testToken.mint(address(this), amount * numDeposits);

        vm.expectRevert();
        vault.makeBatchDeposit(address(testToken), 1, amount, 0, pubKeys20);
    }

    function test_RevertIf_BatchERC1155DepositNotApproved() public {
        uint256 numDeposits = 10;
        address[] memory pubKeys20 = _pubKeys(numDeposits, PUBKEY20);
        testToken1155.mint(address(this), 1, numDeposits, "");

        vm.expectRevert();
        vault.makeBatchDeposit(address(testToken1155), 3, 1, 1, pubKeys20);
    }

    function testMultipleBatchERC20DepositsInRow() public {
        uint256 amount = 100;
        uint256 numDeposits = 10;
        uint256 numberOfBatches = 3;
        address[] memory pubKeys20 = _pubKeys(numDeposits, PUBKEY20);

        for (uint256 batch = 0; batch < numberOfBatches; ++batch) {
            testToken.mint(address(this), amount * numDeposits);
            testToken.approve(address(vault), amount * numDeposits);

            uint256[] memory depositIndexes = vault.makeBatchDeposit(address(testToken), 1, amount, 0, pubKeys20);

            assertEq(depositIndexes.length, numDeposits);
        }
    }

    function testMakeBatchCustomDepositSupportsERC721Deposit() public {
        uint256 tokenId = 42;
        address[] memory tokenAddresses = new address[](1);
        uint8[] memory contractTypes = new uint8[](1);
        uint256[] memory amounts = new uint256[](1);
        uint256[] memory tokenIds = new uint256[](1);
        address[] memory pubKeys20 = new address[](1);
        bool[] memory withMFAs = new bool[](1);

        tokenAddresses[0] = address(testToken721);
        contractTypes[0] = 2;
        amounts[0] = 1;
        tokenIds[0] = tokenId;
        pubKeys20[0] = PUBKEY20;

        testToken721.mint(address(this), tokenId);
        testToken721.approve(address(vault), tokenId);

        uint256[] memory depositIndexes =
            vault.makeBatchCustomDeposit(tokenAddresses, contractTypes, amounts, tokenIds, pubKeys20, withMFAs);

        EnvelopeVault.Deposit memory deposit = vault.getDeposit(depositIndexes[0]);
        assertEq(testToken721.ownerOf(tokenId), address(vault));
        assertEq(deposit.contractType, 2);
        assertEq(deposit.tokenId, tokenId);
        assertEq(deposit.senderAddress, address(this));
    }

    function testMakeBatchCustomDepositWithFeesCollectsFeesAtDeposit() public {
        EnvelopeVault.DepositRequest[] memory requests = new EnvelopeVault.DepositRequest[](2);
        EnvelopeVault.FeeAuthorization[] memory authorizations = new EnvelopeVault.FeeAuthorization[](2);

        requests[0] = _request(address(0), 0, 1 ether, 0, false, address(0), 0);
        requests[1] = _request(address(0), 0, 2 ether, 0, true, RECIPIENT, uint40(block.timestamp + 1 days));
        authorizations[0] = _authorization(feeVault, requests[0], address(this), 0.01 ether, 0.02 ether, 0);
        authorizations[1] = _authorization(feeVault, requests[1], address(this), 0.03 ether, 0.04 ether, 0);

        feeToken.mint(address(this), 0.1 ether);
        feeToken.approve(address(feeVault), 0.1 ether);

        uint256[] memory depositIndexes =
            feeVault.makeBatchCustomDepositWithFees{value: 3 ether}(requests, authorizations);

        EnvelopeVault.Deposit memory firstDeposit = feeVault.getDeposit(depositIndexes[0]);
        EnvelopeVault.Deposit memory secondDeposit = feeVault.getDeposit(depositIndexes[1]);

        assertEq(depositIndexes.length, 2);
        assertEq(firstDeposit.senderAddress, address(this));
        assertEq(firstDeposit.serviceFee, 0.01 ether);
        assertEq(firstDeposit.gaslessFee, 0.02 ether);
        assertEq(secondDeposit.requiresMFA, true);
        assertEq(secondDeposit.recipient, RECIPIENT);
        assertEq(feeToken.balanceOf(address(feeVault)), 0.1 ether);
        assertEq(feeVault.accumulatedFees(address(feeToken)), 0.1 ether);

        bytes memory withdrawalSig =
            _signWithdrawal(feeVault, depositIndexes[0], RECIPIENT, feeVault.ANYONE_WITHDRAWAL_MODE());
        bytes memory callData =
            abi.encodeCall(EnvelopeVault.withdrawDeposit, (depositIndexes[0], RECIPIENT, withdrawalSig));
        assertTrue(feeVault.isValidGaslessOperation(RECIPIENT, callData));
    }

    function testMakeBatchCustomDepositWithFeesSupportsERC721AndERC1155() public {
        uint256 tokenId = 77;
        uint256 erc1155Id = 9;
        EnvelopeVault.DepositRequest[] memory requests = new EnvelopeVault.DepositRequest[](2);
        EnvelopeVault.FeeAuthorization[] memory authorizations = new EnvelopeVault.FeeAuthorization[](2);

        requests[0] = _request(address(testToken721), 2, 1, tokenId, false, address(0), 0);
        requests[1] = _request(address(testToken1155), 3, 5, erc1155Id, false, address(0), 0);
        authorizations[0] = _authorization(feeVault, requests[0], address(this), 1, 2, 0);
        authorizations[1] = _authorization(feeVault, requests[1], address(this), 3, 4, 0);

        testToken721.mint(address(this), tokenId);
        testToken721.approve(address(feeVault), tokenId);
        testToken1155.mint(address(this), erc1155Id, 5, "");
        testToken1155.setApprovalForAll(address(feeVault), true);
        feeToken.mint(address(this), 10);
        feeToken.approve(address(feeVault), 10);

        uint256[] memory depositIndexes = feeVault.makeBatchCustomDepositWithFees(requests, authorizations);

        EnvelopeVault.Deposit memory nftDeposit = feeVault.getDeposit(depositIndexes[0]);
        EnvelopeVault.Deposit memory multiTokenDeposit = feeVault.getDeposit(depositIndexes[1]);

        assertEq(testToken721.ownerOf(tokenId), address(feeVault));
        assertEq(testToken1155.balanceOf(address(feeVault), erc1155Id), 5);
        assertEq(nftDeposit.contractType, 2);
        assertEq(nftDeposit.tokenId, tokenId);
        assertEq(multiTokenDeposit.contractType, 3);
        assertEq(multiTokenDeposit.amount, 5);
        assertEq(feeToken.balanceOf(address(feeVault)), 10);
    }

    function test_RevertIf_BatchFeeAuthorizationIsSignedForDifferentPayer() public {
        EnvelopeVault.DepositRequest[] memory requests = new EnvelopeVault.DepositRequest[](1);
        EnvelopeVault.FeeAuthorization[] memory authorizations = new EnvelopeVault.FeeAuthorization[](1);

        requests[0] = _request(address(0), 0, 1 ether, 0, false, address(0), 0);
        authorizations[0] = _authorization(feeVault, requests[0], address(0xBAD), 0.01 ether, 0.02 ether, 0);

        feeToken.mint(address(this), 0.03 ether);
        feeToken.approve(address(feeVault), 0.03 ether);

        vm.expectRevert(EnvelopeVault.WrongFeeAuthorizationSignature.selector);
        feeVault.makeBatchCustomDepositWithFees{value: 1 ether}(requests, authorizations);
    }

    function testMakeBatchDepositRaffleEth() public {
        uint256[] memory amounts = new uint256[](4);
        amounts[0] = 10;
        amounts[1] = 20;
        amounts[2] = 30;
        amounts[3] = 40;

        uint256[] memory depositIndices = vault.makeBatchDepositRaffle{value: 100}(address(0), 0, amounts, PUBKEY20);

        for (uint256 i = 0; i < amounts.length; ++i) {
            EnvelopeVault.Deposit memory deposit = vault.getDeposit(depositIndices[i]);
            assertEq(deposit.amount, amounts[i]);
            assertEq(deposit.contractType, 0);
            assertEq(deposit.pubKey20, PUBKEY20);
            assertEq(deposit.senderAddress, address(this));
        }
    }

    function testMakeBatchDepositRaffleERC20() public {
        uint256[] memory amounts = new uint256[](4);
        amounts[0] = 10;
        amounts[1] = 20;
        amounts[2] = 30;
        amounts[3] = 40;

        testToken.mint(address(this), 100);
        testToken.approve(address(vault), 100);

        uint256[] memory depositIndices = vault.makeBatchDepositRaffle(address(testToken), 1, amounts, PUBKEY20);

        for (uint256 i = 0; i < amounts.length; ++i) {
            EnvelopeVault.Deposit memory deposit = vault.getDeposit(depositIndices[i]);
            assertEq(deposit.amount, amounts[i]);
            assertEq(deposit.contractType, 1);
            assertEq(deposit.pubKey20, PUBKEY20);
            assertEq(deposit.senderAddress, address(this));
        }
    }

    function testMakeBatchMFADepositRaffle() public {
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 10;
        amounts[1] = 20;

        uint256[] memory depositIndices = vault.makeBatchMFADepositRaffle{value: 30}(address(0), 0, amounts, PUBKEY20);

        for (uint256 i = 0; i < amounts.length; ++i) {
            EnvelopeVault.Deposit memory deposit = vault.getDeposit(depositIndices[i]);
            assertTrue(deposit.requiresMFA);
            assertEq(deposit.senderAddress, address(this));
        }
    }

    function testMakeBatchDepositNoReturnEth() public {
        address[] memory pubKeys20 = _pubKeys(3, PUBKEY20);

        vault.makeBatchDepositNoReturn{value: 3 ether}(address(0), 0, 1 ether, 0, pubKeys20);

        assertEq(vault.getDepositCount(), 3);
    }

    function testBatchZeroLengthDepositsIsNoop() public {
        address[] memory pubKeys20 = new address[](0);
        uint256[] memory ids = vault.makeBatchDeposit(address(0), 0, 0, 0, pubKeys20);

        assertEq(ids.length, 0);
        assertEq(vault.getDepositCount(), 0);
    }

    function _pubKeys(uint256 count, address pubKey20) internal pure returns (address[] memory) {
        address[] memory pubKeys20 = new address[](count);
        for (uint256 i = 0; i < count; ++i) {
            pubKeys20[i] = pubKey20;
        }
        return pubKeys20;
    }

    function _request(
        address tokenAddress,
        uint8 contractType,
        uint256 amount,
        uint256 tokenId,
        bool withMFA,
        address recipient,
        uint40 reclaimableAfter
    ) internal view returns (EnvelopeVault.DepositRequest memory) {
        return EnvelopeVault.DepositRequest({
            tokenAddress: tokenAddress,
            contractType: contractType,
            amount: amount,
            tokenId: tokenId,
            pubKey20: linkPubKey,
            onBehalfOf: address(this),
            withMFA: withMFA,
            recipient: recipient,
            reclaimableAfter: reclaimableAfter
        });
    }

    function _authorization(
        EnvelopeVault targetVault,
        EnvelopeVault.DepositRequest memory request,
        address feePayer,
        uint256 serviceFee,
        uint256 gaslessFee,
        uint256 deadline
    ) internal view returns (EnvelopeVault.FeeAuthorization memory) {
        return EnvelopeVault.FeeAuthorization({
            serviceFee: serviceFee,
            gaslessFee: gaslessFee,
            deadline: deadline,
            signature: _signFeeAuthorization(targetVault, request, feePayer, serviceFee, gaslessFee, deadline)
        });
    }

    function _signFeeAuthorization(
        EnvelopeVault targetVault,
        EnvelopeVault.DepositRequest memory request,
        address feePayer,
        uint256 serviceFee,
        uint256 gaslessFee,
        uint256 deadline
    ) internal view returns (bytes memory) {
        bytes32 digest = MessageHashUtils.toEthSignedMessageHash(
            keccak256(
                abi.encode(
                    targetVault.ENVELOPE_SALT(),
                    block.chainid,
                    address(targetVault),
                    feePayer,
                    request.tokenAddress,
                    request.contractType,
                    request.amount,
                    request.tokenId,
                    request.pubKey20,
                    request.onBehalfOf,
                    request.withMFA,
                    request.recipient,
                    request.reclaimableAfter,
                    serviceFee,
                    gaslessFee,
                    deadline
                )
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(BACKEND_PRIVKEY, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signWithdrawal(EnvelopeVault targetVault, uint256 depositIndex, address recipient, bytes32 mode)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest = MessageHashUtils.toEthSignedMessageHash(
            keccak256(
                abi.encodePacked(
                    targetVault.ENVELOPE_SALT(), block.chainid, address(targetVault), depositIndex, recipient, mode
                )
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(LINK_PRIVKEY, digest);
        return abi.encodePacked(r, s, v);
    }
}
