// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {MigrationNFT} from "../../src/bridge/MigrationNFT.sol";
import {NODLMigration} from "../../src/bridge/NODLMigration.sol";
import {NODL} from "../../src/NODL.sol";

library MigrationNFTTestUtils {
    function bridgeTokens(
        Vm vm,
        NODLMigration migration,
        address oracle,
        bytes32 txHash,
        address target,
        uint256 amount
    ) internal {
        vm.prank(oracle);
        migration.bridge(txHash, target, amount);
        migration.withdraw(txHash);
    }
}

contract MigrationNFTTest is Test {
    using MigrationNFTTestUtils for Vm;

    NODL nodl;
    NODLMigration migration;
    MigrationNFT migrationNFT;

    address[] oracles = [vm.addr(1), vm.addr(2)];

    uint256 maxHolders = 10;

    string[] levelToTokenURI = [
        "https://example.com/1",
        "https://example.com/2",
        "https://example.com/3",
        "https://example.com/4",
        "https://example.com/5"
    ];
    uint256[] levels = [500, 1000, 5000, 10000, 100000];

    function setUp() public {
        nodl = new NODL(address(this));
        migration = new NODLMigration(oracles, nodl, 1, 0);
        migrationNFT = new MigrationNFT(migration, maxHolders, levels, levelToTokenURI);

        nodl.grantRole(nodl.MINTER_ROLE(), address(migration));
    }

    function test_initialState() public view {
        assertEq(migrationNFT.nextTokenId(), 0);
        assertEq(migrationNFT.maxHolders(), maxHolders);
        assertEq(address(migrationNFT.migration()), address(migration));

        for (uint256 i = 0; i < levels.length; i++) {
            assertEq(migrationNFT.levels(i), levels[i]);
        }
    }

    function test_zeroHoldersWillRevert() public {
        vm.expectRevert(MigrationNFT.InvalidZeroHolders.selector);
        new MigrationNFT(migration, 0, levels, levelToTokenURI);
    }

    function test_enforceSorting() public {
        uint256[] memory unsortedLevels = new uint256[](5);
        unsortedLevels[0] = 1000;
        unsortedLevels[1] = 500;
        unsortedLevels[2] = 10000;
        unsortedLevels[3] = 5000;
        unsortedLevels[4] = 100000;

        vm.expectRevert(MigrationNFT.UnsortedLevelsList.selector);
        new MigrationNFT(migration, maxHolders, unsortedLevels, levelToTokenURI);
    }

    function test_enforceEqualLength() public {
        string[] memory unsortedTokenURIs = new string[](4);
        unsortedTokenURIs[0] = "https://example.com/1";
        unsortedTokenURIs[1] = "https://example.com/2";
        unsortedTokenURIs[2] = "https://example.com/3";
        unsortedTokenURIs[3] = "https://example.com/4";

        vm.expectRevert(MigrationNFT.UnequalLengths.selector);
        new MigrationNFT(migration, maxHolders, levels, unsortedTokenURIs);
    }

    function test_mint() public {
        vm.bridgeTokens(migration, oracles[0], 0x0, vm.addr(42), levels[0]);

        migrationNFT.safeMint(0x0);
        assertEq(migrationNFT.nextTokenId(), 1);
        assertEq(migrationNFT.ownerOf(0), vm.addr(42));
        assertEq(migrationNFT.tokenURI(0), levelToTokenURI[0]);
        assertEq(migrationNFT.holderToNextLevel(vm.addr(42)), 1);
        assertEq(migrationNFT.tokenIdToNextLevel(0), 1);
        assertEq(migrationNFT.individualHolders(), 1);
    }

    function test_mintFailsIfTooManyHolders() public {
        for (uint256 i = 0; i < maxHolders; i++) {
            vm.bridgeTokens(migration, oracles[0], bytes32(i), vm.addr(42 + i), levels[0]);
            migrationNFT.safeMint(bytes32(i));
        }

        assertEq(migrationNFT.individualHolders(), maxHolders);

        vm.bridgeTokens(migration, oracles[0], bytes32(maxHolders), vm.addr(42 + maxHolders), levels[0]);
        vm.expectRevert(MigrationNFT.TooManyHolders.selector);
        migrationNFT.safeMint(bytes32(maxHolders));
    }

    function test_mintFailsIfAlreadyClaimed() public {
        vm.bridgeTokens(migration, oracles[0], 0x0, vm.addr(42), levels[0]);
        migrationNFT.safeMint(0x0);

        vm.expectRevert(MigrationNFT.AlreadyClaimed.selector);
        migrationNFT.safeMint(0x0);
    }

    function test_mintFailsIfProposalDoesNotExist() public {
        vm.expectRevert(MigrationNFT.ProposalDoesNotExist.selector);
        migrationNFT.safeMint(0x0);
    }

    function test_mintFailsIfUnderMinimumAmount() public {
        vm.bridgeTokens(migration, oracles[0], 0x0, vm.addr(42), levels[0] - 1);

        vm.expectRevert(MigrationNFT.NoLevelUp.selector);
        migrationNFT.safeMint(0x0);
    }

    function test_mintFailsIfNoMoreLevels() public {
        vm.bridgeTokens(migration, oracles[0], 0x0, vm.addr(42), levels[levels.length - 1]);
        migrationNFT.safeMint(0x0);

        vm.bridgeTokens(migration, oracles[0], bytes32(uint256(1)), vm.addr(42), levels[levels.length - 1]);
        vm.expectRevert(MigrationNFT.NoLevelUp.selector);
        migrationNFT.safeMint(bytes32(uint256(1)));
    }

    function test_mintFailsIfNotExecuted() public {
        vm.prank(oracles[0]);
        migration.bridge(0x0, vm.addr(42), levels[0]);

        vm.expectRevert(MigrationNFT.NotExecuted.selector);
        migrationNFT.safeMint(0x0);
    }

    function test_mintFullLevelUp() public {
        // bridge enough tokens to qualify for all levels at once
        vm.bridgeTokens(migration, oracles[0], 0x0, vm.addr(42), levels[levels.length - 1]);
        migrationNFT.safeMint(0x0);

        assertEq(migrationNFT.individualHolders(), 1);
        assertEq(migrationNFT.holderToNextLevel(vm.addr(42)), levels.length);
        assertEq(migrationNFT.nextTokenId(), levels.length);
        for (uint256 i = 0; i < levels.length; i++) {
            assertEq(migrationNFT.ownerOf(i), vm.addr(42));
            assertEq(migrationNFT.tokenURI(i), levelToTokenURI[i]);
            assertEq(migrationNFT.tokenIdToNextLevel(i), i + 1);
        }
    }

    function test_mintLevelUpOneByOne() public {
        for (uint256 i = 0; i < levels.length; i++) {
            vm.bridgeTokens(migration, oracles[0], bytes32(i), vm.addr(42), levels[i]);
            migrationNFT.safeMint(bytes32(i));

            assertEq(migrationNFT.nextTokenId(), i + 1);
            assertEq(migrationNFT.holderToNextLevel(vm.addr(42)), i + 1);
            assertEq(migrationNFT.tokenIdToNextLevel(i), i + 1);
            assertEq(migrationNFT.ownerOf(i), vm.addr(42));
            assertEq(migrationNFT.tokenURI(i), levelToTokenURI[i]);
        }

        assertEq(migrationNFT.individualHolders(), 1);
    }

    function test_canLevelUpEvenThoughMaxHoldersWasReached() public {
        for (uint256 i = 0; i < maxHolders; i++) {
            vm.bridgeTokens(migration, oracles[0], bytes32(i), vm.addr(42 + i), levels[0]);
            migrationNFT.safeMint(bytes32(i));
        }

        // Can level up even if holders maxed out
        // vm.addr(42) already has one NFT because of the FOR loop above so should still be able to mint
        // level ups
        assertEq(migrationNFT.balanceOf(vm.addr(42)), 1);
        vm.bridgeTokens(migration, oracles[0], bytes32(maxHolders + 1), vm.addr(42), levels[1]);
        migrationNFT.safeMint(bytes32(maxHolders + 1));

        assertEq(migrationNFT.holderToNextLevel(vm.addr(42)), 2);
        assertEq(migrationNFT.nextTokenId(), maxHolders + 1); // we minted `maxHolders` NFTs in the FOR loop + 1 after
    }

    function test_isSoulBound() public {
        vm.bridgeTokens(migration, oracles[0], 0x0, vm.addr(42), levels[0]);
        migrationNFT.safeMint(0x0);

        vm.expectRevert(MigrationNFT.SoulBoundIsNotTransferrable.selector);
        migrationNFT.transferFrom(vm.addr(42), vm.addr(43), 0);
    }
}
