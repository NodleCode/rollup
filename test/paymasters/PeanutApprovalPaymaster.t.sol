// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {AccessControlUtils} from "../__helpers__/AccessControlUtils.sol";
import {PeanutApprovalPaymaster} from "../../src/paymasters/PeanutApprovalPaymaster.sol";
import {QuotaControl} from "../../src/QuotaControl.sol";
import {Transaction} from "lib/era-contracts/l2-contracts/contracts/L2ContractHelper.sol";
import {IPaymasterFlow} from "lib/era-contracts/l2-contracts/contracts/interfaces/IPaymasterFlow.sol";
import {PAYMASTER_VALIDATION_SUCCESS_MAGIC} from "lib/era-contracts/l2-contracts/contracts/interfaces/IPaymaster.sol";

/// @dev Bootloader address — paymaster validation must be called from this address.
address constant BOOTLOADER = address(uint160(0x8001));

contract PeanutApprovalPaymasterTest is Test {
    using AccessControlUtils for Vm;

    PeanutApprovalPaymaster paymaster;

    address admin = address(0xA1);
    address withdrawer = address(0xA2);
    address peanut = address(0xBEEF);
    address allowedToken = address(0xCAFE);
    address blockedToken = address(0xDEAD);

    uint256 operatorPk = uint256(keccak256("operator-signer"));
    address operator;

    uint256 userPk = uint256(keccak256("test-user"));
    address user;

    uint256 constant QUOTA = 1 ether;
    uint256 constant PERIOD = 1 days;

    function setUp() public {
        operator = vm.addr(operatorPk);
        user = vm.addr(userPk);

        paymaster = new PeanutApprovalPaymaster(admin, withdrawer, operator, peanut, QUOTA, PERIOD);
        vm.deal(address(paymaster), 10 ether);

        // Allowlist the test token.
        address[] memory tokens = new address[](1);
        tokens[0] = allowedToken;
        vm.prank(admin);
        paymaster.addAllowedTokens(tokens);
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
        bytes memory data = _approveCall(peanut, 1000);

        uint256 gasLimit = 100_000;
        uint256 gasPrice = 1 gwei;
        uint256 expectedPay = gasLimit * gasPrice;

        uint256 balBefore = address(paymaster).balance;
        uint256 bootBefore = BOOTLOADER.balance;
        _validate(_txTo(allowedToken, data, pmInput, gasLimit, gasPrice));

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
        bytes memory data = _setApprovalForAllCall(peanut, true);

        _validate(_txTo(allowedToken, data, pmInput, 100_000, 1 gwei));
        assertTrue(paymaster.isNonceUsed(nonce));
    }

    // ── Reverts ────────────────────────────────────────────────────────────

    function test_revertsIfNotBootloader() public {
        bytes32 nonce = keccak256("n");
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signGrant(deadline, nonce, user, operatorPk);
        bytes memory pmInput = _buildPaymasterInput(deadline, nonce, sig);
        Transaction memory tx_ = _txTo(allowedToken, _approveCall(peanut, 1), pmInput, 100_000, 1 gwei);

        vm.expectRevert(PeanutApprovalPaymaster.OnlyBootloader.selector);
        paymaster.validateAndPayForPaymasterTransaction(bytes32(0), bytes32(0), tx_);
    }

    function test_revertsOnApprovalBasedFlow() public {
        bytes memory wrongFlowInput = abi.encodeWithSelector(
            IPaymasterFlow.approvalBased.selector, address(0), uint256(0), bytes("")
        );
        Transaction memory tx_ = _txTo(allowedToken, _approveCall(peanut, 1), wrongFlowInput, 100_000, 1 gwei);

        vm.prank(BOOTLOADER);
        vm.expectRevert(PeanutApprovalPaymaster.WrongFlow.selector);
        paymaster.validateAndPayForPaymasterTransaction(bytes32(0), bytes32(0), tx_);
    }

    function test_revertsOnExpiredGrant() public {
        bytes32 nonce = keccak256("expired");
        uint256 deadline = block.timestamp + 100;
        bytes memory sig = _signGrant(deadline, nonce, user, operatorPk);
        bytes memory pmInput = _buildPaymasterInput(deadline, nonce, sig);

        vm.warp(deadline + 1);
        Transaction memory tx_ = _txTo(allowedToken, _approveCall(peanut, 1), pmInput, 100_000, 1 gwei);

        vm.prank(BOOTLOADER);
        vm.expectRevert(PeanutApprovalPaymaster.GrantExpired.selector);
        paymaster.validateAndPayForPaymasterTransaction(bytes32(0), bytes32(0), tx_);
    }

    function test_revertsOnReusedNonce() public {
        bytes32 nonce = keccak256("nonce-replay");
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signGrant(deadline, nonce, user, operatorPk);
        bytes memory pmInput = _buildPaymasterInput(deadline, nonce, sig);

        _validate(_txTo(allowedToken, _approveCall(peanut, 1), pmInput, 100_000, 1 gwei));

        vm.prank(BOOTLOADER);
        vm.expectRevert(PeanutApprovalPaymaster.NonceAlreadyUsed.selector);
        paymaster.validateAndPayForPaymasterTransaction(
            bytes32(0), bytes32(0),
            _txTo(allowedToken, _approveCall(peanut, 1), pmInput, 100_000, 1 gwei)
        );
    }

    function test_revertsOnSignatureFromWrongSigner() public {
        uint256 attackerPk = uint256(keccak256("attacker"));
        bytes32 nonce = keccak256("nonce-attacker");
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signGrant(deadline, nonce, user, attackerPk);
        bytes memory pmInput = _buildPaymasterInput(deadline, nonce, sig);

        vm.prank(BOOTLOADER);
        vm.expectRevert(PeanutApprovalPaymaster.InvalidGrantSignature.selector);
        paymaster.validateAndPayForPaymasterTransaction(
            bytes32(0), bytes32(0),
            _txTo(allowedToken, _approveCall(peanut, 1), pmInput, 100_000, 1 gwei)
        );
    }

    function test_revertsOnSignatureForDifferentUser() public {
        // Operator signs grant for charlie; but tx.from = user. Recovered signer
        // matches operator, BUT the structHash uses tx.from's user address, not the
        // address baked into the sig. So the sig recovers to wrong signer and reverts.
        address charlie = address(0xC);
        bytes32 nonce = keccak256("nonce-other-user");
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signGrant(deadline, nonce, charlie, operatorPk); // signed for charlie
        bytes memory pmInput = _buildPaymasterInput(deadline, nonce, sig);

        // tx.from = user (different from charlie)
        vm.prank(BOOTLOADER);
        vm.expectRevert(PeanutApprovalPaymaster.InvalidGrantSignature.selector);
        paymaster.validateAndPayForPaymasterTransaction(
            bytes32(0), bytes32(0),
            _txTo(allowedToken, _approveCall(peanut, 1), pmInput, 100_000, 1 gwei)
        );
    }

    function test_revertsOnDisallowedToken() public {
        bytes32 nonce = keccak256("nonce-token");
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signGrant(deadline, nonce, user, operatorPk);
        bytes memory pmInput = _buildPaymasterInput(deadline, nonce, sig);

        vm.prank(BOOTLOADER);
        vm.expectRevert(PeanutApprovalPaymaster.TokenNotAllowed.selector);
        paymaster.validateAndPayForPaymasterTransaction(
            bytes32(0), bytes32(0),
            _txTo(blockedToken, _approveCall(peanut, 1), pmInput, 100_000, 1 gwei)
        );
    }

    function test_revertsOnUnsupportedSelector() public {
        bytes32 nonce = keccak256("nonce-sel");
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signGrant(deadline, nonce, user, operatorPk);
        bytes memory pmInput = _buildPaymasterInput(deadline, nonce, sig);
        // transfer(address,uint256) instead of approve
        bytes memory data = abi.encodeWithSelector(0xa9059cbb, peanut, uint256(1));

        vm.prank(BOOTLOADER);
        vm.expectRevert(PeanutApprovalPaymaster.UnsupportedSelector.selector);
        paymaster.validateAndPayForPaymasterTransaction(
            bytes32(0), bytes32(0),
            _txTo(allowedToken, data, pmInput, 100_000, 1 gwei)
        );
    }

    function test_revertsOnSpenderNotPeanut() public {
        bytes32 nonce = keccak256("nonce-spender");
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signGrant(deadline, nonce, user, operatorPk);
        bytes memory pmInput = _buildPaymasterInput(deadline, nonce, sig);
        // Approve attacker instead of peanut
        bytes memory data = _approveCall(address(0xBAD), 1000);

        vm.prank(BOOTLOADER);
        vm.expectRevert(PeanutApprovalPaymaster.SpenderNotPeanut.selector);
        paymaster.validateAndPayForPaymasterTransaction(
            bytes32(0), bytes32(0),
            _txTo(allowedToken, data, pmInput, 100_000, 1 gwei)
        );
    }

    function test_revertsOnExceededQuota() public {
        bytes32 nonce = keccak256("nonce-quota");
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signGrant(deadline, nonce, user, operatorPk);
        bytes memory pmInput = _buildPaymasterInput(deadline, nonce, sig);

        // gasLimit * gasPrice > QUOTA
        uint256 gasLimit = 2_000_000;
        uint256 gasPrice = 1 gwei; // 0.002 ether > 0.001? wait QUOTA is 1 ether — bump
        // Make it definitely exceed: gasLimit huge.
        gasLimit = uint256(QUOTA / gasPrice) + 1_000_000;

        vm.prank(BOOTLOADER);
        vm.expectRevert(QuotaControl.QuotaExceeded.selector);
        paymaster.validateAndPayForPaymasterTransaction(
            bytes32(0), bytes32(0),
            _txTo(allowedToken, _approveCall(peanut, 1), pmInput, gasLimit, gasPrice)
        );
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
        vm.expectRevert(PeanutApprovalPaymaster.InsufficientPaymasterBalance.selector);
        paymaster.validateAndPayForPaymasterTransaction(
            bytes32(0), bytes32(0),
            _txTo(allowedToken, _approveCall(peanut, 1), pmInput, 100_000, 1 gwei)
        );
    }

    // ── Quota period rollover ──────────────────────────────────────────────

    function test_quotaResetsAfterPeriod() public {
        // Burn some quota
        bytes32 nonce1 = keccak256("nonce-r1");
        uint256 deadline = block.timestamp + 7 days;
        bytes memory sig1 = _signGrant(deadline, nonce1, user, operatorPk);
        bytes memory pmInput1 = _buildPaymasterInput(deadline, nonce1, sig1);
        _validate(_txTo(allowedToken, _approveCall(peanut, 1), pmInput1, 100_000, 1 gwei));
        uint256 claimed1 = paymaster.claimed();
        assertGt(claimed1, 0);

        // Roll past the period
        vm.warp(block.timestamp + PERIOD + 1);

        bytes32 nonce2 = keccak256("nonce-r2");
        bytes memory sig2 = _signGrant(deadline, nonce2, user, operatorPk);
        bytes memory pmInput2 = _buildPaymasterInput(deadline, nonce2, sig2);
        _validate(_txTo(allowedToken, _approveCall(peanut, 1), pmInput2, 100_000, 1 gwei));

        // Claimed should reset to just this tx's cost (not cumulative)
        assertEq(paymaster.claimed(), 100_000 * 1 gwei);
    }

    // ── Admin ──────────────────────────────────────────────────────────────

    function test_adminCanAddAndRemoveTokens() public {
        address[] memory tokens = new address[](2);
        tokens[0] = address(0x111);
        tokens[1] = address(0x222);

        vm.prank(admin);
        paymaster.addAllowedTokens(tokens);
        assertTrue(paymaster.isAllowedToken(tokens[0]));
        assertTrue(paymaster.isAllowedToken(tokens[1]));

        vm.prank(admin);
        paymaster.removeAllowedTokens(tokens);
        assertFalse(paymaster.isAllowedToken(tokens[0]));
    }

    function test_nonAdminCannotAddTokens() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(0x111);

        vm.expectRevert();
        paymaster.addAllowedTokens(tokens);
    }

    function test_adminCanRotateOperatorSigner() public {
        address newSigner = address(0x99);
        vm.prank(admin);
        paymaster.setOperatorSigner(newSigner);
        assertEq(paymaster.operatorSigner(), newSigner);
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
