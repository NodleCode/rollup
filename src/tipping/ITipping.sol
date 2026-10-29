// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.26;

/**
 * @title ITipping
 * @notice Interface of Nodle Tipping v2: tip an NFT post or an account with any ERC-20.
 *         A post tip names its recipient and the contract verifies the claim against the NFT
 *         (ERC-721 owner; ERC-1155 collection owner role, Ownable owner or ERC-2981 receiver).
 *         No backend signature, no allowlist, no pause. Keep the event surface stable: the
 *         Nodle feed indexer consumes it.
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
    /// @notice Accrued fees in `token` were sent to the fee recipient.
    event FeesWithdrawn(address indexed token, address indexed to, uint256 amount);

    error ZeroAddress();
    error ZeroAmount();
    error SelfTip();
    error NotAContract(address collection);
    /// @notice The NFT does not exist for the given standard (ownerOf reverted, or an ERC-1155 id with zero supply).
    error InvalidToken(address collection, uint256 tokenId);
    /// @notice The named recipient is not the NFT's owner (ERC-721) nor the collection's owner / royalty receiver (ERC-1155).
    error NotRecipient(address collection, uint256 tokenId, address recipient);
    error FeeTooHigh(uint16 feeBps);
    error InvalidFeeRecipient(address recipient);

    /// @notice Tip the NFT `tokenId` of `collection`: `recipient` is verified against the NFT, then paid `amount` of `token`.
    function tip(address collection, Standard standard, uint256 tokenId, address recipient, address token, uint256 amount)
        external;
    /// @notice Tip an account the caller names.
    function tipAccount(address token, address to, uint256 amount) external;

    /// @notice Whether `tip` would accept `recipient` for this NFT; reverts for a non-contract or an invalid token, like `tip`.
    function isRecipient(address collection, Standard standard, uint256 tokenId, address recipient)
        external
        view
        returns (bool);
    /// @notice Send everything this contract holds in `token` (accrued fees) to the fee recipient. Anyone may call.
    function withdrawFees(address token) external;

    function feeBps() external view returns (uint16);
    function feeRecipient() external view returns (address);
}
