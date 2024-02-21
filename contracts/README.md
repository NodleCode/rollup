# Rollup Contracts
This package contains the Solidity smart contracts deployed to the Nodle rollup. All contracts are upgradeable and may be managed by a configurable governance address.

## Development

### Environmemt
You will need to copy `.env.example` to `.env` and define the approppriate environment variables before you go ahead. If you need some testing accounts for a local node, you may want to look at the [ZkSync rich accounts list](https://github.com/matter-labs/local-setup/blob/main/rich-wallets.json).

### Local node
Please refer to the root level `README.md`.

### Deployments
The deploy script will check that you have enough ETH in your account to go ahead and deploy the contracts behind upgrade proxies. If possible, it will auto verify your contracts on the ZkSync block explorer for your deployment network.

`yarn compile && yarn deploy`

### Unit tests
`yarn test`

### Usage

#### `ContentSignNFT`
`ContentSignNFT` is a shared NFT contract for ContentSign customers. Typically one instance is deployed per group of users or customers. Its constructor accepts three arguments:
- `name`: the name of the NFT contract
- `symbol`: the symbol of the NFT contract
- `admin`: the admin address which may grant minting permissions to users

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
3. `admin` should whitelist a user by calling the function `addWhitelistedUsers` with the user addresses to whitelist.
4. The user may then craft ZkSync compliant transactions to use the paymaster. You will need to refer to your SDK's documentation for this.

> Note that the `WhitelistPaymaster` contract would typically be managed by a central API and not by end users!

#### Whitelisting
As highlighted above, some of the contracts expect the user to be whitelisted before they can call them. The instructions below may be used to whitelist a user. This typically would be done by a backend side component, though when developing it may be necessary to manually whitelist users.

> The instructions below assume you have a running local setup, ideally via `docker compose up` at the root of this repo.

##### Tooling
Make sure you have installed [foundry](https://book.getfoundry.sh/).

> Pro Tip: if you use our devcontainer, it is already preinstalled!

##### Environment
For the sake of making our life easier, let's define a few environment variables (the command `export VAR=VALUE` allows you to do this on most systems where `VAR` and `VALUE` are both the environment variable and its value):
- `ETH_RPC_URL`: URL of the your rollup node, typically `http://localhost:3050`. This is automatically preset in the devcontainer too!
- `ADDR_NFT` and `ADDR_PAYMASTER`: addresses of the deployed `ContentSignNFT` and `WhitelistPaymaster` contracts. If you use the docker compose setup, this can fetched via `docker compose logs -f deploy-contracts`.
- `ADDR_USER` the address of the user you would like to whitelist.
- `PK_WHITELIST` the address of the whitelist admin configured on the paymaster and nft contracts. On the docker compose setup this should be `0xac1e735be8536c6534bb4f17f06f6afc73b2b5ba84ac2cfb12f7461b20c0bbe3`.

##### Add a user to the `WhitelistPaymaster` contract
The Paymaster is used to allow users not to pay for their transactions when interacting with the `ContentSignNFT` contract. To prevent abuse, users must be whitelisted. Additionally, the `ContentSignNFT` contract also expects depends on the user being whitelisted in the `WhitelistPaymaster` before allowing them to mint tokens.

Let's check if the user is already whitelisted:
```sh
$ cast call $ADDR_PAYMASTER "isWhitelistedUser(address)(bool)" $ADDR_USER
false
```

As expected, the user is not whitelisted yet. Let's whitelist him:
```sh
cast send --private-key $PK_WHITELIST $ADDR_PAYMASTER "addWhitelistedUsers(address[])" "[${ADDR_USER}]"
```

And let's check the whitelist status of the user:
```sh
$ cast call $ADDR_PAYMASTER "isWhitelistedUser(address)(bool)" $ADDR_USER
true
```

And here we go! The user may now mint NFTs. You may mint NFTs with commands similar to the below:
```sh
cast send --private-key <private key of the user account> $ADDR_NFT "safeMint(address,string)" $ADDR_USER "test"
```
Of course, make sure to replace `<private key of the user account>` with the actual private key of the user account. `cast` is a really powerful tool, make sure to check the [Foundry Docs](https://book.getfoundry.sh/) for more details.