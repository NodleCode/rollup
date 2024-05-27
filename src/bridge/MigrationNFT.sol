// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity 0.8.23;

import {ERC721} from "openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";
import {NODLMigration} from "./NODLMigration.sol";

contract MigrationNFT is ERC721 {
    uint256 public nextTokenId;
    uint256 public maxHolders;
    uint256 public minAmount;
    NODLMigration public migration;

    string internal tokensURI;

    /**
     * @notice Construct a new MigrationNFT contract
     * @param _migration the NODLMigration contract to bridge tokens
     * @param _maxHolders the maximum number of holders for this NFT
     * @param _minAmount the minimum amount of tokens to bridge to get this NFT
     */
    constructor(NODLMigration _migration, uint256 _maxHolders, uint256 _minAmount, string memory _tokensURI)
        ERC721("Nodle OGs", "NODL_OGS")
    {
        migration = _migration;
        maxHolders = _maxHolders;
        minAmount = _minAmount;
        tokensURI = _tokensURI;
    }

    /**
     * @notice Return the URI of the proper metadata for the given token ID
     * @param tokenId the token ID to mint
     */
    function tokenURI(uint256 tokenId) public view virtual override(ERC721) returns (string memory) {
        _requireOwned(tokenId);
        return tokensURI;
    }

    /**
     * @notice Mint a new NFT for the given user
     * @param txHash the transaction hash to bridge
     */
    function safeMint(bytes32 txHash) public {
        (address target, uint256 amount, uint256 lastVote, uint8 totalVotes, bool executed) =
            migration.proposals(txHash);

        // must be exeucted
        // must be above min amount
        // must have enough holders available
        // must not already be claimed
        // must not already be a holder

        uint256 tokenId = nextTokenId++;
        _safeMint(target, tokenId);

        // silence compiler unused variables
        lastVote;
        totalVotes;
    }

    // add batch mint function
}
