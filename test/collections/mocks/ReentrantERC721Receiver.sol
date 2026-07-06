// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

interface IMintable721 {
    function mint(address to, string calldata uri) external returns (uint256);
}

/// @notice Test-only ERC-721 receiver that reenters `mint` exactly once on its
///         first `onERC721Received` callback. Used to prove that
///         `UserCollection721.mintBatch` reserves its ID range BEFORE the mint
///         loop, so a reentrant mint takes a fresh ID instead of colliding (see
///         F5 hardening). Under the old stale-counter ordering the reentrant
///         mint would have reverted with "token already minted", reverting the
///         whole batch.
contract ReentrantERC721Receiver is IERC721Receiver {
    IMintable721 public collection;
    bool public reentered;
    uint256 public reentrantTokenId;

    function setCollection(IMintable721 c) external {
        collection = c;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        if (!reentered && address(collection) != address(0)) {
            reentered = true;
            reentrantTokenId = collection.mint(address(this), "reentrant.json");
        }
        return IERC721Receiver.onERC721Received.selector;
    }
}
