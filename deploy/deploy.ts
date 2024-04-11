import { deployContract, getWallet } from "./utils";

export default async function () {
    const whitelist_admin = "0x340F754549Cd27a0C7457B1f771A3f09645C1A3F";
    const withdrawer = "0x5e097AC1BCF81E7Ff2657045F72cAa6cF06486C9";
    const super_admin = "0x5e097AC1BCF81E7Ff2657045F72cAa6cF06486C9";

    const paymaster = await deployContract("WhitelistPaymaster", [withdrawer]);
    const nft = await deployContract("ContentSignNFT", ["ContentSign", "SIGNED", await paymaster.getAddress()]);

    console.log("WhitelistPaymaster deployed to:", await paymaster.getAddress());
    console.log("ContentSignNFT deployed to:", await nft.getAddress());

    console.log("Adding NFT contract to whitelist...");
    await paymaster.addWhitelistedContracts([await nft.getAddress()]);

    console.log("Granting roles to correct admins...");
    const role_whitelist_admin = await paymaster.WHITELIST_ADMIN_ROLE();
    const role_super_admin = await paymaster.DEFAULT_ADMIN_ROLE();
    await paymaster.grantRole(role_whitelist_admin, whitelist_admin);
    await paymaster.grantRole(role_super_admin, super_admin);

    console.log("Revoking roles from deployer...");
    const our_address = (await getWallet()).address;
    await paymaster.renounceRole(role_whitelist_admin, our_address);
    await paymaster.renounceRole(role_super_admin, our_address);
}