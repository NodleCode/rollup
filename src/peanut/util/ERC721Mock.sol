// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";

contract ERC721Mock is ERC721 {
    constructor() ERC721("Name", "MOCK") {
        this;
    }

    function mint(address account, uint256 tokenId) external {
        _mint(account, tokenId);
    }
}
