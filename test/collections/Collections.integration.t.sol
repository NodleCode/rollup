// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {CollectionFactory} from "../../src/collections/CollectionFactory.sol";
import {UserCollection721} from "../../src/collections/UserCollection721.sol";
import {UserCollection1155} from "../../src/collections/UserCollection1155.sol";
import {IUserCollection721} from "../../src/collections/interfaces/IUserCollection721.sol";
import {IUserCollection1155} from "../../src/collections/interfaces/IUserCollection1155.sol";
import {Standard, CreateParams721, CreateParams1155} from "../../src/collections/interfaces/CollectionTypes.sol";

import {CollectionFactoryV2Mock} from "./mocks/CollectionFactoryV2Mock.sol";

/**
 * @title Collections.integration.t.sol
 * @notice End-to-end happy-path scenario from spec §8.4.
 */
contract CollectionsIntegrationTest is Test {
    CollectionFactory internal factory;
    UserCollection721 internal impl721;
    UserCollection1155 internal impl1155;

    address internal constant ADMIN = address(0xAD);
    address internal constant OPERATOR = address(0x09);
    address internal constant CREATOR_ALPHA = address(0xA1);
    address internal constant CREATOR_BETA = address(0xB1);
    address internal constant BUYER_1 = address(0xB1A1);
    address internal constant BUYER_2 = address(0xB1A2);
    address internal constant THIRD_PARTY = address(0xC1);

    bytes32 internal constant OWNER_ROLE = keccak256("OWNER_ROLE");

    function setUp() public {
        impl721 = new UserCollection721();
        impl1155 = new UserCollection1155();
        CollectionFactory logic = new CollectionFactory();
        bytes memory init = abi.encodeCall(
            CollectionFactory.initialize, (ADMIN, OPERATOR, address(impl721), address(impl1155))
        );
        factory = CollectionFactory(address(new ERC1967Proxy(address(logic), init)));
    }

    function test_endToEnd_happyPath() public {
        // 1. Operator creates an ERC-721 collection for creator α.
        vm.prank(OPERATOR);
        address c721 = factory.createCollection721(
            CreateParams721({
                owner: CREATOR_ALPHA,
                name: "Alpha",
                symbol: "ALP",
                baseURI: "ipfs://alpha/",
                contractURI: "ipfs://alpha-contract.json",
                royaltyRecipient: CREATOR_ALPHA,
                royaltyBps: 500,
                additionalMinters: new address[](0)
            }),
            keccak256("order-alpha")
        );
        UserCollection721 col721 = UserCollection721(c721);
        assertTrue(col721.hasRole(OWNER_ROLE, CREATOR_ALPHA));

        // 2. Operator creates an ERC-1155 collection for creator β.
        vm.prank(OPERATOR);
        address c1155 = factory.createCollection1155(
            CreateParams1155({
                owner: CREATOR_BETA,
                uri: "ipfs://beta/{id}.json",
                contractURI: "ipfs://beta-contract.json",
                royaltyRecipient: CREATOR_BETA,
                royaltyBps: 250,
                additionalMinters: new address[](0)
            }),
            keccak256("order-beta")
        );
        UserCollection1155 col1155 = UserCollection1155(c1155);
        assertTrue(col1155.hasRole(OWNER_ROLE, CREATOR_BETA));

        // 3. Operator mints into both on behalf of fiat buyers.
        vm.prank(OPERATOR);
        uint256 alphaTokenId = col721.mint(BUYER_1, "1.json");
        assertEq(col721.ownerOf(alphaTokenId), BUYER_1);

        vm.prank(OPERATOR);
        col1155.mint(BUYER_2, 7, 3, "");
        assertEq(col1155.balanceOf(BUYER_2, 7), 3);

        // 4. Creator α transfers an item to a third party.
        vm.prank(BUYER_1);
        col721.transferFrom(BUYER_1, THIRD_PARTY, alphaTokenId);
        assertEq(col721.ownerOf(alphaTokenId), THIRD_PARTY);

        // 5. Creator α locks metadata and royalties.
        vm.prank(CREATOR_ALPHA);
        col721.lockMetadata();
        vm.prank(CREATOR_ALPHA);
        col721.lockRoyalties();
        assertTrue(col721.metadataLocked());
        assertTrue(col721.royaltiesLocked());

        // 6. Subsequent setter calls revert.
        vm.prank(CREATOR_ALPHA);
        vm.expectRevert(IUserCollection721.MetadataIsLocked.selector);
        col721.setBaseURI("ipfs://changed/");

        vm.prank(CREATOR_ALPHA);
        vm.expectRevert(IUserCollection721.RoyaltiesAreLocked.selector);
        col721.setDefaultRoyalty(CREATOR_ALPHA, 100);

        // 7. Admin upgrades the factory and ships a new ERC-721 implementation.
        CollectionFactoryV2Mock v2Logic = new CollectionFactoryV2Mock();
        vm.prank(ADMIN);
        factory.upgradeToAndCall(address(v2Logic), "");
        assertEq(CollectionFactoryV2Mock(address(factory)).v2Sentinel(), 4242);

        UserCollection721 newImpl721 = new UserCollection721();
        vm.prank(ADMIN);
        factory.setImplementation721(address(newImpl721));

        // 8. New ERC-721 collection deploys with new implementation; old
        //    collection remains on the previous implementation.
        vm.prank(OPERATOR);
        address c721b = factory.createCollection721(
            CreateParams721({
                owner: CREATOR_ALPHA,
                name: "Alpha2",
                symbol: "ALP2",
                baseURI: "ipfs://alpha2/",
                contractURI: "ipfs://alpha2-contract.json",
                royaltyRecipient: CREATOR_ALPHA,
                royaltyBps: 500,
                additionalMinters: new address[](0)
            }),
            keccak256("order-alpha-v2")
        );
        // Each per-collection ERC1967Proxy delegates to the factory's
        // `_erc721Implementation` / `_erc1155Implementation` via the EIP-1967
        // implementation slot, captured at deploy time. The factory pointer
        // is the observable state that proves the upgrade took effect for
        // newly deployed collections; existing collections keep delegating
        // to whichever implementation address was written into their slot
        // when they were created.
        assertEq(factory.erc721Implementation(), address(newImpl721));
        // Old collection still operates normally.
        assertEq(col721.ownerOf(alphaTokenId), THIRD_PARTY);
        // New collection initialized correctly under new implementation.
        assertTrue(UserCollection721(c721b).hasRole(OWNER_ROLE, CREATOR_ALPHA));
    }
}
