# Rollup Contracts
This package contains the Solidity smart contracts deployed to the Nodle rollup. All contracts are upgradeable and may be managed by a configurable governance address.

## Development

### Environmemt
> We recommend you run within the provided [devcontainer](https://code.visualstudio.com/remote/advancedcontainers/overview) to ensure you have all the necessary tooling with the correct versions.

You will need to copy `.env.example` to `.env` and define the approppriate environment variables before you go ahead. If you need some testing accounts for a local node, you may want to look at the [ZkSync rich accounts list](https://github.com/matter-labs/local-setup/blob/main/rich-wallets.json).

### Local node
It is recommended you use a local **dockerized** node started via `zksync-cli dev start`.

### Deployments
The deploy script will check that you have enough ETH in your account to go ahead and deploy the contracts behind upgrade proxies. If possible, it will auto verify your contracts on the ZkSync block explorer for your deployment network.

`yarn compile && yarn deploy`

### Unit tests
`yarn test`

### Usage

#### `ContentSignNFT` and `ContentSignNFTFactory`
`ContentSignNFTFactory` is the way to instantiate `ContentSignNFT` contracts at deterministic addresses thanks to the `Create2` operand in the EVM.

Deployment may be done by calling the `deployContentSignNFT` function on the factory contract with the appropriate parameters:
- `_salt` should be a series of bytes. It may be random, or determined from the user address.
- `_defaultAdmin` and `_defaultMinter` will typically be the user address.

Once the transaction goes through a `ContentSignNFT` will be deployed, with the user address set as the minter and admin. Thanks to `Create2`, one can easily compute the address of the contracts with code similar to the below:
```js
const salt = ethers.ZeroHash; // in production, you will use any series of bytes of your choosing

const tx = await factory.deployContentSignNFT(salt, wallet.address, wallet.address);
await tx.wait();

const deployer = new Deployer(hre, wallet);
const artifact = await deployer.loadArtifact("ContentSignNFT");

const abiCoder = new ethers.AbiCoder();
const contractAddress = utils.create2Address(
    await factory.getAddress(),
    // the bytecode value typically comes from the artifact file once the contracts
    // are compiled with `yarn compile`
    utils.hashBytecode(artifact.bytecode),
    salt,
    abiCoder.encode(["address", "address"], [wallet.address, wallet.address])
);
```

Once you have a `ContentSignNFT` deployed, you can easily interact with it. Minting a NFT may be done via the function `safeMint` which accepts the following parameters:
- `to` is the address of the NFT owner
- `uri` should the URI of the NFT metadata file, typically on IPFS

No NFT ID is necessary as we auto increment it internally.

You may then get details about the NFTs minted, their owners, URI etc... according to the [ERC721 standard](https://erc721.org/).

#### `WhitelistPaymaster`
Users of Click and ContentSign are not required to hold tokens to pay for their gas fees. Instead, the operator of the solution will typically sponsor them for their gas fees. This is doable via the `WhitelistPaymaster` which is a ZkSync paymaster implementation allowing whitelisted users to interact with whitelisted contracts.

Whitelisting is centrally controlled by an `admin` that is set at deploy time for the contract (look into `./deploy/deploy.ts`).

Operations of the contract is relatively simple:
1. Deposit enough ETH into the `WhitelistPaymaster` to support the user's gas fees.
2. `admin` should call the function `addWhitelistedContracts` with a list of contracts to whitelist, typically this would be used to add the addresses of the `ContentSignNFT` contracts as they get deployed.
3. `admin` should whitelist a user by calling the function `grantRole` with the whitelist role value (can be fetched from the `WHITELISTED_USER_ROLE` value on the deployed contract), and the user's address.
4. The user may then craft ZkSync compliant transactions to use the paymaster. You will need to refer to your SDK's documentation for this.

> Note that the `WhitelistPaymaster` contract would typically be managed by a central API and not by end users!