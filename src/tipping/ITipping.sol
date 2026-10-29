// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.26;

/**
 * @title ITipping
 * @notice Agnostic tipping: any ERC-20, any NFT, any account. The recipient of a post tip is
 *         resolved on-chain from the NFT itself: the current owner for ERC-721, the ERC-2981
 *         royalty receiver for ERC-1155 (editions have many holders; the royalty receiver is the
 *         creator's payout address). No backend involvement, no signature, no allowlist.
 *         The event surface is what the feed indexer consumes; keep it stable.
 */
interface ITipping {
    enum Standard {
        ERC721,
        ERC1155
    }

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

    error ZeroAddress();
    error ZeroAmount();
    error SelfTip();
    error NotAContract(address collection);
    /// @notice The NFT does not exist for the given standard (ownerOf reverted, or an ERC-1155 id with zero supply).
    error InvalidToken(address collection, uint256 tokenId);
    /// @notice The NFT exists but names nobody to pay (zero owner, or an ERC-1155 without a royalty receiver).
    error NoRecipient(address collection, uint256 tokenId);
    error FeeTooHigh(uint16 feeBps);
    error InvalidFeeRecipient(address recipient);

    /// @notice Tip the NFT `tokenId` of `collection` with `amount` of `token`. The recipient is resolved on-chain.
    function tip(address collection, Standard standard, uint256 tokenId, address token, uint256 amount) external;
    /// @notice Tip an account the caller names.
    function tipAccount(address token, address to, uint256 amount) external;

    /// @notice Who a tip of this NFT would pay right now; reverts the way `tip` would.
    function recipientOf(address collection, Standard standard, uint256 tokenId) external view returns (address);
    function feeBps() external view returns (uint16);
    function feeRecipient() external view returns (address);
}
