// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {L1Bridge} from "src/bridge/L1Bridge.sol";
import {IL1Bridge} from "src/bridge/interfaces/IL1Bridge.sol";
import {IL2Bridge} from "src/bridge/interfaces/IL2Bridge.sol";
import {IWithdrawalMessage} from "src/bridge/interfaces/IWithdrawalMessage.sol";
import {L1Nodl} from "src/L1Nodl.sol";
import {IMailbox} from "lib/era-contracts/l1-contracts/contracts/state-transition/chain-interfaces/IMailbox.sol";
import {L2Message, TxStatus} from "lib/era-contracts/l1-contracts/contracts/common/Messaging.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

/// @dev Minimal mock for zkSync Era Mailbox to drive L1Bridge tests.
contract MockMailbox { /* not inheriting IMailbox on purpose */
    mapping(bytes32 => bool) public l1ToL2Failed; // txHash => failed?
    mapping(uint256 => mapping(uint256 => bool)) public l2InclusionOk; // batch=>index => ok?

    bytes32 public lastRequestedTxHash;
    address public lastRefundRecipient;
    uint256 public baseCostReturn;

    // Allow tests to toggle outcomes
    function setL1ToL2Failed(bytes32 txHash, bool failed) external {
        l1ToL2Failed[txHash] = failed;
    }

    function setInclusion(uint256 batch, uint256 index, bool ok) external {
        l2InclusionOk[batch][index] = ok;
    }

    function setBaseCostReturn(uint256 value) external {
        baseCostReturn = value;
    }

    // --- Methods used by L1Bridge ---
    function requestL2Transaction(
        address _contractL2,
        uint256 _l2Value,
        bytes calldata _calldata,
        uint256 _l2GasLimit,
        uint256 _l2GasPerPubdataByte,
        bytes[] calldata, /*_factoryDeps*/
        address _refundRecipient
    ) external payable returns (bytes32) {
        lastRefundRecipient = _refundRecipient;
        lastRequestedTxHash = keccak256(
            abi.encode(_contractL2, _l2Value, _calldata, _l2GasLimit, _l2GasPerPubdataByte, msg.value, _refundRecipient)
        );
        return lastRequestedTxHash;
    }

    function proveL1ToL2TransactionStatus(
        bytes32 _l2TxHash,
        uint256, /*_l2BatchNumber*/
        uint256, /*_l2MessageIndex*/
        uint16, /*_l2TxNumberInBatch*/
        bytes32[] calldata, /*_merkleProof*/
        TxStatus _status
    ) external view returns (bool) {
        if (_status == TxStatus.Failure) {
            return l1ToL2Failed[_l2TxHash];
        }
        return false;
    }

    function proveL2MessageInclusion(
        uint256 _batchNumber,
        uint256 _index,
        L2Message calldata, /*_message*/
        bytes32[] calldata /*_proof*/
    ) external view returns (bool) {
        return l2InclusionOk[_batchNumber][_index];
    }

    function l2TransactionBaseCost(uint256, uint256, uint256) external view returns (uint256) {
        return baseCostReturn;
    }
}

contract L1BridgeTest is Test {
    // Actors
    address internal ADMIN = address(0xA11CE);
    address internal USER = address(0xBEEF);
    address internal OTHER = address(0xCAFE);

    // Deployed contracts
    MockMailbox internal mailbox;
    L1Nodl internal token;
    L1Bridge internal bridge;

    // Config
    address internal constant L2_BRIDGE_ADDR = address(0x1234);

    function setUp() public {
        mailbox = new MockMailbox();
        token = new L1Nodl(ADMIN, ADMIN);
        bridge = new L1Bridge(ADMIN, address(mailbox), address(token), L2_BRIDGE_ADDR);

        vm.startPrank(ADMIN);
        bytes32 minterRole = keccak256("MINTER_ROLE");
        token.grantRole(minterRole, address(bridge));
        token.mint(USER, 1_000_000 ether);
        vm.stopPrank();
    }

    function test_Deposit_HappyPath() public {
        uint256 amount = 100 ether;
        address l2Receiver = address(0x7777);
        uint256 gasLimit = 1_000_000;
        uint256 gasPerPubdata = 800;
        address refundRecipient = address(0x9999);

        vm.startPrank(USER);
        token.approve(address(bridge), amount);

        vm.expectEmit(false, true, true, true);
        emit IL1Bridge.DepositInitiated(bytes32(0), USER, l2Receiver, amount);

        bytes32 txHash = bridge.deposit(l2Receiver, amount, gasLimit, gasPerPubdata, refundRecipient);
        vm.stopPrank();

        assertEq(bridge.depositAmount(USER, txHash), amount, "deposit amount recorded");
        assertEq(token.balanceOf(USER), 1_000_000 ether - amount, "user burned amount");
        assertEq(mailbox.lastRefundRecipient(), refundRecipient, "refund recipient passed to mailbox");
    }

    function test_Deposit_Overload_DefaultRefundRecipient() public {
        uint256 amount = 100 ether;
        address l2Receiver = address(0x7777);
        uint256 gasLimit = 1_000_000;
        uint256 gasPerPubdata = 800;

        vm.startPrank(USER);
        token.approve(address(bridge), amount);

        vm.expectEmit(false, true, true, true);
        emit IL1Bridge.DepositInitiated(bytes32(0), USER, l2Receiver, amount);

        bytes32 txHash = bridge.deposit(l2Receiver, amount, gasLimit, gasPerPubdata);
        vm.stopPrank();

        assertEq(bridge.depositAmount(USER, txHash), amount, "deposit amount recorded");
        assertEq(token.balanceOf(USER), 1_000_000 ether - amount, "user burned amount");
        assertEq(mailbox.lastRefundRecipient(), USER, "refund recipient is user");
    }

    function test_Deposit_RefundRecipientZero_DefaultsToUser() public {
        uint256 amount = 77 ether;
        address l2Receiver = address(0x7777);
        uint256 gasLimit = 123_456;
        uint256 gasPerPubdata = 900;

        vm.startPrank(USER);
        token.approve(address(bridge), amount);
        bytes32 txHash = bridge.deposit(l2Receiver, amount, gasLimit, gasPerPubdata, address(0));
        vm.stopPrank();

        assertEq(bridge.depositAmount(USER, txHash), amount, "deposit amount recorded");
        assertEq(mailbox.lastRefundRecipient(), USER, "refund recipient defaults to sender");
    }

    function test_Deposit_Revert_ZeroAmount() public {
        vm.prank(USER);
        vm.expectRevert(abi.encodeWithSelector(L1Bridge.ZeroAmount.selector));
        bridge.deposit(address(0x1), 0, 100, 1000, USER);
    }

    function test_Deposit_Revert_L2ReceiverZero() public {
        vm.startPrank(USER);
        token.approve(address(bridge), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(L1Bridge.ZeroAddress.selector));
        bridge.deposit(address(0), 1 ether, 100, 1000, USER);
        vm.stopPrank();
    }

    function test_Deposit_Revert_InsufficientBalance() public {
        address l2Receiver = address(0x7777);
        uint256 gasLimit = 1_000_000;
        uint256 gasPerPubdata = 800;
        address refundRecipient = address(0x9999);

        uint256 amount = token.balanceOf(USER) + 1;
        vm.startPrank(USER);
        token.approve(address(bridge), amount);

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, USER, amount - 1, amount)
        );
        bridge.deposit(l2Receiver, amount, gasLimit, gasPerPubdata, refundRecipient);
        vm.stopPrank();
    }

    function test_ClaimFailedDeposit_HappyPath() public {
        uint256 amount = 100 ether;
        address l2Receiver = address(0x7777);
        uint256 gasLimit = 1_000_000;
        uint256 gasPerPubdata = 800;

        vm.startPrank(USER);
        token.approve(address(bridge), amount);

        vm.expectEmit(false, true, true, true);
        emit IL1Bridge.DepositInitiated(bytes32(0), USER, l2Receiver, amount);

        bytes32 txHash = bridge.deposit(l2Receiver, amount, gasLimit, gasPerPubdata);
        assertEq(token.balanceOf(USER), 1_000_000 ether - amount, "user burned amount");

        mailbox.setL1ToL2Failed(txHash, true);

        vm.expectEmit(true, true, true, true);
        emit IL1Bridge.ClaimedFailedDeposit(USER, amount);

        bridge.claimFailedDeposit(USER, txHash, 1, 0, 0, new bytes32[](0));
        vm.stopPrank();

        assertEq(token.balanceOf(USER), 1_000_000 ether, "user recovered amount");
    }

    function test_ClaimFailedDeposit_Revert_DoubleClaim() public {
        uint256 amount = 10 ether;
        vm.startPrank(USER);
        token.approve(address(bridge), amount);
        bytes32 txHash = bridge.deposit(address(0xABCD), amount, 50_000, 800);
        mailbox.setL1ToL2Failed(txHash, true);
        bridge.claimFailedDeposit(USER, txHash, 1, 0, 0, new bytes32[](0));
        vm.expectRevert(abi.encodeWithSelector(L1Bridge.UnknownTxHash.selector));
        bridge.claimFailedDeposit(USER, txHash, 1, 0, 0, new bytes32[](0));
        vm.stopPrank();
    }

    function test_ClaimFailedDeposit_Revert_UnknownTxHash() public {
        vm.expectRevert(abi.encodeWithSelector(L1Bridge.UnknownTxHash.selector));
        bridge.claimFailedDeposit(USER, bytes32(uint256(123)), 1, 0, 0, new bytes32[](0));
    }

    function test_ClaimFailedDeposit_Revert_ProofFailed() public {
        uint256 amount = 100 ether;
        address l2Receiver = address(0x7777);
        uint256 gasLimit = 1_000_000;
        uint256 gasPerPubdata = 800;

        vm.startPrank(USER);
        token.approve(address(bridge), amount);

        vm.expectEmit(false, true, true, true);
        emit IL1Bridge.DepositInitiated(bytes32(0), USER, l2Receiver, amount);

        bytes32 txHash = bridge.deposit(l2Receiver, amount, gasLimit, gasPerPubdata);
        assertEq(token.balanceOf(USER), 1_000_000 ether - amount, "user burned amount");

        vm.expectRevert(abi.encodeWithSelector(L1Bridge.L2FailureProofFailed.selector));
        bridge.claimFailedDeposit(USER, txHash, 1, 0, 0, new bytes32[](0));
        vm.stopPrank();
    }

    function test_FinalizeWithdrawal_HappyPath() public {
        uint256 batch = 10;
        uint256 idx = 2;
        uint16 txNum = 7;
        address receiver = OTHER;
        uint256 amount = 123 ether;

        mailbox.setInclusion(batch, idx, true);
        bytes memory msgBytes = abi.encodePacked(IWithdrawalMessage.finalizeWithdrawal.selector, receiver, amount);

        L2Message memory expected = L2Message({txNumberInBatch: txNum, sender: L2_BRIDGE_ADDR, data: msgBytes});
        vm.expectCall(
            address(mailbox),
            abi.encodeWithSelector(IMailbox.proveL2MessageInclusion.selector, batch, idx, expected, new bytes32[](0))
        );
        vm.expectEmit(true, true, true, true);
        emit IL1Bridge.WithdrawalFinalized(receiver, batch, idx, txNum, amount);
        bridge.finalizeWithdrawal(batch, idx, txNum, msgBytes, new bytes32[](0));
        assertEq(token.balanceOf(receiver), amount, "minted to receiver");
    }

    function test_FinalizeWithdrawal_Revert_DoubleFinalize() public {
        uint256 batch = 1;
        uint256 idx = 0;
        uint16 txNum = 1;
        address receiver = OTHER;
        uint256 amount = 1 ether;
        mailbox.setInclusion(batch, idx, true);
        bytes memory msgBytes = abi.encodePacked(IWithdrawalMessage.finalizeWithdrawal.selector, receiver, amount);
        bridge.finalizeWithdrawal(batch, idx, txNum, msgBytes, new bytes32[](0));

        vm.expectRevert(abi.encodeWithSelector(L1Bridge.WithdrawalAlreadyFinalized.selector));
        bridge.finalizeWithdrawal(batch, idx, txNum, msgBytes, new bytes32[](0));
    }

    function test_FinalizeWithdrawal_Revert_InvalidProof() public {
        uint256 batch = 2;
        uint256 idx = 3;
        uint16 txNum = 1;
        address receiver = OTHER;
        uint256 amount = 1 ether;
        bytes memory msgBytes = abi.encodePacked(IWithdrawalMessage.finalizeWithdrawal.selector, receiver, amount);
        vm.expectRevert(abi.encodeWithSelector(L1Bridge.InvalidProof.selector));
        bridge.finalizeWithdrawal(batch, idx, txNum, msgBytes, new bytes32[](0));
    }

    function test_FinalizeWithdrawal_RevertThenSuccess_DoesNotStickFlag() public {
        uint256 batch = 3;
        uint256 idx = 1;
        uint16 txNum = 9;
        address receiver = OTHER;
        uint256 amount = 5 ether;

        bytes memory msgBytes = abi.encodePacked(IWithdrawalMessage.finalizeWithdrawal.selector, receiver, amount);
        vm.expectRevert(abi.encodeWithSelector(L1Bridge.InvalidProof.selector));
        bridge.finalizeWithdrawal(batch, idx, txNum, msgBytes, new bytes32[](0));
        assertFalse(bridge.isWithdrawalFinalized(batch, idx), "flag should not be set on revert");

        mailbox.setInclusion(batch, idx, true);
        bridge.finalizeWithdrawal(batch, idx, txNum, msgBytes, new bytes32[](0));
        assertTrue(bridge.isWithdrawalFinalized(batch, idx), "now finalized");
    }

    function test_FinalizeWithdrawal_Revert_WrongLength() public {
        // 55 bytes (too short)
        bytes memory bad = new bytes(55);
        vm.expectRevert(abi.encodeWithSelector(L1Bridge.L2WithdrawalMessageWrongLength.selector, 55));
        bridge.finalizeWithdrawal(1, 1, 1, bad, new bytes32[](0));
    }

    function test_FinalizeWithdrawal_Revert_WrongSelector() public {
        // same length 56 but wrong selector
        bytes memory bad = abi.encodePacked(bytes4(0xDEADBEEF), OTHER, uint256(1));
        vm.expectRevert(abi.encodeWithSelector(L1Bridge.InvalidSelector.selector, bytes4(0xDEADBEEF)));
        bridge.finalizeWithdrawal(1, 1, 1, bad, new bytes32[](0));
    }

    function test_QuoteL2BaseCost_UsesTxGasPrice() public {
        uint256 gasLimit = 500_000;
        uint256 gasPerPubdata = 800;
        uint256 quotedValue = 123;
        vm.txGasPrice(42 gwei);

        bytes memory callData =
            abi.encodeWithSelector(IMailbox.l2TransactionBaseCost.selector, uint256(42 gwei), gasLimit, gasPerPubdata);
        mailbox.setBaseCostReturn(quotedValue);
        vm.expectCall(address(mailbox), callData);

        uint256 quote = bridge.quoteL2BaseCost(gasLimit, gasPerPubdata);

        assertEq(quote, quotedValue, "returns quoted base cost from mailbox");
    }

    function test_QuoteL2BaseCostAtGasPrice() public {
        uint256 gasLimit = 250_000;
        uint256 gasPerPubdata = 900;
        uint256 gasPrice = 15 gwei;
        uint256 quotedValue = 456;
        bytes memory callData =
            abi.encodeWithSelector(IMailbox.l2TransactionBaseCost.selector, gasPrice, gasLimit, gasPerPubdata);
        mailbox.setBaseCostReturn(quotedValue);
        vm.expectCall(address(mailbox), callData);
        uint256 quote = bridge.quoteL2BaseCostAtGasPrice(gasPrice, gasLimit, gasPerPubdata);

        assertEq(quote, quotedValue, "returns mailbox quote");
    }

    function test_Pause_Gates_Functions() public {
        vm.prank(ADMIN);
        bridge.pause();

        vm.startPrank(USER);
        token.approve(address(bridge), 1 ether);

        vm.expectRevert(Pausable.EnforcedPause.selector);
        bridge.deposit(address(0x5), 1 ether, 100, 1000);

        vm.expectRevert(Pausable.EnforcedPause.selector);
        bridge.claimFailedDeposit(USER, bytes32(uint256(1)), 1, 0, 0, new bytes32[](0));

        vm.expectRevert(Pausable.EnforcedPause.selector);
        bridge.finalizeWithdrawal(
            1,
            0,
            0,
            abi.encodePacked(IWithdrawalMessage.finalizeWithdrawal.selector, OTHER, uint256(1)),
            new bytes32[](0)
        );
    }

    function test_Unpause_Allows_Functions() public {
        vm.prank(ADMIN);
        bridge.pause();
        vm.prank(ADMIN);
        bridge.unpause();

        vm.prank(USER);
        token.approve(address(bridge), 1 ether);
        vm.prank(USER);
        bridge.deposit(address(0x6), 1 ether, 100, 1000);
    }

    function test_Pause_OnlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, USER));
        vm.prank(USER);
        bridge.pause();
    }

    function test_Unpause_OnlyOwner() public {
        vm.prank(ADMIN);
        bridge.pause();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, USER));
        vm.prank(USER);
        bridge.unpause();
    }

    function test_Constructor_Revert_ZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(L1Bridge.ZeroAddress.selector));
        new L1Bridge(ADMIN, address(0), address(token), L2_BRIDGE_ADDR);
    }
}
