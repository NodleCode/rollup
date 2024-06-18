// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity 0.8.23;

import {ERC721} from "openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";
import {NODLMigration} from "./NODLMigration.sol";

contract MigrationNFT is ERC721 {
    uint256 public nextTokenId;
    uint256 public maxNFTs;
    uint256 public minAmount;
    NODLMigration public migration;

    string internal tokensURI;

    mapping(bytes32 => bool) public claimed;

    error TooManyNFTs();
    error AlreadyClaimed();
    error ProposalDoesNotExist();
    error UnderMinimumAmount();
    error NotExecuted();
    error AlreadyAHolder();

    /**
     * @notice Construct a new MigrationNFT contract
     * @param _migration the NODLMigration contract to bridge tokens
     * @param _maxNFTs the maximum number of NFTs to be minted
     * @param _minAmount the minimum amount of tokens to bridge to get this NFT
     */
    constructor(NODLMigration _migration, uint256 _maxNFTs, uint256 _minAmount, string memory _tokensURI)
        ERC721("OG ZK NODL", "OG_ZK_NODL")
    {
        migration = _migration;
        maxNFTs = _maxNFTs;
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
        _mustHaveEnoughNFTsRemaining();
        _mustNotHaveBeenClaimed(txHash);

        (address target, uint256 amount,,, bool executed) = migration.proposals(txHash);

        _mustBeAnExistingProposal(target);
        _mustBeAboveMinAmount(amount);
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
        // solidity initialize memory to 0s so we can check if the address is 0
        // since it is very unlikely that the address 0 is a valid target
        if (target == address(0)) {
            revert ProposalDoesNotExist();
        }
    }

    function _mustBeAboveMinAmount(uint256 amount) internal view {
        if (amount < minAmount) {
            revert UnderMinimumAmount();
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
