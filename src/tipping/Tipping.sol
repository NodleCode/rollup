// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

import {ITipping} from "./ITipping.sol";

/**
 * @title Tipping
 * @notice Immutable, agnostic tipping (nft-feed-indexer design §6.2). No proxy and no upgrade
 *         path on purpose: an allowance granted to this address can only ever be spent by the
 *         approver's own `tip`/`tipAccount` calls, because `transferFrom` is only called with
 *         `from == msg.sender`. The contract holds no funds and knows no token or collection.
 *
 * Post tips carry a `TipAuthorization` signed by `signer` (the Nodle feed API, which resolves
 * the recipient from indexed data: holder, minter or creator, by policy that lives off-chain).
 * The authorization binds the tipper, the token, the post, the recipient, the amount, a
 * deadline and a single-use nonce, so a signature cannot be replayed or redirected.
 * Account tips name their recipient directly and need no signature.
 *
 * Roles: DEFAULT_ADMIN_ROLE (fee, fee recipient, signer, pause). `signer` is a single address,
 * rotated in one call so a leaked key stops working immediately; it may be a contract (ERC-1271).
 */
contract Tipping is ITipping, AccessControl, ReentrancyGuard, Pausable, EIP712 {
    using SafeERC20 for IERC20;

    uint16 public constant MAX_FEE_BPS = 1000;
    uint256 public constant BPS = 10_000;
    bytes32 public constant TIP_AUTHORIZATION_TYPEHASH = keccak256(
        "TipAuthorization(address tipper,address token,address collection,uint256 tokenId,address recipient,uint256 amount,uint256 deadline,bytes32 nonce)"
    );

    address public signer;
    uint16 public feeBps;
    address public feeRecipient;
    mapping(bytes32 nonce => bool used) public nonceUsed;

    constructor(address admin, address initialSigner) EIP712("NodleTipping", "1") {
        if (admin == address(0) || initialSigner == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        signer = initialSigner;
        feeRecipient = admin;
        emit SignerUpdated(initialSigner);
        emit FeeUpdated(0);
        emit FeeRecipientUpdated(admin);
    }

    // ───────── Tipping ─────────

    /// @inheritdoc ITipping
    function tip(TipAuthorization calldata auth, bytes calldata signature) external whenNotPaused nonReentrant {
        if (
            auth.tipper != msg.sender
                || !SignatureChecker.isValidSignatureNow(signer, hashAuthorization(auth), signature)
        ) {
            revert InvalidSignature();
        }
        if (block.timestamp > auth.deadline) revert Expired(auth.deadline);
        if (nonceUsed[auth.nonce]) revert NonceUsed(auth.nonce);
        nonceUsed[auth.nonce] = true;

        uint256 fee = _pay(auth.token, auth.recipient, auth.amount);
        emit Tipped(msg.sender, auth.collection, auth.tokenId, auth.token, auth.recipient, auth.amount, fee);
    }

    /// @inheritdoc ITipping
    function tipAccount(address token, address to, uint256 amount) external whenNotPaused nonReentrant {
        uint256 fee = _pay(token, to, amount);
        emit AccountTipped(msg.sender, to, token, amount, fee);
    }

    /// @dev Shared guards and transfers. Only ever pulls from msg.sender: the property the
    ///      immutability argument rests on. Returns the fee taken.
    function _pay(address token, address to, uint256 amount) internal returns (uint256 fee) {
        if (token == address(0) || to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (to == msg.sender) revert SelfTip();
        fee = (amount * feeBps) / BPS;
        IERC20(token).safeTransferFrom(msg.sender, to, amount - fee);
        if (fee > 0) IERC20(token).safeTransferFrom(msg.sender, feeRecipient, fee);
    }

    /// @inheritdoc ITipping
    function hashAuthorization(TipAuthorization calldata auth) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    TIP_AUTHORIZATION_TYPEHASH,
                    auth.tipper,
                    auth.token,
                    auth.collection,
                    auth.tokenId,
                    auth.recipient,
                    auth.amount,
                    auth.deadline,
                    auth.nonce
                )
            )
        );
    }

    // ───────── Admin ─────────

    function setSigner(address newSigner) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newSigner == address(0)) revert ZeroAddress();
        signer = newSigner;
        emit SignerUpdated(newSigner);
    }

    function setFee(uint16 bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (bps > MAX_FEE_BPS) revert FeeTooHigh(bps);
        feeBps = bps;
        emit FeeUpdated(bps);
    }

    function setFeeRecipient(address recipient) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (recipient == address(0)) revert ZeroAddress();
        // No rescue path exists in an immutable contract: fees sent to this address are lost.
        if (recipient == address(this)) revert InvalidFeeRecipient(recipient);
        feeRecipient = recipient;
        emit FeeRecipientUpdated(recipient);
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }
}
