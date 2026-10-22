// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.26;

/**
 * @title ITipping
 * @notice NODL tips on NFTs with on-chain recipient resolution. The event and error surface
 *         is what the feed indexer consumes (nft-feed-indexer design §6.2); keep it stable.
 */
interface ITipping {
    /// @notice A tip was paid. `amount` is gross (what the tipper gave); `fee` went to the fee recipient.
    event Tipped(
        address indexed tipper,
        address indexed collection,
        uint256 indexed tokenId,
        address recipient,
        uint256 amount,
        uint256 fee
    );
    /// @notice A ContentSign-type collection was added to or removed from the allowlist.
    event CollectionAllowed(address indexed collection, bool allowed);
    /// @notice The registered creator of a factory collection changed (zero clears the entry).
    event CreatorSet(address indexed collection, address indexed creator);
    event MinTipUpdated(uint256 minTipAmount);
    event FeeUpdated(uint16 feeBps);
    event FeeRecipientUpdated(address indexed feeRecipient);
    // `Paused(address)` / `Unpaused(address)` come from OpenZeppelin Pausable and are part of
    // the indexed surface too; do not strip them from the generated ABI.

    error ZeroAddress();
    error BelowMinimum(uint256 amount, uint256 minTipAmount);
    error SelfTip();
    error UnknownCollection(address collection);
    error UnknownToken(address collection, uint256 tokenId);
    error NoRecipient(address collection, uint256 tokenId);
    error NotCollectionOwner(address collection, address account);
    error FeeTooHigh(uint16 feeBps);
    error AlreadyRegistered(address collection);
    error InvalidFeeRecipient(address recipient);

    function tip(address collection, uint256 tokenId, uint256 amount) external;
    function registerCollection(address collection) external;
    function resolveRecipient(address collection, uint256 tokenId) external view returns (address);

    function nodl() external view returns (address);
    function minTipAmount() external view returns (uint256);
    function feeBps() external view returns (uint16);
    function feeRecipient() external view returns (address);
    function contentSignAllowed(address collection) external view returns (bool);
    function creatorOf(address collection) external view returns (address);
}
