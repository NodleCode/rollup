// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";

import {ICollectionFactory} from "../src/collections/interfaces/ICollectionFactory.sol";
import {IUserCollection1155} from "../src/collections/interfaces/IUserCollection1155.sol";
import {CreateParams1155} from "../src/collections/interfaces/CollectionTypes.sol";

/**
 * @title CreateCollection1155ZkSync
 * @notice Operator action: create one ERC-1155 user collection via the factory.
 * @dev See `src/collections/doc/backend-integration.md` (§2).
 *
 *      The broadcasting key MUST hold `OPERATOR_ROLE` on the factory proxy.
 *      The collection is created with NO admin; `owner` receives `OWNER_ROLE`
 *      (+ `MINTER_ROLE`) and the operator is auto-granted `MINTER_ROLE`.
 *
 *      After creating the collection, this script mints the edition in the
 *      same broadcast: the operator is auto-granted `MINTER_ROLE`, so it can
 *      `mint(to, id, amount, data)` immediately on the new collection.
 *
 * Usage:
 *   forge script script/CreateCollection1155ZkSync.s.sol \
 *       --rpc-url $L2_RPC --broadcast --zksync
 *
 * Environment Variables:
 *   - OPERATOR_PRIVATE_KEY   Key holding OPERATOR_ROLE on the factory (pays gas).
 *   - COLLECTION_FACTORY_PROXY   Factory ERC1967 proxy address.
 *   - COLLECTION_OWNER       Creator wallet — receives OWNER_ROLE + MINTER_ROLE.
 *   - TOKEN_URI              ERC-1155 token-metadata JSON URI (e.g. ipfs://<cid>).
 *   - CONTRACT_URI           Collection-metadata JSON URI (e.g. ipfs://<cid>).
 *   - EXTERNAL_ID_SEED       Non-empty string; hashed to the bytes32 externalId.
 *   - ROYALTY_RECIPIENT      (optional) ERC-2981 recipient. Default: address(0).
 *   - ROYALTY_BPS            (optional) basis points (500 = 5%). Default: 0 (none).
 *   - MINT_TO                (optional) recipient of the minted edition. Default: COLLECTION_OWNER.
 *   - TOKEN_ID               (optional) ERC-1155 id to mint. Default: 0.
 *   - MINT_AMOUNT            quantity to mint (e.g. 1 for a 1/1, 10000 for an edition).
 */
contract CreateCollection1155ZkSync is Script {
    function run() external {
        uint256 operatorKey = vm.envUint("OPERATOR_PRIVATE_KEY");
        address factory = vm.envAddress("COLLECTION_FACTORY_PROXY");
        address owner = vm.envAddress("COLLECTION_OWNER");
        string memory tokenURI = vm.envString("TOKEN_URI");
        string memory contractURI = vm.envString("CONTRACT_URI");
        string memory externalIdSeed = vm.envString("EXTERNAL_ID_SEED");

        address royaltyRecipient = vm.envOr("ROYALTY_RECIPIENT", address(0));
        uint96 royaltyBps = uint96(vm.envOr("ROYALTY_BPS", uint256(0)));

        address mintTo = vm.envOr("MINT_TO", owner);
        uint256 tokenId = vm.envOr("TOKEN_ID", uint256(0));
        uint256 mintAmount = vm.envUint("MINT_AMOUNT");

        require(factory != address(0), "COLLECTION_FACTORY_PROXY is zero");
        require(owner != address(0), "COLLECTION_OWNER is zero");
        require(bytes(externalIdSeed).length > 0, "EXTERNAL_ID_SEED is empty");
        require(mintAmount > 0, "MINT_AMOUNT must be > 0");
        // Fail-closed: a non-zero royalty with a zero recipient reverts in init.
        require(royaltyBps == 0 || royaltyRecipient != address(0), "royalty recipient required");

        bytes32 externalId = keccak256(bytes(externalIdSeed));

        address[] memory additionalMinters = new address[](0);
        CreateParams1155 memory p = CreateParams1155({
            owner: owner,
            uri: tokenURI,
            contractURI: contractURI,
            royaltyRecipient: royaltyRecipient,
            royaltyBps: royaltyBps,
            additionalMinters: additionalMinters
        });

        console.log("=== Creating ERC-1155 Collection ===");
        console.log("Factory:", factory);
        console.log("Owner:", owner);
        console.log("Token URI:", tokenURI);
        console.log("Contract URI:", contractURI);
        console.log("Royalty recipient:", royaltyRecipient);
        console.log("Royalty bps:", royaltyBps);
        console.logBytes32(externalId);
        console.log("");

        console.log("Mint to:", mintTo);
        console.log("Token id:", tokenId);
        console.log("Mint amount:", mintAmount);
        console.log("");

        vm.startBroadcast(operatorKey);
        address collection = ICollectionFactory(factory).createCollection1155(p, externalId);
        IUserCollection1155(collection).mint(mintTo, tokenId, mintAmount, "");
        vm.stopBroadcast();

        console.log("=== Created + Minted ===");
        console.log("Collection:", collection);
        console.log("Verify: factory.collectionByExternalId(externalId) == above");
    }
}
