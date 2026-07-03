// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {BatchMintNFT} from "../../src/contentsign/BatchMintNFT.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

contract BatchMintNFTTest is Test {
    BatchMintNFT private implementation;
    BatchMintNFT private nft;
    ERC1967Proxy private proxy;

    address internal admin = vm.addr(1);
    address internal alice = vm.addr(2);
    address internal bob = vm.addr(3);
    address internal charlie = vm.addr(4);

    function setUp() public {
        // Deploy implementation
        implementation = new BatchMintNFT();

        // Encode initialize function call
        bytes memory initData = abi.encodeWithSelector(
            BatchMintNFT.initialize.selector,
            "BatchMintNFT",
            "BMNFT",
            admin
        );

        // Deploy proxy with initialization
        proxy = new ERC1967Proxy(address(implementation), initData);

        // Attach to proxy
        nft = BatchMintNFT(address(proxy));
    }

    function test_initialization() public view {
        assertEq(nft.name(), "BatchMintNFT");
        assertEq(nft.symbol(), "BMNFT");
        assertEq(nft.nextTokenId(), 0);
        assertTrue(nft.hasRole(nft.DEFAULT_ADMIN_ROLE(), admin));
    }

    function test_publicMint() public {
        vm.prank(alice);
        nft.safeMint(alice, "ipfs://uri1");

        assertEq(nft.ownerOf(0), alice);
        assertEq(nft.tokenURI(0), "ipfs://uri1");
        assertEq(nft.nextTokenId(), 1);
    }

    function test_publicMintMultiple() public {
        vm.prank(alice);
        nft.safeMint(alice, "ipfs://uri1");

        vm.prank(bob);
        nft.safeMint(bob, "ipfs://uri2");

        assertEq(nft.ownerOf(0), alice);
        assertEq(nft.ownerOf(1), bob);
        assertEq(nft.tokenURI(0), "ipfs://uri1");
        assertEq(nft.tokenURI(1), "ipfs://uri2");
        assertEq(nft.nextTokenId(), 2);
    }

    function test_batchMint() public {
        address[] memory recipients = new address[](3);
        recipients[0] = alice;
        recipients[1] = bob;
        recipients[2] = charlie;

        string[] memory uris = new string[](3);
        uris[0] = "ipfs://uri1";
        uris[1] = "ipfs://uri2";
        uris[2] = "ipfs://uri3";

        vm.prank(alice);
        nft.batchSafeMint(recipients, uris);

        assertEq(nft.ownerOf(0), alice);
        assertEq(nft.ownerOf(1), bob);
        assertEq(nft.ownerOf(2), charlie);
        assertEq(nft.tokenURI(0), "ipfs://uri1");
        assertEq(nft.tokenURI(1), "ipfs://uri2");
        assertEq(nft.tokenURI(2), "ipfs://uri3");
        assertEq(nft.nextTokenId(), 3);
    }

    function test_batchMintUnequalLengths() public {
        address[] memory recipients = new address[](2);
        recipients[0] = alice;
        recipients[1] = bob;

        string[] memory uris = new string[](3);
        uris[0] = "ipfs://uri1";
        uris[1] = "ipfs://uri2";
        uris[2] = "ipfs://uri3";

        vm.expectRevert(BatchMintNFT.UnequalLengths.selector);
        vm.prank(alice);
        nft.batchSafeMint(recipients, uris);
    }

    function test_batchMintEmptyArrays() public {
        address[] memory recipients = new address[](0);
        string[] memory uris = new string[](0);

        vm.prank(alice);
        nft.batchSafeMint(recipients, uris);

        assertEq(nft.nextTokenId(), 0);
    }

    function test_mixedMintAndBatch() public {
        // First mint individually
        vm.prank(alice);
        nft.safeMint(alice, "ipfs://uri1");

        // Then batch mint
        address[] memory recipients = new address[](2);
        recipients[0] = bob;
        recipients[1] = charlie;

        string[] memory uris = new string[](2);
        uris[0] = "ipfs://uri2";
        uris[1] = "ipfs://uri3";

        vm.prank(bob);
        nft.batchSafeMint(recipients, uris);

        assertEq(nft.ownerOf(0), alice);
        assertEq(nft.ownerOf(1), bob);
        assertEq(nft.ownerOf(2), charlie);
        assertEq(nft.nextTokenId(), 3);
    }

    function test_adminCanUpgrade() public {
        // Deploy new implementation
        BatchMintNFT newImplementation = new BatchMintNFT();

        // Admin can upgrade using upgradeTo (no call data needed)
        vm.prank(admin);
        nft.upgradeTo(address(newImplementation));

        // Verify the contract still works after upgrade
        vm.prank(alice);
        nft.safeMint(alice, "ipfs://uri1");
        assertEq(nft.ownerOf(0), alice);
    }

    function test_nonAdminCannotUpgrade() public {
        BatchMintNFT newImplementation = new BatchMintNFT();

        // AccessControl v4.9.0 emits a string error, not a custom error
        vm.expectRevert();
        vm.prank(alice);
        nft.upgradeTo(address(newImplementation));
    }

    function test_supportsInterface() public view {
        // ERC721 interface
        assertTrue(nft.supportsInterface(0x80ac58cd));
        // ERC721Metadata interface
        assertTrue(nft.supportsInterface(0x5b5e139f));
        // AccessControl interface
        assertTrue(nft.supportsInterface(0x7965db0b));
    }

    function test_balanceOf() public {
        vm.prank(alice);
        nft.safeMint(alice, "ipfs://uri1");

        vm.prank(alice);
        nft.safeMint(alice, "ipfs://uri2");

        assertEq(nft.balanceOf(alice), 2);
        assertEq(nft.balanceOf(bob), 0);
    }

    function test_batchMintToSameAddress() public {
        address[] memory recipients = new address[](3);
        recipients[0] = alice;
        recipients[1] = alice;
        recipients[2] = alice;

        string[] memory uris = new string[](3);
        uris[0] = "ipfs://uri1";
        uris[1] = "ipfs://uri2";
        uris[2] = "ipfs://uri3";

        vm.prank(alice);
        nft.batchSafeMint(recipients, uris);

        assertEq(nft.balanceOf(alice), 3);
        assertEq(nft.ownerOf(0), alice);
        assertEq(nft.ownerOf(1), alice);
        assertEq(nft.ownerOf(2), alice);
    }

    // ============================================
    // Security Tests - Zero Address Validation
    // ============================================

    function test_initializeRevertsWithZeroAddress() public {
        BatchMintNFT newImpl = new BatchMintNFT();
        bytes memory initData = abi.encodeWithSelector(
            BatchMintNFT.initialize.selector,
            "Test",
            "TEST",
            address(0)
        );

        vm.expectRevert(BatchMintNFT.ZeroAddress.selector);
        new ERC1967Proxy(address(newImpl), initData);
    }

    function test_safeMintRevertsWithZeroAddress() public {
        vm.expectRevert(BatchMintNFT.ZeroAddress.selector);
        vm.prank(alice);
        nft.safeMint(address(0), "ipfs://uri1");
    }

    function test_batchSafeMintRevertsWithZeroAddress() public {
        address[] memory recipients = new address[](2);
        recipients[0] = alice;
        recipients[1] = address(0); // Zero address

        string[] memory uris = new string[](2);
        uris[0] = "ipfs://uri1";
        uris[1] = "ipfs://uri2";

        vm.expectRevert(BatchMintNFT.ZeroAddress.selector);
        vm.prank(alice);
        nft.batchSafeMint(recipients, uris);
    }

    // ============================================
    // Security Tests - URI Validation
    // ============================================

    function test_safeMintRevertsWithEmptyURI() public {
        vm.expectRevert(BatchMintNFT.EmptyURI.selector);
        vm.prank(alice);
        nft.safeMint(alice, "");
    }

    function test_batchSafeMintRevertsWithEmptyURI() public {
        address[] memory recipients = new address[](2);
        recipients[0] = alice;
        recipients[1] = bob;

        string[] memory uris = new string[](2);
        uris[0] = "ipfs://uri1";
        uris[1] = ""; // Empty URI

        vm.expectRevert(BatchMintNFT.EmptyURI.selector);
        vm.prank(alice);
        nft.batchSafeMint(recipients, uris);
    }

    // ============================================
    // Security Tests - Batch Size Limit
    // ============================================

    function test_batchSafeMintRevertsWhenExceedingMaxBatchSize() public {
        uint256 maxSize = nft.MAX_BATCH_SIZE();
        address[] memory recipients = new address[](maxSize + 1);
        string[] memory uris = new string[](maxSize + 1);

        for (uint256 i = 0; i < maxSize + 1; ) {
            recipients[i] = vm.addr(i + 10);
            uris[i] = "ipfs://uri";
            unchecked {
                ++i;
            }
        }

        vm.expectRevert(BatchMintNFT.BatchTooLarge.selector);
        vm.prank(alice);
        nft.batchSafeMint(recipients, uris);
    }

    function test_batchSafeMintSucceedsAtMaxBatchSize() public {
        uint256 maxSize = nft.MAX_BATCH_SIZE();
        address[] memory recipients = new address[](maxSize);
        string[] memory uris = new string[](maxSize);

        for (uint256 i = 0; i < maxSize; ) {
            recipients[i] = vm.addr(i + 10);
            uris[i] = "ipfs://uri";
            unchecked {
                ++i;
            }
        }

        vm.prank(alice);
        nft.batchSafeMint(recipients, uris);

        assertEq(nft.nextTokenId(), maxSize);
    }

    // ============================================
    // Security Tests - Re-initialization
    // ============================================

    function test_initializeCannotBeCalledTwice() public {
        vm.expectRevert();
        nft.initialize("NewName", "NEW", admin);
    }

    // ============================================
    // Upgrade Tests - State Preservation
    // ============================================

    function test_upgradePreservesState() public {
        // Mint some tokens before upgrade
        vm.prank(alice);
        nft.safeMint(alice, "ipfs://uri1");

        vm.prank(bob);
        nft.safeMint(bob, "ipfs://uri2");

        address[] memory recipients = new address[](2);
        recipients[0] = charlie;
        recipients[1] = admin;

        string[] memory uris = new string[](2);
        uris[0] = "ipfs://uri3";
        uris[1] = "ipfs://uri4";

        vm.prank(charlie);
        nft.batchSafeMint(recipients, uris);

        uint256 tokenCountBefore = nft.nextTokenId();
        assertEq(tokenCountBefore, 4);

        // Perform upgrade
        BatchMintNFT newImplementation = new BatchMintNFT();
        vm.prank(admin);
        nft.upgradeTo(address(newImplementation));

        // Verify state is preserved
        assertEq(nft.nextTokenId(), tokenCountBefore);
        assertEq(nft.ownerOf(0), alice);
        assertEq(nft.ownerOf(1), bob);
        assertEq(nft.ownerOf(2), charlie);
        assertEq(nft.ownerOf(3), admin);
        assertEq(nft.tokenURI(0), "ipfs://uri1");
        assertEq(nft.tokenURI(1), "ipfs://uri2");
        assertEq(nft.tokenURI(2), "ipfs://uri3");
        assertEq(nft.tokenURI(3), "ipfs://uri4");
        assertEq(nft.balanceOf(alice), 1);
        assertEq(nft.balanceOf(bob), 1);
        assertEq(nft.balanceOf(charlie), 1);
        assertEq(nft.balanceOf(admin), 1);

        // Verify contract still works after upgrade
        vm.prank(alice);
        nft.safeMint(alice, "ipfs://uri5");
        assertEq(nft.ownerOf(4), alice);
        assertEq(nft.nextTokenId(), 5);
    }

    // ============================================
    // Event Tests
    // ============================================

    function test_batchSafeMintEmitsEvent() public {
        address[] memory recipients = new address[](2);
        recipients[0] = alice;
        recipients[1] = bob;

        string[] memory uris = new string[](2);
        uris[0] = "ipfs://uri1";
        uris[1] = "ipfs://uri2";

        uint256[] memory expectedTokenIds = new uint256[](2);
        expectedTokenIds[0] = 0;
        expectedTokenIds[1] = 1;

        vm.expectEmit(true, true, true, true);
        emit BatchMintNFT.BatchMinted(recipients, expectedTokenIds);

        vm.prank(alice);
        nft.batchSafeMint(recipients, uris);
    }

    // ============================================
    // Burn Tests - Owner Only
    // ============================================

    function test_ownerCanBurnOwnToken() public {
        // Mint token to alice
        vm.prank(alice);
        nft.safeMint(alice, "ipfs://uri1");

        assertEq(nft.ownerOf(0), alice);
        assertEq(nft.balanceOf(alice), 1);

        // Alice can burn her own token
        vm.prank(alice);
        nft.burn(0);

        // Verify token is burned
        vm.expectRevert();
        nft.ownerOf(0);
        assertEq(nft.balanceOf(alice), 0);
    }

    function test_nonOwnerCannotBurnToken() public {
        // Mint token to alice
        vm.prank(alice);
        nft.safeMint(alice, "ipfs://uri1");

        assertEq(nft.ownerOf(0), alice);

        // Bob cannot burn alice's token
        vm.expectRevert();
        vm.prank(bob);
        nft.burn(0);

        // Token should still exist
        assertEq(nft.ownerOf(0), alice);
    }

    function test_approvedOperatorCanBurnToken() public {
        // Mint token to alice
        vm.prank(alice);
        nft.safeMint(alice, "ipfs://uri1");

        // Alice approves bob as operator
        vm.prank(alice);
        nft.setApprovalForAll(bob, true);

        // Bob can now burn alice's token
        vm.prank(bob);
        nft.burn(0);

        // Verify token is burned
        vm.expectRevert();
        nft.ownerOf(0);
    }

    function test_cannotBurnNonExistentToken() public {
        vm.expectRevert();
        vm.prank(alice);
        nft.burn(999);
    }

    function test_burnEmitsTransferEvent() public {
        vm.prank(alice);
        nft.safeMint(alice, "ipfs://uri1");

        vm.expectEmit(true, true, true, true);
        emit IERC721.Transfer(alice, address(0), 0);

        vm.prank(alice);
        nft.burn(0);
    }

    function test_burnClearsTokenURI() public {
        vm.prank(alice);
        nft.safeMint(alice, "ipfs://uri1");

        assertEq(nft.tokenURI(0), "ipfs://uri1");

        vm.prank(alice);
        nft.burn(0);

        // Token URI should be cleared after burn
        vm.expectRevert();
        nft.tokenURI(0);
    }

    // ============ Minting Enabled/Disabled Tests ============

    function test_mintingEnabledByDefault() public view {
        assertTrue(nft.mintingEnabled());
    }

    function test_adminCanDisableMinting() public {
        vm.prank(admin);
        nft.setMintingEnabled(false);

        assertFalse(nft.mintingEnabled());
    }

    function test_adminCanEnableMinting() public {
        // Disable first
        vm.prank(admin);
        nft.setMintingEnabled(false);

        // Then enable
        vm.prank(admin);
        nft.setMintingEnabled(true);

        assertTrue(nft.mintingEnabled());
    }

    function test_nonAdminCannotSetMintingEnabled() public {
        vm.prank(alice);
        vm.expectRevert();
        nft.setMintingEnabled(false);
    }

    function test_safeMintRevertsWhenMintingDisabled() public {
        // Disable minting
        vm.prank(admin);
        nft.setMintingEnabled(false);

        // Try to mint
        vm.prank(alice);
        vm.expectRevert(BatchMintNFT.MintingDisabled.selector);
        nft.safeMint(alice, "ipfs://uri1");
    }

    function test_batchSafeMintRevertsWhenMintingDisabled() public {
        // Disable minting
        vm.prank(admin);
        nft.setMintingEnabled(false);

        // Try to batch mint
        address[] memory recipients = new address[](1);
        recipients[0] = alice;
        string[] memory uris = new string[](1);
        uris[0] = "ipfs://uri1";

        vm.prank(alice);
        vm.expectRevert(BatchMintNFT.MintingDisabled.selector);
        nft.batchSafeMint(recipients, uris);
    }

    function test_setMintingEnabledEmitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit BatchMintNFT.MintingEnabledChanged(false);

        vm.prank(admin);
        nft.setMintingEnabled(false);
    }

    function test_mintingWorksAfterReenabling() public {
        // Disable minting
        vm.prank(admin);
        nft.setMintingEnabled(false);

        // Re-enable minting
        vm.prank(admin);
        nft.setMintingEnabled(true);

        // Minting should work again
        vm.prank(alice);
        nft.safeMint(alice, "ipfs://uri1");

        assertEq(nft.ownerOf(0), alice);
        assertEq(nft.tokenURI(0), "ipfs://uri1");
    }
}
