// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {MigrationNFT} from "../../src/bridge/MigrationNFT.sol";
import {NODLMigration} from "../../src/bridge/NODLMigration.sol";
import {NODL} from "../../src/NODL.sol";

contract MigrationNFTTest is Test {
    NODL nodl;
    NODLMigration migration;
    MigrationNFT migrationNFT;

    address[] oracles = [vm.addr(1), vm.addr(2)];

    uint256 maxHolders = 10;
    uint256 minAmount = 100;

    string tokenURI = "https://example.com";

    function setUp() public {
        nodl = new NODL();
        migration = new NODLMigration(oracles, nodl, 1, 0);
        migrationNFT = new MigrationNFT(migration, maxHolders, minAmount, tokenURI);

        nodl.grantRole(nodl.MINTER_ROLE(), address(migration));
    }

    function test_initialState() public {
        assertEq(migrationNFT.nextTokenId(), 0);
        assertEq(migrationNFT.maxHolders(), maxHolders);
        assertEq(migrationNFT.minAmount(), minAmount);
        assertEq(address(migrationNFT.migration()), address(migration));
    }

    function test_mint() public {
        vm.prank(oracles[0]);
        migration.bridge(0x0, vm.addr(42), minAmount);
        migration.withdraw(0x0);

        migrationNFT.safeMint(0x0);
        assertEq(migrationNFT.nextTokenId(), 1);
        assertEq(migrationNFT.ownerOf(0), vm.addr(42));
        assertEq(migrationNFT.tokenURI(0), tokenURI);
    }
}
