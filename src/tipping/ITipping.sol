// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.26;

/**
 * @title ITipping
 * @notice Agnostic tipping: any ERC-20, any NFT, any account. The contract knows nothing about
 *         the NFT; the recipient of a post tip is attested off-chain by the Nodle signer (the
 *         feed API resolves it from indexed data) and verified here as an EIP-712 signature.
 *         The event surface is what the feed indexer consumes; keep it stable.
 */
interface ITipping {
    /// @notice A post was tipped. `amount` is gross (what the tipper gave); `fee` went to the fee recipient.
    event Tipped(
        address indexed tipper,
        address indexed collection,
        uint256 indexed tokenId,
        address token,
        address recipient,
        uint256 amount,
        uint256 fee
    );
    /// @notice An account was tipped directly, not tied to a post.
    event AccountTipped(address indexed tipper, address indexed to, address token, uint256 amount, uint256 fee);
    event FeeUpdated(uint16 feeBps);
    event FeeRecipientUpdated(address indexed feeRecipient);
    event SignerUpdated(address indexed signer);

    error ZeroAddress();
    error ZeroAmount();
    error SelfTip();
    error Expired(uint256 deadline);
    error NonceUsed(bytes32 nonce);
    error InvalidSignature();
    error FeeTooHigh(uint16 feeBps);
    error InvalidFeeRecipient(address recipient);

    /// @notice The authorization a post tip carries. Signed by `signer()` over EIP-712.
    struct TipAuthorization {
        address tipper;
        address token;
        address collection;
        uint256 tokenId;
        address recipient;
        uint256 amount;
        uint256 deadline;
        bytes32 nonce;
    }

    /// @notice Tip a post. `auth.tipper` must be the caller; `signature` is the signer's EIP-712 signature over `auth`.
    function tip(TipAuthorization calldata auth, bytes calldata signature) external;
    /// @notice Tip an account the caller names. No authorization needed.
    function tipAccount(address token, address to, uint256 amount) external;

    function signer() external view returns (address);
    function feeBps() external view returns (uint16);
    function feeRecipient() external view returns (address);
    function nonceUsed(bytes32 nonce) external view returns (bool);
    /// @notice The EIP-712 digest the signer signs for `auth` (for clients and tests).
    function hashAuthorization(TipAuthorization calldata auth) external view returns (bytes32);
}
