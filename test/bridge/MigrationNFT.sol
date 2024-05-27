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

    uint256 maxNFTs = 10;
    uint256 minAmount = 100;

    string tokenURI = "https://example.com";

    function setUp() public {
        nodl = new NODL();
        migration = new NODLMigration(oracles, nodl, 1, 0);
        migrationNFT = new MigrationNFT(migration, maxNFTs, minAmount, tokenURI);

        nodl.grantRole(nodl.MINTER_ROLE(), address(migration));
    }

    function test_initialState() public {
        assertEq(migrationNFT.nextTokenId(), 0);
        assertEq(migrationNFT.maxNFTs(), maxNFTs);
        assertEq(migrationNFT.minAmount(), minAmount);
        assertEq(address(migrationNFT.migration()), address(migration));
    }

    function test_mint() public {
        vm.bridgeTokens(migration, oracles[0], 0x0, vm.addr(42), minAmount);

        migrationNFT.safeMint(0x0);
        assertEq(migrationNFT.nextTokenId(), 1);
        assertEq(migrationNFT.ownerOf(0), vm.addr(42));
        assertEq(migrationNFT.tokenURI(0), tokenURI);
    }

    function test_mintFailsIfTooManyNFTs() public {
        for (uint256 i = 0; i < maxNFTs; i++) {
            vm.bridgeTokens(migration, oracles[0], bytes32(i), vm.addr(42 + i), minAmount);
            migrationNFT.safeMint(bytes32(i));
        }

        vm.expectRevert(MigrationNFT.TooManyNFTs.selector);
        migrationNFT.safeMint(0x0);
    }

    function test_mintFailsIfAlreadyClaimed() public {
        vm.bridgeTokens(migration, oracles[0], 0x0, vm.addr(42), minAmount);
        migrationNFT.safeMint(0x0);

        vm.expectRevert(MigrationNFT.AlreadyClaimed.selector);
        migrationNFT.safeMint(0x0);
    }

    function test_mintFailsIfProposalDoesNotExist() public {
        vm.expectRevert(MigrationNFT.ProposalDoesNotExist.selector);
        migrationNFT.safeMint(0x0);
    }

    function test_mintFailsIfUnderMinimumAmount() public {
        vm.bridgeTokens(migration, oracles[0], 0x0, vm.addr(42), minAmount - 1);

        vm.expectRevert(MigrationNFT.UnderMinimumAmount.selector);
        migrationNFT.safeMint(0x0);
    }

    function test_mintFailsIfNotExecuted() public {
        vm.prank(oracles[0]);
        migration.bridge(0x0, vm.addr(42), minAmount);

        vm.expectRevert(MigrationNFT.NotExecuted.selector);
        migrationNFT.safeMint(0x0);
    }

    function test_mintFailsIfAlreadyHolder() public {
        vm.bridgeTokens(migration, oracles[0], 0x0, vm.addr(42), minAmount);
        vm.bridgeTokens(migration, oracles[0], bytes32(uint256(1)), vm.addr(42), minAmount);
        migrationNFT.safeMint(0x0);

        vm.expectRevert(MigrationNFT.AlreadyAHolder.selector);
        migrationNFT.safeMint(bytes32(uint256(1)));
    }
}
