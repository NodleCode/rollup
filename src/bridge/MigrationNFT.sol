// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity 0.8.23;

import {ERC721} from "openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";
import {Strings} from "openzeppelin-contracts/contracts/utils/Strings.sol";
import {NODLMigration} from "./NODLMigration.sol";

contract MigrationNFT is ERC721 {
    using Strings for uint256;

    uint256 public nextTokenId;
    uint256 public maxHolders;
    NODLMigration public migration;

    string internal tokensURIRoot;

    uint256[] public levels;
    mapping(uint256 => uint256) public tokenIdToLevel;
    mapping(address => uint256) public holderToLevel;

    uint256 public individualHolders;
    mapping(bytes32 => bool) public claimed;

    error TooManyHolders();
    error AlreadyClaimed();
    error NoLevelUp();
    error ProposalDoesNotExist();
    error NotExecuted();
    error Soulbound();

    /**
     * @notice Construct a new MigrationNFT contract
     * @param _migration the NODLMigration contract to bridge tokens
     * @param _maxHolders the maximum number of holders for the NFTs
     * @param _tokensURIRoot the URI of the metadata folder for the NFTs
     * @param _levels an array representing the different reward levels expressed in
     *                the amount of tokens needed to get the NFT
     */
    constructor(NODLMigration _migration, uint256 _maxHolders, string memory _tokensURIRoot, uint256[] memory _levels)
        ERC721("OG ZK NODL", "OG_ZK_NODL")
    {
        migration = _migration;
        maxHolders = _maxHolders;
        tokensURIRoot = _tokensURIRoot;
        levels = _levels;

        for (uint256 i = 1; i < levels.length; i++) {
            assert(levels[i] > levels[i - 1]);
        }
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
        _mustNotHaveBeenClaimed(txHash);

        (address target, uint256 amount,,, bool executed) = migration.proposals(txHash);

        _mustBeAnExistingProposal(target);
        _mustBeExecuted(executed);
        bool alreadyHolder = _mustAlreadyBeHolderOrEnougHoldersRemaining(target);

        (uint256[] memory levelsToMint, uint256 nbLevelsToMint) = _computeLevelUps(target, amount);

        claimed[txHash] = true;
        if (!alreadyHolder) {
            individualHolders++;
        }

        for (uint256 i = 0; i < nbLevelsToMint; i++) {
            uint256 tokenId = nextTokenId++;
            tokenIdToLevel[tokenId] = levelsToMint[i] + 1;
            holderToLevel[target] = levelsToMint[i] + 1;
            _safeMint(target, tokenId);
        }
    }

    function _computeLevelUps(address target, uint256 amount)
        internal
        view
        returns (uint256[] memory levelsToMint, uint256 nbLevelsToMint)
    {
        levelsToMint = new uint256[](levels.length);
        nbLevelsToMint = 0;

        // We effectively iterate over all the levels the `target` has YET
        // to qualify for. This expressively skips levels the `target` has
        // already qualified for.
        uint256 currentLevel = holderToLevel[target];
        for (uint256 i = currentLevel; i < levels.length; i++) {
            if (amount >= levels[i]) {
                levelsToMint[i - currentLevel] = i;
                nbLevelsToMint++;
            }
        }

        if (nbLevelsToMint == 0) {
            revert NoLevelUp();
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

    function _mustAlreadyBeHolderOrEnougHoldersRemaining(address target) internal view returns (bool alreadyHolder) {
        alreadyHolder = balanceOf(target) > 0;
        if (!alreadyHolder && individualHolders == maxHolders) {
            revert TooManyHolders();
        }
    }

    function _update(address to, uint256 tokenId, address auth) internal override(ERC721) returns (address) {
        address from = _ownerOf(tokenId);
        if (from != address(0) && to != address(0)) {
            // only burn or mint is allowed for a soulbound token
            revert Soulbound();
        }

        return super._update(to, tokenId, auth);
    }
}
