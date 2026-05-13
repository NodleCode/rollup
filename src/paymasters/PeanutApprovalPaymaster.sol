// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.26;

import {
    IPaymaster,
    ExecutionResult,
    PAYMASTER_VALIDATION_SUCCESS_MAGIC
} from "lib/era-contracts/l2-contracts/contracts/interfaces/IPaymaster.sol";
import {IPaymasterFlow} from "lib/era-contracts/l2-contracts/contracts/interfaces/IPaymasterFlow.sol";
import {Transaction} from "lib/era-contracts/l2-contracts/contracts/L2ContractHelper.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {QuotaControl} from "../QuotaControl.sol";

/// @dev Bootloader address (duplicated from era-contracts/system-contracts/Constants.sol —
/// the canonical file uses a template variable that can't be imported).
uint160 constant SYSTEM_CONTRACTS_OFFSET = 0x8000;
address payable constant BOOTLOADER_FORMAL_ADDRESS = payable(address(SYSTEM_CONTRACTS_OFFSET + 0x01));

/// @title  Peanut Approval Paymaster
/// @notice Sponsors gas for a *narrow* set of operations: ERC-20 / ERC-721 `approve(peanut, ...)`
///         and ERC-721 / ERC-1155 `setApprovalForAll(peanut, ...)` — the txs needed to grant
///         PeanutV4 access to a user's tokens before the operator submits `makeCustomDeposit`.
/// @dev    Validation enforced per call:
///           - tx.to is on the per-token allowlist
///           - inner selector is approve(address,uint256) or setApprovalForAll(address,bool)
///           - the spender/operator argument == peanutVault
///           - the user holds an unexpired EIP-712 grant signed by `operatorSigner`
///           - daily quota (in wei) hasn't been exhausted
///         Storage writes in validation (nonce, quota counters) are permitted by EraVM's
///         paymaster-validation rules.
contract PeanutApprovalPaymaster is IPaymaster, QuotaControl {
    bytes32 public constant ALLOWLIST_ADMIN_ROLE = keccak256("ALLOWLIST_ADMIN_ROLE");
    bytes32 public constant WITHDRAWER_ROLE = keccak256("WITHDRAWER_ROLE");

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
    event Withdrawn(address indexed to, uint256 amount);

    error OnlyBootloader();
    error WrongFlow();
    error InvalidPaymasterInput();
    error GrantExpired();
    error NonceAlreadyUsed();
    error InvalidGrantSignature();
    error TokenNotAllowed();
    error UnsupportedSelector();
    error SpenderNotPeanut();
    error InsufficientPaymasterBalance();
    error WithdrawFailed();
    error ZeroAddress();

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
    ) QuotaControl(initialQuota, initialPeriod, admin) {
        if (admin == address(0) || peanut_ == address(0) || operatorSigner_ == address(0)) revert ZeroAddress();
        _grantRole(ALLOWLIST_ADMIN_ROLE, admin);
        _grantRole(WITHDRAWER_ROLE, withdrawer);

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
        returns (bytes4 magic, bytes memory context)
    {
        if (msg.sender != BOOTLOADER_FORMAL_ADDRESS) revert OnlyBootloader();

        // 1. Flow selector — only general supported.
        if (transaction.paymasterInput.length < 4) revert InvalidPaymasterInput();
        bytes4 flow = bytes4(transaction.paymasterInput[0:4]);
        if (flow != IPaymasterFlow.general.selector) revert WrongFlow();

        // 2. Decode grant from the inner bytes.
        bytes memory inner = abi.decode(transaction.paymasterInput[4:], (bytes));
        (uint256 deadline, bytes32 nonce, bytes memory signature) = abi.decode(inner, (uint256, bytes32, bytes));

        if (block.timestamp > deadline) revert GrantExpired();
        if (isNonceUsed[nonce]) revert NonceAlreadyUsed();

        address user = address(uint160(transaction.from));
        bytes32 structHash = keccak256(abi.encode(GRANT_TYPEHASH, user, deadline, nonce));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
        address signer = ECDSA.recover(digest, signature);
        if (signer != operatorSigner) revert InvalidGrantSignature();

        // 3. Token allowlist.
        address token = address(uint160(transaction.to));
        if (!isAllowedToken[token]) revert TokenNotAllowed();

        // 4. Inner selector + first arg (spender / operator) must equal peanut.
        bytes calldata innerCall = transaction.data;
        if (innerCall.length < 36) revert UnsupportedSelector();
        bytes4 sel = bytes4(innerCall[0:4]);
        if (sel != APPROVE_SEL && sel != SET_APPROVAL_FOR_ALL_SEL) revert UnsupportedSelector();
        address spender;
        // Both target selectors have an `address` as their first argument; read it directly.
        assembly {
            spender := calldataload(add(innerCall.offset, 0x04))
        }
        if (spender != peanutVault) revert SpenderNotPeanut();

        // 5. Settle.
        uint256 requiredETH = transaction.gasLimit * transaction.maxFeePerGas;
        if (address(this).balance < requiredETH) revert InsufficientPaymasterBalance();

        _checkedResetClaimed();
        _checkedUpdateClaimed(requiredETH);
        isNonceUsed[nonce] = true;

        (bool ok,) = BOOTLOADER_FORMAL_ADDRESS.call{value: requiredETH}("");
        if (!ok) revert InsufficientPaymasterBalance();

        emit ApprovalSponsored(user, token, nonce, requiredETH);
        magic = PAYMASTER_VALIDATION_SUCCESS_MAGIC;
    }

    function postTransaction(
        bytes calldata, /*_context*/
        Transaction calldata, /*_transaction*/
        bytes32, /*_txHash*/
        bytes32, /*_suggestedSignedHash*/
        ExecutionResult, /*_txResult*/
        uint256 /*_maxRefundedGas*/
    ) external payable {
        if (msg.sender != BOOTLOADER_FORMAL_ADDRESS) revert OnlyBootloader();
        // Refunds are not supported.
    }

    receive() external payable {}

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

    /// @notice Withdraw native ETH from the paymaster.
    function withdraw(address to, uint256 amount) external onlyRole(WITHDRAWER_ROLE) {
        emit Withdrawn(to, amount);
        (bool ok,) = payable(to).call{value: amount}("");
        if (!ok) revert WithdrawFailed();
    }
}
