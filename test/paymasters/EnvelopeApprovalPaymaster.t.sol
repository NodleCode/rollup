// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {AccessControlUtils} from "../__helpers__/AccessControlUtils.sol";
import {EnvelopeApprovalPaymaster} from "../../src/paymasters/EnvelopeApprovalPaymaster.sol";
import {BasePaymaster} from "../../src/paymasters/BasePaymaster.sol";
import {QuotaControl} from "../../src/QuotaControl.sol";
import {Transaction} from "lib/era-contracts/l2-contracts/contracts/L2ContractHelper.sol";
import {IPaymasterFlow} from "lib/era-contracts/l2-contracts/contracts/interfaces/IPaymasterFlow.sol";

/// @dev Bootloader address — paymaster validation must be called from this address.
address constant BOOTLOADER = address(uint160(0x8001));

contract EnvelopeApprovalPaymasterTest is Test {
    using AccessControlUtils for Vm;

    EnvelopeApprovalPaymaster paymaster;

    address admin = address(0xA1);
    address withdrawer = address(0xA2);
    address envelope = address(0xBEEF);
    address sponsoredToken = address(0xCAFE);

    uint256 operatorPk = uint256(keccak256("operator-signer"));
    address operator;

    uint256 userPk = uint256(keccak256("test-user"));
    address user;

    uint256 constant MAX_ETH_PER_TX = 0.005 ether;
    uint256 constant QUOTA = 1 ether;
    uint256 constant PERIOD = 1 days;

    function setUp() public {
        operator = vm.addr(operatorPk);
        user = vm.addr(userPk);

        paymaster = new EnvelopeApprovalPaymaster(
            admin, withdrawer, operator, envelope, MAX_ETH_PER_TX, QUOTA, PERIOD
        );
        vm.deal(address(paymaster), 10 ether);
    }

    // ── helpers ────────────────────────────────────────────────────────────

    function _signGrant(uint256 deadline, bytes32 nonce, address grantedUser, uint256 signerPk)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash =
            keccak256(abi.encode(paymaster.GRANT_TYPEHASH(), grantedUser, deadline, nonce));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", paymaster.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _buildPaymasterInput(uint256 deadline, bytes32 nonce, bytes memory signature)
        internal
        pure
        returns (bytes memory)
    {
        bytes memory inner = abi.encode(deadline, nonce, signature);
        return abi.encodeWithSelector(IPaymasterFlow.general.selector, inner);
    }

    function _approveCall(address spender, uint256 amount) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(0x095ea7b3, spender, amount);
    }

    function _setApprovalForAllCall(address operator_, bool approved) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(0xa22cb465, operator_, approved);
    }

    function _txTo(address to, bytes memory data, bytes memory paymasterInput, uint256 gasLimit, uint256 gasPrice)
        internal
        view
        returns (Transaction memory)
    {
        return Transaction({
            txType: 0x71, // EIP-712 zksync tx type
            from: uint256(uint160(user)),
            to: uint256(uint160(to)),
            gasLimit: gasLimit,
            gasPerPubdataByteLimit: 50000,
            maxFeePerGas: gasPrice,
            maxPriorityFeePerGas: 0,
            paymaster: uint256(uint160(address(paymaster))),
            nonce: 0,
            value: 0,
            reserved: [uint256(0), 0, 0, 0],
            data: data,
            signature: hex"",
            factoryDeps: new bytes32[](0),
            paymasterInput: paymasterInput,
            reservedDynamic: hex""
        });
    }

    function _validate(Transaction memory tx_) internal {
        vm.prank(BOOTLOADER);
        paymaster.validateAndPayForPaymasterTransaction(bytes32(0), bytes32(0), tx_);
    }

    // ── Happy paths ────────────────────────────────────────────────────────

    function test_sponsorsApprove() public {
        bytes32 nonce = keccak256("nonce-1");
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signGrant(deadline, nonce, user, operatorPk);
        bytes memory pmInput = _buildPaymasterInput(deadline, nonce, sig);
        bytes memory data = _approveCall(envelope, 1000);

        uint256 gasLimit = 100_000;
        uint256 gasPrice = 1 gwei;
        uint256 expectedPay = gasLimit * gasPrice;

        uint256 balBefore = address(paymaster).balance;
        uint256 bootBefore = BOOTLOADER.balance;
        _validate(_txTo(sponsoredToken, data, pmInput, gasLimit, gasPrice));

        assertEq(address(paymaster).balance, balBefore - expectedPay, "paymaster paid wrong amount");
        assertEq(BOOTLOADER.balance, bootBefore + expectedPay, "bootloader didn't receive");
        assertTrue(paymaster.isNonceUsed(nonce), "nonce not marked used");
        assertEq(paymaster.claimed(), expectedPay, "quota counter not bumped");
    }

    function test_sponsorsSetApprovalForAll() public {
        bytes32 nonce = keccak256("nonce-2");
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signGrant(deadline, nonce, user, operatorPk);
        bytes memory pmInput = _buildPaymasterInput(deadline, nonce, sig);
        bytes memory data = _setApprovalForAllCall(envelope, true);

        _validate(_txTo(sponsoredToken, data, pmInput, 100_000, 1 gwei));
        assertTrue(paymaster.isNonceUsed(nonce));
    }

    function test_sponsorsApproveOnAnyToken() public {
        // No token allowlist — operator's grant is the only auth.
        // Prove an arbitrary token address still gets sponsored.
        address randomToken = address(0xC0FFEE);
        bytes32 nonce = keccak256("nonce-random-token");
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signGrant(deadline, nonce, user, operatorPk);
        bytes memory pmInput = _buildPaymasterInput(deadline, nonce, sig);
        bytes memory data = _approveCall(envelope, 1);

        _validate(_txTo(randomToken, data, pmInput, 100_000, 1 gwei));
        assertTrue(paymaster.isNonceUsed(nonce));
    }

    // ── Reverts ────────────────────────────────────────────────────────────

    function test_revertsIfNotBootloader() public {
        bytes32 nonce = keccak256("n");
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signGrant(deadline, nonce, user, operatorPk);
        bytes memory pmInput = _buildPaymasterInput(deadline, nonce, sig);
        Transaction memory tx_ = _txTo(sponsoredToken, _approveCall(envelope, 1), pmInput, 100_000, 1 gwei);

        vm.expectRevert(BasePaymaster.AccessRestrictedToBootloader.selector);
        paymaster.validateAndPayForPaymasterTransaction(bytes32(0), bytes32(0), tx_);
    }

    function test_revertsOnApprovalBasedFlow() public {
        bytes memory wrongFlowInput = abi.encodeWithSelector(
            IPaymasterFlow.approvalBased.selector, address(0), uint256(0), bytes("")
        );
        Transaction memory tx_ = _txTo(sponsoredToken, _approveCall(envelope, 1), wrongFlowInput, 100_000, 1 gwei);

        vm.prank(BOOTLOADER);
        vm.expectRevert(EnvelopeApprovalPaymaster.WrongFlow.selector);
        paymaster.validateAndPayForPaymasterTransaction(bytes32(0), bytes32(0), tx_);
    }

    function test_revertsOnExpiredGrant() public {
        bytes32 nonce = keccak256("expired");
        uint256 deadline = block.timestamp + 100;
        bytes memory sig = _signGrant(deadline, nonce, user, operatorPk);
        bytes memory pmInput = _buildPaymasterInput(deadline, nonce, sig);

        vm.warp(deadline + 1);
        Transaction memory tx_ = _txTo(sponsoredToken, _approveCall(envelope, 1), pmInput, 100_000, 1 gwei);

        vm.prank(BOOTLOADER);
        vm.expectRevert(EnvelopeApprovalPaymaster.GrantExpired.selector);
        paymaster.validateAndPayForPaymasterTransaction(bytes32(0), bytes32(0), tx_);
    }

    function test_revertsOnReusedNonce() public {
        bytes32 nonce = keccak256("nonce-replay");
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signGrant(deadline, nonce, user, operatorPk);
        bytes memory pmInput = _buildPaymasterInput(deadline, nonce, sig);

        _validate(_txTo(sponsoredToken, _approveCall(envelope, 1), pmInput, 100_000, 1 gwei));

        vm.prank(BOOTLOADER);
        vm.expectRevert(EnvelopeApprovalPaymaster.NonceAlreadyUsed.selector);
        paymaster.validateAndPayForPaymasterTransaction(
            bytes32(0), bytes32(0),
            _txTo(sponsoredToken, _approveCall(envelope, 1), pmInput, 100_000, 1 gwei)
        );
    }

    function test_revertsOnSignatureFromWrongSigner() public {
        uint256 attackerPk = uint256(keccak256("attacker"));
        bytes32 nonce = keccak256("nonce-attacker");
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signGrant(deadline, nonce, user, attackerPk);
        bytes memory pmInput = _buildPaymasterInput(deadline, nonce, sig);

        vm.prank(BOOTLOADER);
        vm.expectRevert(EnvelopeApprovalPaymaster.InvalidGrantSignature.selector);
        paymaster.validateAndPayForPaymasterTransaction(
            bytes32(0), bytes32(0),
            _txTo(sponsoredToken, _approveCall(envelope, 1), pmInput, 100_000, 1 gwei)
        );
    }

    function test_revertsOnSignatureForDifferentUser() public {
        address charlie = address(0xC);
        bytes32 nonce = keccak256("nonce-other-user");
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signGrant(deadline, nonce, charlie, operatorPk); // signed for charlie
        bytes memory pmInput = _buildPaymasterInput(deadline, nonce, sig);

        // tx.from = user (different from charlie)
        vm.prank(BOOTLOADER);
        vm.expectRevert(EnvelopeApprovalPaymaster.InvalidGrantSignature.selector);
        paymaster.validateAndPayForPaymasterTransaction(
            bytes32(0), bytes32(0),
            _txTo(sponsoredToken, _approveCall(envelope, 1), pmInput, 100_000, 1 gwei)
        );
    }

    function test_revertsOnUnsupportedSelector() public {
        bytes32 nonce = keccak256("nonce-sel");
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signGrant(deadline, nonce, user, operatorPk);
        bytes memory pmInput = _buildPaymasterInput(deadline, nonce, sig);
        // transfer(address,uint256) instead of approve
        bytes memory data = abi.encodeWithSelector(0xa9059cbb, envelope, uint256(1));

        vm.prank(BOOTLOADER);
        vm.expectRevert(EnvelopeApprovalPaymaster.UnsupportedSelector.selector);
        paymaster.validateAndPayForPaymasterTransaction(
            bytes32(0), bytes32(0),
            _txTo(sponsoredToken, data, pmInput, 100_000, 1 gwei)
        );
    }

    function test_revertsOnSpenderNotEnvelope() public {
        bytes32 nonce = keccak256("nonce-spender");
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signGrant(deadline, nonce, user, operatorPk);
        bytes memory pmInput = _buildPaymasterInput(deadline, nonce, sig);
        // Approve attacker instead of envelope
        bytes memory data = _approveCall(address(0xBAD), 1000);

        vm.prank(BOOTLOADER);
        vm.expectRevert(EnvelopeApprovalPaymaster.SpenderNotEnvelope.selector);
        paymaster.validateAndPayForPaymasterTransaction(
            bytes32(0), bytes32(0),
            _txTo(sponsoredToken, data, pmInput, 100_000, 1 gwei)
        );
    }

    function test_revertsOnPerTxLimitExceeded() public {
        bytes32 nonce = keccak256("nonce-per-tx");
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signGrant(deadline, nonce, user, operatorPk);
        bytes memory pmInput = _buildPaymasterInput(deadline, nonce, sig);

        // gasLimit * gasPrice > MAX_ETH_PER_TX (0.005 ether)
        // Use gasPrice = 1 gwei, gasLimit large enough to exceed 5_000_000 gwei
        uint256 gasPrice = 1 gwei;
        uint256 gasLimit = (MAX_ETH_PER_TX / gasPrice) + 1;

        vm.prank(BOOTLOADER);
        vm.expectRevert(EnvelopeApprovalPaymaster.PerTxLimitExceeded.selector);
        paymaster.validateAndPayForPaymasterTransaction(
            bytes32(0), bytes32(0),
            _txTo(sponsoredToken, _approveCall(envelope, 1), pmInput, gasLimit, gasPrice)
        );
    }

    function test_revertsOnExceededQuota() public {
        // Use a dedicated paymaster with a tight quota = 2 * per-tx-cap so two max-cost
        // sponsored txs fill it exactly; the third hits QuotaExceeded.
        EnvelopeApprovalPaymaster tight = new EnvelopeApprovalPaymaster(
            admin, withdrawer, operator, envelope,
            MAX_ETH_PER_TX, MAX_ETH_PER_TX * 2, PERIOD
        );
        vm.deal(address(tight), 10 ether);

        uint256 gasPrice = 1 gwei;
        uint256 gasLimit = MAX_ETH_PER_TX / gasPrice; // exactly per-tx cap

        // tx 1 — fills half the quota
        bytes32 n1 = keccak256("nq1");
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 typehash = tight.GRANT_TYPEHASH();
        bytes32 domain = tight.DOMAIN_SEPARATOR();
        bytes memory sig1 = _signTightGrant(typehash, domain, deadline, n1, user, operatorPk);
        vm.prank(BOOTLOADER);
        tight.validateAndPayForPaymasterTransaction(
            bytes32(0), bytes32(0),
            _txTo(sponsoredToken, _approveCall(envelope, 1),
                  _buildPaymasterInput(deadline, n1, sig1), gasLimit, gasPrice)
        );

        // tx 2 — fills the other half
        bytes32 n2 = keccak256("nq2");
        bytes memory sig2 = _signTightGrant(typehash, domain, deadline, n2, user, operatorPk);
        vm.prank(BOOTLOADER);
        tight.validateAndPayForPaymasterTransaction(
            bytes32(0), bytes32(0),
            _txTo(sponsoredToken, _approveCall(envelope, 1),
                  _buildPaymasterInput(deadline, n2, sig2), gasLimit, gasPrice)
        );

        // tx 3 — over quota
        bytes32 n3 = keccak256("nq3");
        bytes memory sig3 = _signTightGrant(typehash, domain, deadline, n3, user, operatorPk);
        vm.prank(BOOTLOADER);
        vm.expectRevert(QuotaControl.QuotaExceeded.selector);
        tight.validateAndPayForPaymasterTransaction(
            bytes32(0), bytes32(0),
            _txTo(sponsoredToken, _approveCall(envelope, 1),
                  _buildPaymasterInput(deadline, n3, sig3), gasLimit, gasPrice)
        );
    }

    /// @dev Sign a grant against an arbitrary typehash+domain (for testing alt-paymaster instances).
    function _signTightGrant(
        bytes32 typehash, bytes32 domain, uint256 deadline, bytes32 nonce, address grantedUser, uint256 signerPk
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(abi.encode(typehash, grantedUser, deadline, nonce));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domain, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        return abi.encodePacked(r, s, v);
    }

    function test_revertsOnInsufficientBalance() public {
        // Drain the paymaster balance
        vm.prank(withdrawer);
        paymaster.withdraw(address(0x1), address(paymaster).balance);

        bytes32 nonce = keccak256("nonce-bal");
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signGrant(deadline, nonce, user, operatorPk);
        bytes memory pmInput = _buildPaymasterInput(deadline, nonce, sig);

        vm.prank(BOOTLOADER);
        vm.expectRevert(EnvelopeApprovalPaymaster.InsufficientPaymasterBalance.selector);
        paymaster.validateAndPayForPaymasterTransaction(
            bytes32(0), bytes32(0),
            _txTo(sponsoredToken, _approveCall(envelope, 1), pmInput, 100_000, 1 gwei)
        );
    }

    // ── Quota period rollover ──────────────────────────────────────────────

    function test_quotaResetsAfterPeriod() public {
        // Burn some quota
        bytes32 nonce1 = keccak256("nonce-r1");
        uint256 deadline = block.timestamp + 7 days;
        bytes memory sig1 = _signGrant(deadline, nonce1, user, operatorPk);
        bytes memory pmInput1 = _buildPaymasterInput(deadline, nonce1, sig1);
        _validate(_txTo(sponsoredToken, _approveCall(envelope, 1), pmInput1, 100_000, 1 gwei));
        uint256 claimed1 = paymaster.claimed();
        assertGt(claimed1, 0);

        // Roll past the period
        vm.warp(block.timestamp + PERIOD + 1);

        bytes32 nonce2 = keccak256("nonce-r2");
        bytes memory sig2 = _signGrant(deadline, nonce2, user, operatorPk);
        bytes memory pmInput2 = _buildPaymasterInput(deadline, nonce2, sig2);
        _validate(_txTo(sponsoredToken, _approveCall(envelope, 1), pmInput2, 100_000, 1 gwei));

        // Claimed should reset to just this tx's cost (not cumulative)
        assertEq(paymaster.claimed(), 100_000 * 1 gwei);
    }

    // ── Admin ──────────────────────────────────────────────────────────────

    function test_adminCanRotateOperatorSigner() public {
        address newSigner = address(0x99);
        vm.prank(admin);
        paymaster.setOperatorSigner(newSigner);
        assertEq(paymaster.operatorSigner(), newSigner);
    }

    function test_nonAdminCannotRotateOperatorSigner() public {
        vm.expectRevert();
        paymaster.setOperatorSigner(address(0x99));
    }

    function test_withdrawerCanDrainBalance() public {
        uint256 amount = 1 ether;
        address recipient = address(0x77);
        uint256 before = recipient.balance;

        vm.prank(withdrawer);
        paymaster.withdraw(recipient, amount);
        assertEq(recipient.balance, before + amount);
    }

    function test_nonWithdrawerCannotDrain() public {
        vm.expectRevert();
        paymaster.withdraw(address(0x77), 1);
    }
}
