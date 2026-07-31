// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {
    IPaymaster,
    PAYMASTER_VALIDATION_SUCCESS_MAGIC
} from "lib/era-contracts/l2-contracts/contracts/interfaces/IPaymaster.sol";
import {IPaymasterFlow} from "lib/era-contracts/l2-contracts/contracts/interfaces/IPaymasterFlow.sol";
import {Transaction} from "lib/era-contracts/l2-contracts/contracts/L2ContractHelper.sol";

import {QuotaControl} from "../QuotaControl.sol";
import {BasePaymaster, BOOTLOADER_FORMAL_ADDRESS} from "./BasePaymaster.sol";

/// @notice zkSync paymaster that lets users pay gas in a single ERC-20 fee token (NODL).
/// @dev ApprovalBased only. Off-chain `erc20-fee-signer` prices the fee, applies markup, and
///      EIP-712-signs `(from, to, token, amount, expirationTime, maxFeePerGas, gasLimit)`.
///      Inner paymaster input encoding matches ZyFi's shape: `abi.encode(uint64 expirationTime, bytes signature)`.
///      Periodic ETH spend is capped via `QuotaControl` (quota unit = wei paid to the bootloader).
contract ERC20FeePaymaster is BasePaymaster, QuotaControl, EIP712 {
    using SafeERC20 for IERC20;

    /// @dev Keccak of FeeApproval(address from,address to,address token,uint256 amount,uint64 expirationTime,uint256 maxFeePerGas,uint256 gasLimit)
    bytes32 public constant FEE_APPROVAL_TYPEHASH = keccak256(
        "FeeApproval(address from,address to,address token,uint256 amount,uint64 expirationTime,uint256 maxFeePerGas,uint256 gasLimit)"
    );

    string public constant SIGNING_DOMAIN = "erc20-fee-paymaster.nodle";
    string public constant SIGNATURE_VERSION = "1";

    /// @notice Hard cap on signed approval lifetime. Bounds damage if the fee-signer key is compromised.
    uint64 public constant MAX_SIGNATURE_TTL = 15 minutes;

    IERC20 public immutable feeToken;

    /// @notice Off-chain fee signer whose EIP-712 signatures this paymaster accepts.
    address public feeSigner;

    event FeeSignerUpdated(address indexed previousSigner, address indexed newSigner);
    event FeeTokenCollected(address indexed from, address indexed token, uint256 amount);
    event TokensWithdrawn(address indexed token, address indexed to, uint256 amount);

    error ZeroAddress();
    error InvalidFeeToken();
    error ZeroFeeAmount();
    error ApprovalExpired(uint64 expirationTime);
    error ApprovalTtlTooLong(uint64 expirationTime);
    error AllowanceTooLow(uint256 provided, uint256 required);
    error PaymasterBalanceTooLow();

    constructor(
        address admin,
        address withdrawer,
        address feeToken_,
        address feeSigner_,
        uint256 initialQuota,
        uint256 initialPeriod
    )
        BasePaymaster(admin, withdrawer)
        QuotaControl(initialQuota, initialPeriod, admin)
        EIP712(SIGNING_DOMAIN, SIGNATURE_VERSION)
    {
        if (feeToken_ == address(0) || feeSigner_ == address(0)) {
            revert ZeroAddress();
        }
        feeToken = IERC20(feeToken_);
        feeSigner = feeSigner_;
        emit FeeSignerUpdated(address(0), feeSigner_);
    }

    /// @notice Rotate the off-chain fee signer.
    function setFeeSigner(address newSigner) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newSigner == address(0)) revert ZeroAddress();
        address previous = feeSigner;
        feeSigner = newSigner;
        emit FeeSignerUpdated(previous, newSigner);
    }

    /// @notice Withdraw collected fee tokens (or any ERC-20) from this contract.
    function withdrawTokens(address token, address to, uint256 amount) external {
        _checkRole(WITHDRAWER_ROLE);
        if (to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
        emit TokensWithdrawn(token, to, amount);
    }

    /// @notice EIP-712 digest the off-chain fee signer must sign.
    function hashFeeApproval(
        address from,
        address to,
        address token,
        uint256 amount,
        uint64 expirationTime,
        uint256 maxFeePerGas,
        uint256 gasLimit
    ) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(FEE_APPROVAL_TYPEHASH, from, to, token, amount, expirationTime, maxFeePerGas, gasLimit)
            )
        );
    }

    /// @inheritdoc IPaymaster
    /// @dev Overrides `BasePaymaster` so validation can bind the signature to `maxFeePerGas` /
    ///      `gasLimit` individually (ZyFi-compatible fields) and return `magic = 0` on a bad
    ///      signature for gas estimation without reverting.
    function validateAndPayForPaymasterTransaction(
        bytes32, /*_txHash*/
        bytes32, /*_suggestedSignedHash*/
        Transaction calldata transaction
    )
        external
        payable
        override
        returns (bytes4 magic, bytes memory context)
    {
        _mustBeBootloader();

        magic = PAYMASTER_VALIDATION_SUCCESS_MAGIC;
        context = "";

        if (transaction.paymasterInput.length < 4) {
            revert InvalidPaymasterInput("The standard paymaster input must be at least 4 bytes long");
        }

        bytes4 paymasterInputSelector = bytes4(transaction.paymasterInput[0:4]);
        if (paymasterInputSelector != IPaymasterFlow.approvalBased.selector) {
            revert PaymasterFlowNotSupported();
        }

        (address token, uint256 amount, bytes memory data) =
            abi.decode(transaction.paymasterInput[4:], (address, uint256, bytes));

        if (token != address(feeToken)) revert InvalidFeeToken();
        if (amount == 0) revert ZeroFeeAmount();

        (uint64 expirationTime, bytes memory signature) = abi.decode(data, (uint64, bytes));

        if (block.timestamp > expirationTime) revert ApprovalExpired(expirationTime);
        if (expirationTime > block.timestamp + MAX_SIGNATURE_TTL) {
            revert ApprovalTtlTooLong(expirationTime);
        }

        address userAddress = address(uint160(transaction.from));
        address destAddress = address(uint160(transaction.to));

        bytes32 digest = hashFeeApproval(
            userAddress, destAddress, token, amount, expirationTime, transaction.maxFeePerGas, transaction.gasLimit
        );

        // Invalid signature → magic = 0 so eth_estimateGas still explores this path on mainnet,
        // while a real submission with a bad signature is rejected by the bootloader.
        if (!SignatureChecker.isValidSignatureNow(feeSigner, digest, signature)) {
            magic = bytes4(0);
        }

        uint256 requiredETH = transaction.gasLimit * transaction.maxFeePerGas;

        uint256 providedAllowance = feeToken.allowance(userAddress, address(this));
        if (providedAllowance < amount) revert AllowanceTooLow(providedAllowance, amount);

        if (address(this).balance < requiredETH) revert PaymasterBalanceTooLow();

        _checkedResetClaimed();
        _checkedUpdateClaimed(requiredETH);

        feeToken.safeTransferFrom(userAddress, address(this), amount);
        emit FeeTokenCollected(userAddress, token, amount);

        (bool success,) = payable(BOOTLOADER_FORMAL_ADDRESS).call{value: requiredETH}("");
        if (!success) revert NotEnoughETHInPaymasterToPayForTransaction();
    }

    function _validateAndPayGeneralFlow(address, address, uint256, bytes memory) internal pure override {
        revert PaymasterFlowNotSupported();
    }

    function _validateAndPayApprovalBasedFlow(address, address, address, uint256, bytes memory, uint256)
        internal
        pure
        override
    {
        // ApprovalBased validation is implemented in `validateAndPayForPaymasterTransaction`
        // so the signature can bind `maxFeePerGas` and `gasLimit`. This hook must not be reached.
        revert PaymasterFlowNotSupported();
    }
}
