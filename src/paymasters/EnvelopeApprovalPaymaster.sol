// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.26;

import {
    IPaymaster,
    PAYMASTER_VALIDATION_SUCCESS_MAGIC
} from "lib/era-contracts/l2-contracts/contracts/interfaces/IPaymaster.sol";
import {IPaymasterFlow} from "lib/era-contracts/l2-contracts/contracts/interfaces/IPaymasterFlow.sol";
import {Transaction} from "lib/era-contracts/l2-contracts/contracts/L2ContractHelper.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {BasePaymaster, BOOTLOADER_FORMAL_ADDRESS} from "./BasePaymaster.sol";
import {QuotaControl} from "../QuotaControl.sol";

/// @title  Envelope Approval Paymaster
/// @notice Sponsors gas in two modes — both share one ETH pool and one daily QuotaControl.
///
///         Mode A — User approval: caller is a regular user. Path-C support: the user's tx
///         is a token `approve(envelope, ...)` or `setApprovalForAll(envelope, true)` and
///         must carry a fresh EIP-712 grant signed by `operatorSigner` (single-use nonce,
///         deadline). Defends against arbitrary spend with: per-token-irrelevant + selector
///         + spender + grant.
///
///         Mode B — Operator direct call: caller is on the operator allowlist (set by admin)
///         and the target (`tx.to`) is on the allowed-targets allowlist. No grant / selector /
///         spender check: the operator's EOA identity is the auth (the operator is a trusted
///         persistent identity, not an ephemeral grant holder). Used so the operator can call
///         the envelope vault (`makeCustomDeposit`, `withdrawDeposit`, etc.) without holding
///         ETH itself — the paymaster's pool funds those ops.
///
///         Both modes apply the same per-tx ETH cap (`maxEthPerTx`) and contribute to the
///         same `QuotaControl` daily quota.
/// @dev    Overrides `validateAndPayForPaymasterTransaction` directly (instead of the
///         `_validateAndPayGeneralFlow` hook) because validation requires the full
///         `Transaction` calldata — the hook signature hides `transaction.data` and
///         `transaction.paymasterInput`.
///         Storage writes in validation (nonce, quota counters, mode-tracking) are permitted
///         by EraVM paymaster-validation rules.
contract EnvelopeApprovalPaymaster is BasePaymaster, QuotaControl {
    bytes4 internal constant APPROVE_SEL = 0x095ea7b3; // approve(address,uint256) — ERC-20 + ERC-721
    bytes4 internal constant SET_APPROVAL_FOR_ALL_SEL = 0xa22cb465; // setApprovalForAll(address,bool) — ERC-721 + ERC-1155

    bytes32 public constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 public constant GRANT_TYPEHASH =
        keccak256("EnvelopeApprovalGrant(address user,uint256 deadline,bytes32 nonce)");

    bytes32 public immutable DOMAIN_SEPARATOR;
    address public immutable envelopeVault;
    /// @notice Maximum wei the paymaster will sponsor for a single tx (defense-in-depth
    /// against operator-key compromise; per-tx cost is bounded regardless of token).
    uint256 public immutable maxEthPerTx;

    address public operatorSigner;
    mapping(bytes32 => bool) public isNonceUsed;
    /// @notice Mode B — EOAs allowed to call any function on an allowlisted target.
    mapping(address => bool) public isOperator;
    /// @notice Mode B — contracts an operator EOA may call gaslessly.
    mapping(address => bool) public isAllowedTarget;

    event OperatorSignerUpdated(address indexed previousSigner, address indexed newSigner);
    event ApprovalSponsored(address indexed user, address indexed token, bytes32 indexed nonce, uint256 gasPaid);
    event OperatorCallSponsored(address indexed operator, address indexed target, uint256 gasPaid);
    event OperatorSet(address indexed operator, bool allowed);
    event AllowedTargetSet(address indexed target, bool allowed);

    error WrongFlow();
    error GrantExpired();
    error NonceAlreadyUsed();
    error InvalidGrantSignature();
    error UnsupportedSelector();
    error SpenderNotEnvelope();
    error TargetNotAllowed();
    error PerTxLimitExceeded();
    error InsufficientPaymasterBalance();
    error ZeroAddress();
    error Unused();

    /// @param admin            DEFAULT_ADMIN_ROLE
    /// @param withdrawer       WITHDRAWER_ROLE
    /// @param operatorSigner_  EOA or contract whose ECDSA signatures the paymaster will accept as grants
    /// @param envelope_        Envelope vault address (the only allowed spender/operator for sponsored approvals)
    /// @param maxEthPerTx_     Hard ceiling on wei sponsored per single tx
    /// @param initialQuota     Total wei sponsorable per period
    /// @param initialPeriod    Period length in seconds (max 30 days, see QuotaControl)
    constructor(
        address admin,
        address withdrawer,
        address operatorSigner_,
        address envelope_,
        uint256 maxEthPerTx_,
        uint256 initialQuota,
        uint256 initialPeriod
    ) BasePaymaster(admin, withdrawer) QuotaControl(initialQuota, initialPeriod, admin) {
        if (admin == address(0) || envelope_ == address(0) || operatorSigner_ == address(0)) revert ZeroAddress();

        envelopeVault = envelope_;
        operatorSigner = operatorSigner_;
        maxEthPerTx = maxEthPerTx_;

        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes("EnvelopeApprovalPaymaster")),
                keccak256(bytes("1")),
                block.chainid,
                address(this)
            )
        );
    }

    function validateAndPayForPaymasterTransaction(bytes32, bytes32, Transaction calldata transaction)
        external
        payable
        override
        returns (bytes4 magic, bytes memory)
    {
        _mustBeBootloader();
        _requireGeneralFlow(transaction.paymasterInput);

        address from = address(uint160(transaction.from));
        address to = address(uint160(transaction.to));
        uint256 requiredETH = transaction.gasLimit * transaction.maxFeePerGas;
        if (requiredETH > maxEthPerTx) revert PerTxLimitExceeded();

        if (isOperator[from]) {
            // Mode B — operator EOA calls an allowlisted target.
            if (!isAllowedTarget[to]) revert TargetNotAllowed();
            _payBootloader(requiredETH);
            emit OperatorCallSponsored(from, to, requiredETH);
        } else {
            // Mode A — user-side approval gated by an operator EIP-712 grant.
            bytes32 nonce = _verifyAndConsumeGrant(from, transaction.paymasterInput);
            _requireApprovalCallToEnvelope(transaction.data);
            _payBootloader(requiredETH);
            emit ApprovalSponsored(from, to, nonce, requiredETH);
        }

        magic = PAYMASTER_VALIDATION_SUCCESS_MAGIC;
    }

    /// @dev Reverts unless paymasterInput starts with the `general` flow selector.
    function _requireGeneralFlow(bytes calldata paymasterInput) internal pure {
        if (paymasterInput.length < 4) {
            revert InvalidPaymasterInput("paymasterInput must contain at least a flow selector");
        }
        if (bytes4(paymasterInput[0:4]) != IPaymasterFlow.general.selector) revert WrongFlow();
    }

    /// @dev Decodes the EIP-712 grant from the inner bytes, verifies the signature,
    ///      checks deadline + nonce-uniqueness, and marks the nonce used.
    function _verifyAndConsumeGrant(address user, bytes calldata paymasterInput)
        internal
        returns (bytes32 nonce)
    {
        bytes memory inner = abi.decode(paymasterInput[4:], (bytes));
        uint256 deadline;
        bytes memory signature;
        (deadline, nonce, signature) = abi.decode(inner, (uint256, bytes32, bytes));

        if (block.timestamp > deadline) revert GrantExpired();
        if (isNonceUsed[nonce]) revert NonceAlreadyUsed();

        bytes32 structHash = keccak256(abi.encode(GRANT_TYPEHASH, user, deadline, nonce));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
        // SignatureChecker supports both EOA ECDSA signatures and EIP-1271 contract signers,
        // so operatorSigner can be a multisig / smart account in production.
        if (!SignatureChecker.isValidSignatureNow(operatorSigner, digest, signature)) {
            revert InvalidGrantSignature();
        }

        isNonceUsed[nonce] = true;
    }

    /// @dev Reverts unless the user's call is approve(envelope,...) or setApprovalForAll(envelope,...).
    function _requireApprovalCallToEnvelope(bytes calldata data) internal view {
        if (data.length < 36) revert UnsupportedSelector();
        bytes4 sel = bytes4(data[0:4]);
        if (sel != APPROVE_SEL && sel != SET_APPROVAL_FOR_ALL_SEL) revert UnsupportedSelector();
        address spender;
        // Both target selectors have an `address` as their first argument.
        assembly {
            spender := calldataload(add(data.offset, 0x04))
        }
        if (spender != envelopeVault) revert SpenderNotEnvelope();
    }

    /// @dev Checks balance, bumps quota counters, sends ETH to the bootloader.
    function _payBootloader(uint256 requiredETH) internal {
        if (address(this).balance < requiredETH) revert InsufficientPaymasterBalance();
        _checkedResetClaimed();
        _checkedUpdateClaimed(requiredETH);
        (bool ok,) = BOOTLOADER_FORMAL_ADDRESS.call{value: requiredETH}("");
        if (!ok) revert InsufficientPaymasterBalance();
    }

    /// @dev Unused — full validation lives in `validateAndPayForPaymasterTransaction`.
    /// Required because BasePaymaster declares this hook abstract.
    function _validateAndPayGeneralFlow(address, address, uint256) internal pure override {
        revert Unused();
    }

    /// @dev Unused — only the `general` flow is supported.
    function _validateAndPayApprovalBasedFlow(address, address, address, uint256, bytes memory, uint256)
        internal
        pure
        override
    {
        revert PaymasterFlowNotSupported();
    }

    // ── Admin ──────────────────────────────────────────────────────────────

    function setOperatorSigner(address newSigner) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newSigner == address(0)) revert ZeroAddress();
        emit OperatorSignerUpdated(operatorSigner, newSigner);
        operatorSigner = newSigner;
    }

    /// @notice Add or remove a Mode-B operator EOA. Operators can call any function on
    /// an allowlisted target with paymaster-funded gas; no EIP-712 grant required.
    function setOperator(address operator, bool allowed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (operator == address(0)) revert ZeroAddress();
        isOperator[operator] = allowed;
        emit OperatorSet(operator, allowed);
    }

    /// @notice Add or remove a Mode-B target contract. Operator EOAs can call any function
    /// on these targets with paymaster-funded gas.
    function setAllowedTarget(address target, bool allowed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (target == address(0)) revert ZeroAddress();
        isAllowedTarget[target] = allowed;
        emit AllowedTargetSet(target, allowed);
    }
}
