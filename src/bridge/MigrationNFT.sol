// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity 0.8.23;

import {ERC721} from "openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";
import {Strings} from "openzeppelin-contracts/contracts/utils/Strings.sol";
import {NODLMigration} from "./NODLMigration.sol";

contract MigrationNFT is ERC721 {
    using Strings for uint256;

    uint256 public nextTokenId;
    uint256 public maxNFTs;
    NODLMigration public migration;

    string internal tokensURIRoot;

    uint256[] public levels;
    mapping(uint256 => uint256) public tokenIdToLevel;

    mapping(bytes32 => bool) public claimed;

    error TooManyNFTs();
    error AlreadyClaimed();
    error ProposalDoesNotExist();
    error NotExecuted();
    error AlreadyAHolder();

    /**
     * @notice Construct a new MigrationNFT contract
     * @param _migration the NODLMigration contract to bridge tokens
     * @param _maxNFTs the maximum number of NFTs to be minted
     * @param _tokensURIRoot the URI of the metadata folder for the NFTs
     * @param _levels an array representing the different reward levels expressed in
     *                the amount of tokens needed to get the NFT
     */
    constructor(NODLMigration _migration, uint256 _maxNFTs, string memory _tokensURIRoot, uint256[] memory _levels)
        ERC721("OG ZK NODL", "OG_ZK_NODL")
    {
        migration = _migration;
        maxNFTs = _maxNFTs;
        tokensURIRoot = _tokensURIRoot;
        levels = _levels;
    }

    /**
     * @notice Return the URI of the proper metadata for the given token ID
     * @param tokenId the token ID to mint
     */
    function tokenURI(uint256 tokenId) public view virtual override(ERC721) returns (string memory) {
        _requireOwned(tokenId);

        uint256 level = tokenIdToLevel[tokenId];
        return string.concat(tokensURIRoot, "/", level.toString());
    }

    /**
     * @notice Mint a new NFT for the given user
     * @param txHash the transaction hash to bridge
     */
    function safeMint(bytes32 txHash) public {
        _mustHaveEnoughNFTsRemaining();
        _mustNotHaveBeenClaimed(txHash);

        (address target, uint256 amount,,, bool executed) = migration.proposals(txHash);

        _mustBeAnExistingProposal(target);
        _mustBeExecuted(executed);
        _mustNotBeAlreadyAHolder(target);

        uint256 tokenId = nextTokenId++;
        _markAsClaimed(txHash);
        _safeMint(target, tokenId);
    }

    /**
     * @notice Mint a batch of NFTs for all the provided transaction hashes
     * @param txHashes the transaction hashes to mint NFTs for
     */
    function safeMintBatch(bytes32[] memory txHashes) public {
        for (uint256 i = 0; i < txHashes.length; i++) {
            safeMint(txHashes[i]);
        }
    }

    function _markAsClaimed(bytes32 txHash) internal {
        claimed[txHash] = true;
    }

    function _mustHaveEnoughNFTsRemaining() internal view {
        if (nextTokenId >= maxNFTs) {
            revert TooManyNFTs();
        }
    }

    function _mustNotHaveBeenClaimed(bytes32 txHash) internal view {
        if (claimed[txHash]) {
            revert AlreadyClaimed();
        }
    }

    function _mustBeAnExistingProposal(address target) internal pure {
        // the relayers skip any transfers to the 0 address
        if (target == address(0)) {
            revert ProposalDoesNotExist();
        }
    }

    function _mustBeExecuted(bool executed) internal pure {
        if (!executed) {
            revert NotExecuted();
        }
    }

    function _mustNotBeAlreadyAHolder(address target) internal view {
        if (balanceOf(target) > 0) {
            revert AlreadyAHolder();
        }
    }
}
