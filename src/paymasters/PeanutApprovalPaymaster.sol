// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.26;

import {
    IPaymaster,
    PAYMASTER_VALIDATION_SUCCESS_MAGIC
} from "lib/era-contracts/l2-contracts/contracts/interfaces/IPaymaster.sol";
import {IPaymasterFlow} from "lib/era-contracts/l2-contracts/contracts/interfaces/IPaymasterFlow.sol";
import {Transaction} from "lib/era-contracts/l2-contracts/contracts/L2ContractHelper.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {BasePaymaster, BOOTLOADER_FORMAL_ADDRESS} from "./BasePaymaster.sol";
import {QuotaControl} from "../QuotaControl.sol";

/// @title  Peanut Approval Paymaster
/// @notice Sponsors gas for a *narrow* set of operations: ERC-20 / ERC-721 `approve(peanut, ...)`
///         and ERC-721 / ERC-1155 `setApprovalForAll(peanut, ...)` — the txs needed to grant
///         PeanutV4 access to a user's tokens before the operator submits `makeCustomDeposit`.
/// @dev    Validation enforced per call:
///           - tx.to is on the per-token allowlist
///           - inner selector is approve(address,uint256) or setApprovalForAll(address,bool)
///           - the spender/operator argument == peanutVault
///           - the user holds an unexpired EIP-712 grant signed by `operatorSigner`
///           - daily wei quota hasn't been exhausted (QuotaControl)
///         Overrides `validateAndPayForPaymasterTransaction` directly (instead of the
///         `_validateAndPayGeneralFlow` hook) because validation requires the full
///         `Transaction` calldata — the hook signature hides `transaction.data` and
///         `transaction.paymasterInput`.
///         Storage writes in validation (nonce, quota counters) are permitted by EraVM's
///         paymaster-validation rules.
contract PeanutApprovalPaymaster is BasePaymaster, QuotaControl {
    bytes32 public constant ALLOWLIST_ADMIN_ROLE = keccak256("ALLOWLIST_ADMIN_ROLE");

    bytes4 internal constant APPROVE_SEL = 0x095ea7b3; // approve(address,uint256) — ERC-20 + ERC-721
    bytes4 internal constant SET_APPROVAL_FOR_ALL_SEL = 0xa22cb465; // setApprovalForAll(address,bool) — ERC-721 + ERC-1155

    bytes32 public constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 public constant GRANT_TYPEHASH =
        keccak256("PeanutApprovalGrant(address user,uint256 deadline,bytes32 nonce)");

    bytes32 public immutable DOMAIN_SEPARATOR;
    address public immutable peanutVault;

    address public operatorSigner;
    mapping(address => bool) public isAllowedToken;
    mapping(bytes32 => bool) public isNonceUsed;

    event TokensAllowed(address[] tokens);
    event TokensRevoked(address[] tokens);
    event OperatorSignerUpdated(address indexed previousSigner, address indexed newSigner);
    event ApprovalSponsored(address indexed user, address indexed token, bytes32 indexed nonce, uint256 gasPaid);

    error WrongFlow();
    error GrantExpired();
    error NonceAlreadyUsed();
    error InvalidGrantSignature();
    error TokenNotAllowed();
    error UnsupportedSelector();
    error SpenderNotPeanut();
    error InsufficientPaymasterBalance();
    error ZeroAddress();
    error Unused();

    /// @param admin            DEFAULT_ADMIN_ROLE + ALLOWLIST_ADMIN_ROLE
    /// @param withdrawer       WITHDRAWER_ROLE
    /// @param operatorSigner_  EOA or contract whose ECDSA signatures the paymaster will accept as grants
    /// @param peanut_          PeanutV4 vault address (the only allowed spender/operator for sponsored approvals)
    /// @param initialQuota     Total wei sponsorable per period
    /// @param initialPeriod    Period length in seconds (max 30 days, see QuotaControl)
    constructor(
        address admin,
        address withdrawer,
        address operatorSigner_,
        address peanut_,
        uint256 initialQuota,
        uint256 initialPeriod
    ) BasePaymaster(admin, withdrawer) QuotaControl(initialQuota, initialPeriod, admin) {
        if (admin == address(0) || peanut_ == address(0) || operatorSigner_ == address(0)) revert ZeroAddress();
        _grantRole(ALLOWLIST_ADMIN_ROLE, admin);

        peanutVault = peanut_;
        operatorSigner = operatorSigner_;

        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes("PeanutApprovalPaymaster")),
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

        address user = address(uint160(transaction.from));
        bytes32 nonce = _verifyAndConsumeGrant(user, transaction.paymasterInput);

        address token = address(uint160(transaction.to));
        if (!isAllowedToken[token]) revert TokenNotAllowed();
        _requireApprovalCallToPeanut(transaction.data);

        uint256 requiredETH = transaction.gasLimit * transaction.maxFeePerGas;
        _payBootloader(requiredETH);

        emit ApprovalSponsored(user, token, nonce, requiredETH);
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
        if (ECDSA.recover(digest, signature) != operatorSigner) revert InvalidGrantSignature();

        isNonceUsed[nonce] = true;
    }

    /// @dev Reverts unless the user's call is approve(peanut,...) or setApprovalForAll(peanut,...).
    function _requireApprovalCallToPeanut(bytes calldata data) internal view {
        if (data.length < 36) revert UnsupportedSelector();
        bytes4 sel = bytes4(data[0:4]);
        if (sel != APPROVE_SEL && sel != SET_APPROVAL_FOR_ALL_SEL) revert UnsupportedSelector();
        address spender;
        // Both target selectors have an `address` as their first argument.
        assembly {
            spender := calldataload(add(data.offset, 0x04))
        }
        if (spender != peanutVault) revert SpenderNotPeanut();
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

    function addAllowedTokens(address[] calldata tokens) external onlyRole(ALLOWLIST_ADMIN_ROLE) {
        for (uint256 i = 0; i < tokens.length; ++i) {
            isAllowedToken[tokens[i]] = true;
        }
        emit TokensAllowed(tokens);
    }

    function removeAllowedTokens(address[] calldata tokens) external onlyRole(ALLOWLIST_ADMIN_ROLE) {
        for (uint256 i = 0; i < tokens.length; ++i) {
            isAllowedToken[tokens[i]] = false;
        }
        emit TokensRevoked(tokens);
    }

    function setOperatorSigner(address newSigner) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newSigner == address(0)) revert ZeroAddress();
        emit OperatorSignerUpdated(operatorSigner, newSigner);
        operatorSigner = newSigner;
    }
}
