// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IPaymasterFlow} from "lib/era-contracts/l2-contracts/contracts/interfaces/IPaymasterFlow.sol";
import {Transaction} from "lib/era-contracts/l2-contracts/contracts/L2ContractHelper.sol";
import {PAYMASTER_VALIDATION_SUCCESS_MAGIC} from "lib/era-contracts/l2-contracts/contracts/interfaces/IPaymaster.sol";

import {AccessControlUtils} from "../__helpers__/AccessControlUtils.sol";
import {QuotaControl} from "../../src/QuotaControl.sol";
import {BasePaymaster, BOOTLOADER_FORMAL_ADDRESS} from "../../src/paymasters/BasePaymaster.sol";
import {ERC20FeePaymaster} from "../../src/paymasters/ERC20FeePaymaster.sol";

contract MockFeeToken is ERC20 {
    constructor() ERC20("Mock NODL", "mNODL") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract ERC20FeePaymasterTest is Test {
    using AccessControlUtils for Vm;

    ERC20FeePaymaster private paymaster;
    MockFeeToken private feeToken;

    address internal admin = address(0x1111);
    address internal withdrawer = address(0x2222);
    uint256 internal signerKey = 0xA11CE;
    address internal feeSigner;
    address internal user = address(0xA);
    address internal dest = address(0xB);
    address internal attacker = address(0xB33F);

    uint256 internal constant QUOTA = 10 ether;
    uint256 internal constant PERIOD = 1 days;
    uint256 internal constant GAS_LIMIT = 100_000;
    uint256 internal constant MAX_FEE = 1 gwei;
    uint256 internal constant FEE_AMOUNT = 5 ether;

    function setUp() public {
        feeSigner = vm.addr(signerKey);
        feeToken = new MockFeeToken();
        paymaster = new ERC20FeePaymaster(admin, withdrawer, address(feeToken), feeSigner, QUOTA, PERIOD);
        vm.deal(address(paymaster), 100 ether);

        feeToken.mint(user, 1_000 ether);
        vm.prank(user);
        feeToken.approve(address(paymaster), type(uint256).max);
    }

    function _buildApprovalInput(uint256 amount, uint64 expirationTime, bytes memory signature)
        internal
        view
        returns (bytes memory)
    {
        bytes memory inner = abi.encode(expirationTime, signature);
        return abi.encodeWithSelector(IPaymasterFlow.approvalBased.selector, address(feeToken), amount, inner);
    }

    function _buildTransaction(address from, address to, uint256 gasLimit, uint256 maxFeePerGas, bytes memory pmInput)
        internal
        pure
        returns (Transaction memory txn)
    {
        txn.from = uint256(uint160(from));
        txn.to = uint256(uint160(to));
        txn.gasLimit = gasLimit;
        txn.maxFeePerGas = maxFeePerGas;
        txn.paymasterInput = pmInput;
    }

    function _signFeeApproval(
        address from,
        address to,
        address token,
        uint256 amount,
        uint64 expirationTime,
        uint256 maxFeePerGas,
        uint256 gasLimit
    ) internal view returns (bytes memory) {
        bytes32 digest = paymaster.hashFeeApproval(from, to, token, amount, expirationTime, maxFeePerGas, gasLimit);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _validExpiration() internal view returns (uint64) {
        return uint64(block.timestamp + 5 minutes);
    }

    function test_defaultACLsAndImmutables() public view {
        assertTrue(paymaster.hasRole(paymaster.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(paymaster.hasRole(paymaster.WITHDRAWER_ROLE(), withdrawer));
        assertEq(address(paymaster.feeToken()), address(feeToken));
        assertEq(paymaster.feeSigner(), feeSigner);
        assertEq(paymaster.quota(), QUOTA);
        assertEq(paymaster.period(), PERIOD);
    }

    function test_setFeeSigner() public {
        address newSigner = address(0xC0FFEE);
        vm.prank(admin);
        vm.expectEmit(true, true, false, true);
        emit ERC20FeePaymaster.FeeSignerUpdated(feeSigner, newSigner);
        paymaster.setFeeSigner(newSigner);
        assertEq(paymaster.feeSigner(), newSigner);
    }

    function test_RevertIf_setFeeSignerUnauthorized() public {
        vm.expectRevert_AccessControlUnauthorizedAccount(attacker, paymaster.DEFAULT_ADMIN_ROLE());
        vm.prank(attacker);
        paymaster.setFeeSigner(attacker);
    }

    function test_RevertIf_setFeeSignerZero() public {
        vm.prank(admin);
        vm.expectRevert(ERC20FeePaymaster.ZeroAddress.selector);
        paymaster.setFeeSigner(address(0));
    }

    function test_validateAndPay_success() public {
        uint64 expiration = _validExpiration();
        bytes memory signature =
            _signFeeApproval(user, dest, address(feeToken), FEE_AMOUNT, expiration, MAX_FEE, GAS_LIMIT);
        bytes memory pmInput = _buildApprovalInput(FEE_AMOUNT, expiration, signature);
        Transaction memory txn = _buildTransaction(user, dest, GAS_LIMIT, MAX_FEE, pmInput);

        uint256 requiredETH = GAS_LIMIT * MAX_FEE;
        uint256 bootloaderBefore = BOOTLOADER_FORMAL_ADDRESS.balance;
        uint256 userTokenBefore = feeToken.balanceOf(user);
        uint256 paymasterTokenBefore = feeToken.balanceOf(address(paymaster));

        vm.prank(BOOTLOADER_FORMAL_ADDRESS);
        (bytes4 magic,) = paymaster.validateAndPayForPaymasterTransaction(bytes32(0), bytes32(0), txn);

        assertEq(magic, PAYMASTER_VALIDATION_SUCCESS_MAGIC);
        assertEq(BOOTLOADER_FORMAL_ADDRESS.balance, bootloaderBefore + requiredETH);
        assertEq(feeToken.balanceOf(user), userTokenBefore - FEE_AMOUNT);
        assertEq(feeToken.balanceOf(address(paymaster)), paymasterTokenBefore + FEE_AMOUNT);
        assertEq(paymaster.claimed(), requiredETH);
    }

    function test_validateAndPay_invalidSignatureReturnsZeroMagic() public {
        uint64 expiration = _validExpiration();
        // Sign with a different key
        bytes32 digest =
            paymaster.hashFeeApproval(user, dest, address(feeToken), FEE_AMOUNT, expiration, MAX_FEE, GAS_LIMIT);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xDEAD, digest);
        bytes memory badSig = abi.encodePacked(r, s, v);

        bytes memory pmInput = _buildApprovalInput(FEE_AMOUNT, expiration, badSig);
        Transaction memory txn = _buildTransaction(user, dest, GAS_LIMIT, MAX_FEE, pmInput);

        vm.prank(BOOTLOADER_FORMAL_ADDRESS);
        (bytes4 magic,) = paymaster.validateAndPayForPaymasterTransaction(bytes32(0), bytes32(0), txn);

        assertEq(magic, bytes4(0));
        // Economic path still runs so eth_estimateGas observes realistic costs.
        assertEq(paymaster.claimed(), GAS_LIMIT * MAX_FEE);
    }

    function test_RevertIf_wrongFeeToken() public {
        MockFeeToken other = new MockFeeToken();
        uint64 expiration = _validExpiration();
        bytes memory signature =
            _signFeeApproval(user, dest, address(other), FEE_AMOUNT, expiration, MAX_FEE, GAS_LIMIT);
        bytes memory inner = abi.encode(expiration, signature);
        bytes memory pmInput =
            abi.encodeWithSelector(IPaymasterFlow.approvalBased.selector, address(other), FEE_AMOUNT, inner);
        Transaction memory txn = _buildTransaction(user, dest, GAS_LIMIT, MAX_FEE, pmInput);

        vm.prank(BOOTLOADER_FORMAL_ADDRESS);
        vm.expectRevert(ERC20FeePaymaster.InvalidFeeToken.selector);
        paymaster.validateAndPayForPaymasterTransaction(bytes32(0), bytes32(0), txn);
    }

    function test_RevertIf_zeroFeeAmount() public {
        uint64 expiration = _validExpiration();
        bytes memory signature = _signFeeApproval(user, dest, address(feeToken), 0, expiration, MAX_FEE, GAS_LIMIT);
        bytes memory pmInput = _buildApprovalInput(0, expiration, signature);
        Transaction memory txn = _buildTransaction(user, dest, GAS_LIMIT, MAX_FEE, pmInput);

        vm.prank(BOOTLOADER_FORMAL_ADDRESS);
        vm.expectRevert(ERC20FeePaymaster.ZeroFeeAmount.selector);
        paymaster.validateAndPayForPaymasterTransaction(bytes32(0), bytes32(0), txn);
    }

    function test_RevertIf_approvalExpired() public {
        uint64 expiration = uint64(block.timestamp - 1);
        bytes memory signature =
            _signFeeApproval(user, dest, address(feeToken), FEE_AMOUNT, expiration, MAX_FEE, GAS_LIMIT);
        bytes memory pmInput = _buildApprovalInput(FEE_AMOUNT, expiration, signature);
        Transaction memory txn = _buildTransaction(user, dest, GAS_LIMIT, MAX_FEE, pmInput);

        vm.prank(BOOTLOADER_FORMAL_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(ERC20FeePaymaster.ApprovalExpired.selector, expiration));
        paymaster.validateAndPayForPaymasterTransaction(bytes32(0), bytes32(0), txn);
    }

    function test_RevertIf_approvalTtlTooLong() public {
        uint64 expiration = uint64(block.timestamp + paymaster.MAX_SIGNATURE_TTL() + 1);
        bytes memory signature =
            _signFeeApproval(user, dest, address(feeToken), FEE_AMOUNT, expiration, MAX_FEE, GAS_LIMIT);
        bytes memory pmInput = _buildApprovalInput(FEE_AMOUNT, expiration, signature);
        Transaction memory txn = _buildTransaction(user, dest, GAS_LIMIT, MAX_FEE, pmInput);

        vm.prank(BOOTLOADER_FORMAL_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(ERC20FeePaymaster.ApprovalTtlTooLong.selector, expiration));
        paymaster.validateAndPayForPaymasterTransaction(bytes32(0), bytes32(0), txn);
    }

    function test_RevertIf_allowanceTooLow() public {
        vm.prank(user);
        feeToken.approve(address(paymaster), FEE_AMOUNT - 1);

        uint64 expiration = _validExpiration();
        bytes memory signature =
            _signFeeApproval(user, dest, address(feeToken), FEE_AMOUNT, expiration, MAX_FEE, GAS_LIMIT);
        bytes memory pmInput = _buildApprovalInput(FEE_AMOUNT, expiration, signature);
        Transaction memory txn = _buildTransaction(user, dest, GAS_LIMIT, MAX_FEE, pmInput);

        vm.prank(BOOTLOADER_FORMAL_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(ERC20FeePaymaster.AllowanceTooLow.selector, FEE_AMOUNT - 1, FEE_AMOUNT));
        paymaster.validateAndPayForPaymasterTransaction(bytes32(0), bytes32(0), txn);
    }

    function test_RevertIf_quotaExceeded() public {
        // Drain almost all quota with one large gas payment
        uint256 gasLimit = QUOTA / MAX_FEE;
        uint256 feeAmount = 1 ether;
        uint64 expiration = _validExpiration();
        bytes memory signature =
            _signFeeApproval(user, dest, address(feeToken), feeAmount, expiration, MAX_FEE, gasLimit);
        bytes memory pmInput = _buildApprovalInput(feeAmount, expiration, signature);
        Transaction memory txn = _buildTransaction(user, dest, gasLimit, MAX_FEE, pmInput);

        vm.prank(BOOTLOADER_FORMAL_ADDRESS);
        paymaster.validateAndPayForPaymasterTransaction(bytes32(0), bytes32(0), txn);
        assertEq(paymaster.claimed(), QUOTA);

        // Any additional requiredETH exceeds quota
        uint256 smallGas = 1;
        signature = _signFeeApproval(user, dest, address(feeToken), feeAmount, expiration, MAX_FEE, smallGas);
        pmInput = _buildApprovalInput(feeAmount, expiration, signature);
        txn = _buildTransaction(user, dest, smallGas, MAX_FEE, pmInput);

        vm.prank(BOOTLOADER_FORMAL_ADDRESS);
        vm.expectRevert(QuotaControl.QuotaExceeded.selector);
        paymaster.validateAndPayForPaymasterTransaction(bytes32(0), bytes32(0), txn);
    }

    function test_RevertIf_generalFlow() public {
        bytes memory pmInput = abi.encodeWithSelector(IPaymasterFlow.general.selector, "");
        Transaction memory txn = _buildTransaction(user, dest, GAS_LIMIT, MAX_FEE, pmInput);

        vm.prank(BOOTLOADER_FORMAL_ADDRESS);
        vm.expectRevert(BasePaymaster.PaymasterFlowNotSupported.selector);
        paymaster.validateAndPayForPaymasterTransaction(bytes32(0), bytes32(0), txn);
    }

    function test_RevertIf_notBootloader() public {
        uint64 expiration = _validExpiration();
        bytes memory signature =
            _signFeeApproval(user, dest, address(feeToken), FEE_AMOUNT, expiration, MAX_FEE, GAS_LIMIT);
        bytes memory pmInput = _buildApprovalInput(FEE_AMOUNT, expiration, signature);
        Transaction memory txn = _buildTransaction(user, dest, GAS_LIMIT, MAX_FEE, pmInput);

        vm.prank(attacker);
        vm.expectRevert(BasePaymaster.AccessRestrictedToBootloader.selector);
        paymaster.validateAndPayForPaymasterTransaction(bytes32(0), bytes32(0), txn);
    }

    function test_withdrawTokens() public {
        feeToken.mint(address(paymaster), 10 ether);
        vm.prank(withdrawer);
        vm.expectEmit(true, true, false, true);
        emit ERC20FeePaymaster.TokensWithdrawn(address(feeToken), withdrawer, 3 ether);
        paymaster.withdrawTokens(address(feeToken), withdrawer, 3 ether);
        assertEq(feeToken.balanceOf(withdrawer), 3 ether);
    }

    function test_RevertIf_withdrawTokensUnauthorized() public {
        feeToken.mint(address(paymaster), 1 ether);
        vm.expectRevert_AccessControlUnauthorizedAccount(attacker, paymaster.WITHDRAWER_ROLE());
        vm.prank(attacker);
        paymaster.withdrawTokens(address(feeToken), attacker, 1 ether);
    }

    function test_RevertIf_constructorZeroFeeToken() public {
        vm.expectRevert(ERC20FeePaymaster.ZeroAddress.selector);
        new ERC20FeePaymaster(admin, withdrawer, address(0), feeSigner, QUOTA, PERIOD);
    }

    function test_RevertIf_constructorZeroFeeSigner() public {
        vm.expectRevert(ERC20FeePaymaster.ZeroAddress.selector);
        new ERC20FeePaymaster(admin, withdrawer, address(feeToken), address(0), QUOTA, PERIOD);
    }
}
