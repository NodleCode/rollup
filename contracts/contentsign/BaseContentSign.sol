// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity 0.8.23;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721URIStorage} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";

import {WhitelistPaymaster} from "../paymasters/WhitelistPaymaster.sol";

/// @notice a simple NFT contract for contentsign data where each nft is mapped to a one-time
/// configurable URL. This is used for every variant of ContentSign with associated hooks.
abstract contract BaseContentSign is ERC721, ERC721URIStorage {
    uint256 public nextTokenId;

    error UserIsNotWhitelisted(address user);

    constructor(string memory name, string memory symbol) ERC721(name, symbol) {}

    function safeMint(address to, string memory uri) public {
        _mustBeWhitelisted();

        uint256 tokenId = nextTokenId++;
        _safeMint(to, tokenId);
        _setTokenURI(tokenId, uri);
    }

    function tokenURI(uint256 tokenId) public view override(ERC721, ERC721URIStorage) returns (string memory) {
        return super.tokenURI(tokenId);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(ERC721, ERC721URIStorage)
        returns (bool)
    {
        return ERC721.supportsInterface(interfaceId) || ERC721URIStorage.supportsInterface(interfaceId);
    }

    function _mustBeWhitelisted() internal view {
        if (!_userIsWhitelisted(msg.sender)) {
            revert UserIsNotWhitelisted(msg.sender);
        }
    }

    function _userIsWhitelisted(address user) internal view virtual returns (bool);
}
