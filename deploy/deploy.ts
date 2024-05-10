import { deployContract, getWallet } from "./utils";

export default async function () {
    const one_day = 60 * 60 * 24; // zksync mainnet uses a 1sec block time
    const threshold = 2;
    const relayers = [
        "0x7037F93D4e736329b6526d3E5469dB56950Eff2D",
        "0x5795d2fDF0E9a4c9E5ac99894bDE7a2eA5A7A633",
        "0xCe8931DA686aD61c85e352caA3Dee97B6f06dFC8"
    ];

    const admin_multisig = "0x5e097AC1BCF81E7Ff2657045F72cAa6cF06486C9";

    const nodl = await deployContract("NODL");
    const migration = await deployContract("NODLMigration", [relayers, await nodl.getAddress(), threshold, one_day]);

    const role_minter = await nodl.MINTER_ROLE();
    const role_admin = await nodl.DEFAULT_ADMIN_ROLE();

    await nodl.grantRole(role_minter, await migration.getAddress());
    await nodl.grantRole(role_admin, admin_multisig);

    await nodl.renounceRole(role_admin, getWallet().address);

    console.log("NODL deployed to:", await nodl.getAddress());
    console.log("NODLMigration deployed to:", await migration.getAddress());
}