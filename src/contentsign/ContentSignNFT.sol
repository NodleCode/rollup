// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.20;

import {ERC721} from "openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";
import {ERC721URIStorage} from "openzeppelin-contracts/contracts/token/ERC721/extensions/ERC721URIStorage.sol";

import {WhitelistPaymaster} from "../paymasters/WhitelistPaymaster.sol";

/// @notice a simple NFT contract for contentsign data where each nft is mapped to a one-time
/// configurable URL
contract ContentSignNFT is ERC721, ERC721URIStorage {
    uint256 public nextTokenId;
    WhitelistPaymaster public whitelistPaymaster;

    error UserIsNotWhitelisted();

    constructor(string memory name, string memory symbol, WhitelistPaymaster whitelist) ERC721(name, symbol) {
        whitelistPaymaster = whitelist;
    }

    function safeMint(address to, string memory uri) public {
        _mustBeWhitelisted();

        uint256 tokenId = nextTokenId++;
        _safeMint(to, tokenId);
        _setTokenURI(tokenId, uri);
    }

    function tokenURI(uint256 tokenId) public view override(ERC721, ERC721URIStorage) returns (string memory) {
        return super.tokenURI(tokenId);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721, ERC721URIStorage) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    function _mustBeWhitelisted() internal view {
        if (!whitelistPaymaster.isWhitelistedUser(msg.sender)) {
            revert UserIsNotWhitelisted();
        }
    }
}
