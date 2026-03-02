// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ServiceProvider} from "../src/swarms/ServiceProvider.sol";

contract ServiceProviderTest is Test {
    ServiceProvider provider;

    address alice = address(0xA);
    address bob = address(0xB);

    string constant URL_1 = "https://backend.swarm.example.com/api/v1";
    string constant URL_2 = "https://relay.nodle.network:8443";
    string constant URL_3 = "https://provider.third.io";

    event ProviderRegistered(address indexed owner, string url, uint256 indexed tokenId);
    event ProviderBurned(address indexed owner, uint256 indexed tokenId);

    function setUp() public {
        provider = new ServiceProvider();
    }

    // ==============================
    // registerProvider
    // ==============================

    function test_registerProvider_mintsAndStoresURL() public {
        vm.prank(alice);
        uint256 tokenId = provider.registerProvider(URL_1);

        assertEq(provider.ownerOf(tokenId), alice);
        assertEq(keccak256(bytes(provider.providerUrls(tokenId))), keccak256(bytes(URL_1)));
    }

    function test_registerProvider_deterministicTokenId() public {
        vm.prank(alice);
        uint256 tokenId = provider.registerProvider(URL_1);

        assertEq(tokenId, uint256(keccak256(bytes(URL_1))));
    }

    function test_registerProvider_emitsEvent() public {
        uint256 expectedTokenId = uint256(keccak256(bytes(URL_1)));

        vm.expectEmit(true, true, true, true);
        emit ProviderRegistered(alice, URL_1, expectedTokenId);

        vm.prank(alice);
        provider.registerProvider(URL_1);
    }

    function test_registerProvider_multipleProviders() public {
        vm.prank(alice);
        uint256 id1 = provider.registerProvider(URL_1);

        vm.prank(bob);
        uint256 id2 = provider.registerProvider(URL_2);

        assertEq(provider.ownerOf(id1), alice);
        assertEq(provider.ownerOf(id2), bob);
        assertTrue(id1 != id2);
    }

    function test_RevertIf_registerProvider_emptyURL() public {
        vm.prank(alice);
        vm.expectRevert(ServiceProvider.EmptyURL.selector);
        provider.registerProvider("");
    }

    function test_RevertIf_registerProvider_duplicateURL() public {
        vm.prank(alice);
        provider.registerProvider(URL_1);

        vm.prank(bob);
        vm.expectRevert(); // ERC721: token already minted
        provider.registerProvider(URL_1);
    }

    // ==============================
    // burn
    // ==============================

    function test_burn_deletesURLAndToken() public {
        vm.prank(alice);
        uint256 tokenId = provider.registerProvider(URL_1);

        vm.prank(alice);
        provider.burn(tokenId);

        // URL mapping cleared
        assertEq(bytes(provider.providerUrls(tokenId)).length, 0);

        // Token no longer exists
        vm.expectRevert(); // ownerOf reverts for non-existent token
        provider.ownerOf(tokenId);
    }

    function test_burn_emitsEvent() public {
        vm.prank(alice);
        uint256 tokenId = provider.registerProvider(URL_1);

        vm.expectEmit(true, true, true, true);
        emit ProviderBurned(alice, tokenId);

        vm.prank(alice);
        provider.burn(tokenId);
    }

    function test_RevertIf_burn_notOwner() public {
        vm.prank(alice);
        uint256 tokenId = provider.registerProvider(URL_1);

        vm.prank(bob);
        vm.expectRevert(ServiceProvider.NotTokenOwner.selector);
        provider.burn(tokenId);
    }

    function test_burn_allowsReregistration() public {
        vm.prank(alice);
        uint256 tokenId = provider.registerProvider(URL_1);

        vm.prank(alice);
        provider.burn(tokenId);

        // Same URL can now be registered by someone else
        vm.prank(bob);
        uint256 newTokenId = provider.registerProvider(URL_1);

        assertEq(newTokenId, tokenId); // Same deterministic ID
        assertEq(provider.ownerOf(newTokenId), bob);
    }

    // ==============================
    // Fuzz Tests
    // ==============================

    function testFuzz_registerProvider_anyValidURL(string calldata url) public {
        vm.assume(bytes(url).length > 0);

        vm.prank(alice);
        uint256 tokenId = provider.registerProvider(url);

        assertEq(tokenId, uint256(keccak256(bytes(url))));
        assertEq(provider.ownerOf(tokenId), alice);
    }

    function testFuzz_burn_onlyOwner(address caller) public {
        vm.assume(caller != alice);
        vm.assume(caller != address(0));

        vm.prank(alice);
        uint256 tokenId = provider.registerProvider(URL_1);

        vm.prank(caller);
        vm.expectRevert(ServiceProvider.NotTokenOwner.selector);
        provider.burn(tokenId);
    }
}
