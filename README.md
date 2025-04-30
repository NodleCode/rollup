# Nodle's Eth L2 rollup powered by zkSync stack
![Banner](https://github.com/NodleCode/rollup/assets/10683430/b50803ff-41d1-4faa-99eb-72c9eeaf3194)

# Development setup
> [!NOTE]
> We recommend you run within the provided [devcontainer](https://code.visualstudio.com/remote/advancedcontainers/overview) to ensure you have all the necessary tooling installed such `zksync-cli`, and `forge`.

For subquery utilization refer to [Nodle-zksync-subquery](/subquery/README.md)

## Repo organization
- `./` contains foundry contracts for Nodle and Click on ZkSync:
  - `./lib` contains libraries we depend on.
  - `./src` contains contract sources.
  - `./script` contains deployment scripts.
  - `./test` contains unit tests.
- `./subquery` contains a custom subquery for this project.
- ...more to come

## Conventions
- all files should be licensed under the BSD 3 Clear Clause license with the required file header `// SPDX-License-Identifier: BSD-3-Clause-Clear`
- when writing scripts, ensure that:
  - input environment variables are prefixed with `N_` to differentiate them from `forge` environment variables
  - an example usage is added to this readme file
  - naming aligns with existing script files
- when writing new contracts, ensure that:
  - proper unit tests are written, no PR should be merged without proper unit testing
  - OpenZeppelin is used extensively whenever possible as to reduce audit risk
- while we do have a compatibility layer with `hardhat`, scripts, tests and contracts need to be fully usable via `forge` itself by default
- if deploying a contract, ensure it is verified on Etherscan

# Mainnet Deployments

Please refer to the [Nodle on ZKsync documentation](https://docs.nodle.com/nodle-on-zksync-era) for main contract addresses.

# Usage

## Build

```shell
$ forge build --zksync --zk-optimizer
```

## Test

```shell
$ forge test
```

## Format

```shell
$ forge fmt
```

## Deployment

Please see scripts in `./scripts` and refer to the [forge documentation](https://book.getfoundry.sh/reference/forge/forge-script) for additional arguments. You will need to specify additional arguments when deploying to mainnet or verifying the contracts on Etherscan such as `--rpc-url` and `--broadcast`.

### Deploying Click contracts

Please define the following environment variables:
- `N_WHITELIST_ADMIN`: address of the whitelist admin on the paymaster whitelist contract (typically the onboard or sponsorship API address).
- `N_WITHDRAWER`: address of the account allowed to withdraw ETH from the paymaster contract.
- deployer address will be set as super admin.

```shell
$ forge script script/DeployClick.s.sol --zksync
[⠒] Compiling...
[⠆] Compiling 1 files with 0.8.20
[⠰] Solc 0.8.20 finished in 8.47s

Script ran successfully.
Gas used: 1821666

== Logs ==
  Deployed ClickContentSign at 0x90193C961A926261B756D1E5bb255e67ff9498A1
  Deployed WhitelistPaymaster at 0x34A1D3fff3958843C43aD80F30b94c510645C316
  Please ensure you fund the paymaster contract with enough ETH!

If you wish to simulate on-chain transactions pass a RPC URL.
```

### Deploying ContentSign Enterprise contracts

Please define the following environment variables:
- `N_NAME`: name of the NFT contract deployed.
- `N_SYMBOL`: symbol of the NFT contract deployed.

Here is a full example for a Sepolia deployment: `N_NAME=ExampleContentSign N_SYMBOL=ECS forge script script/DeployContentSignEnterprise.s.sol --zksync --rpc-url https://sepolia.era.zksync.dev --zk-optimizer -i 1 --broadcast`.

Once deployed, the script will output the contract address, and the account you deployed with will be set as the administrator of this contract with the possibility to grant other users minting access. You may onboard a new user with `cast` via the following command template:
```shell
export ETH_RPC_URL=https://sepolia.era.zksync.dev     # use the appropriate RPC here
export NFT=0x195e4E251c41e8Ae9E9E961366C73e2CFbfB115A # use your own contract address here
export ROLE=`cast call $NFT "WHITELISTED_ROLE()(bytes32)"`

# Of course, replace 0x68e3981280792A19cC03B5A770B82a6497f0A464 with the address of
# the user whom you'd like to onboard - this is only here for example
cast send -i $NFT "grantRole(bytes32,address)" $ROLE 0x68e3981280792A19cC03B5A770B82a6497f0A464
```

### Deploying NODL and NODLMigration contract
In the following example `N_VOTER1_ADDR` is the public address of the bridge oracle whose role is going to be a voter for funds coming from
the parachain side. Similarly `N_VOTER2_ADDR` and `N_VOTER3_ADDR` are addresses of the other two voter oracles. 
The closer oracle does not need special permissions and thus need not to be mentioned.
NOTE: `i` flag in the command will make the tool prompt you for the private key of the deployer. So remember to have that handy but you don't need to define it in your environment.
```shell
N_VOTER1_ADDR="0x18AB6B4310d89e9cc5521D33D5f24Fb6bc6a215E" \
N_VOTER2_ADDR="0x571C969688991C6A35420C62d44666c47eB3F752" \
N_VOTER3_ADDR="0x0cBCE4Ab8ADe1398bA10Fca2A19B5Aa332312Fb1" \
forge script script/DeployNodlMigration.sol --zksync --rpc-url https://sepolia.era.zksync.dev --zk-optimizer -i 1 --broadcast
```

Afterwards the user you onboarded should be able to mint NFTs as usual via the `safeMint(ownerAddress, metadataUri)` function.

### Deploying MigrationNFT contract
The `MigrationNFT` contract allows the minting of a reward SoulBound NFT when users bridge enough tokens through `NODLMigration`. Users can "level up" depending on the amount of tokens they bring in, with each levels being a sorted list of bridged amounts.

You will need to set the following environment variables:
- `N_MIGRATION`: address of the `NODLMigration` contract
- `N_MAX_HOLDERS`: maximum number of participants
- `N_LEVELS`: number of levels to set
- `N_LEVELS_x` where `x` is an integer from `0` to `N_LEVELS - 1`: actual number of tokens for each level
- `N_LEVELS_URI_x` where `x` is an integer from `0` to `N_LEVELS - 1`: actual metadata URL for the NFTs

You can then run the script `script/DeployMigrationNFT.s.sol` very similarly to the below:
```shell
N_MIGRATION=0x1427d38B967435a3F8f476Cda0bc4F51fe66AF4D \
N_MAX_HOLDERS=10000 \
N_LEVELS=3 \
N_LEVELS_0=100 \
N_LEVELS_1=200 \
N_LEVELS_2=300 \
N_LEVELS_URI_0=example.com \
N_LEVELS_URI_1=example.com \
N_LEVELS_URI_2=example.com \
forge script script/DeployMigrationNFT.s.sol --zksync --rpc-url https://sepolia.era.zksync.dev --zk-optimizer -i 1 --broadcast
```

## Scripts

### Checking on bridging proposals
Given a tracker id (`proposal`) and the bridge address you may run the script available in `./script/CheckBridge.s.sol`. The script will output proposal details and outline expectations as to the proposal's execution timeline. Here is a simple example:
```shell
N_PROPOSAL_ID=c43005c880cad7b699122b403607187a78251b9850d387521ffb123c473e3392 \
N_BRIDGE=0x5de7fe085ee66Fb48447e75AA8fb0598a080AEe0 \
forge script script/CheckBridge.s.sol --zksync --rpc-url https://mainnet.era.zksync.io
```

### Whitelisting new users on ContentSign contracts
Given a user and contract address, you can whitelist new users on contracts derived from `EnterpriseContentSign` with the `ContentSignWhitelist` script. Note that this assumes your own key has been granted admin permissions on this same contract. Here is a simple example for a testnet contract:
```shell
N_CONTENTSIGN=0x195e4E251c41e8Ae9E9E961366C73e2CFbfB115A \
N_WHITELIST=0x732e40223f57d7a1dbf340f5c0cc5b363b60428b \
forge script script/ContentSignWhitelist.s.sol -i 1 --zksync --rpc-url https://sepolia.era.zksync.dev --broadcast
```

## Contract verification

> [!CAUTION]
> The below steps are **not** for the faint of heart. Contract verification is technically not supported yet by the zkSync foundry fork, and the instructions below are likely to break (in which case feel free to update them via a PR).

Verification on Etherscan is best done via the Solidity Json Input method as it is the least error prone and most reliable. To do so, you will need a few elements:
1. Contract address, which you typically get from script outputs.
2. `solc` and `zksolc` versions, which you can identify based on the pragma header of the solidity contracts, or by checking what binaries are on your system:
  ```shell
  $ ls ~/.zksync/
  solc-macosx-arm64-0.8.23-1.0.0 zksolc-macosx-arm64-v1.4.1
  ```
  In the sample case above, we are using `solc` `0.8.23` and `zksolc` `1.4.1`.
3. The Solidity Json Input file, which you can get by following the below instructions
  1. Build the contracts and ask for the `build-info` via `forge build --zksync --zk-optimizer --build-info`
  2. Access the said `build-info` at path `./out/build-info`, you will find there a JSON file (if you have more than one, take the most recent one)
  3. Open the JSON file and select the value under the `input` key
  4. Due to some incompatibilities, normalize the JSON value by removing the keys `settings.metadata` and `settings.viaIR`
4. The contract inputs, which you can regenerate if you know the input values you deployed the contract with. Or that you can fetch by viewing your deployment transaction on [explorer.zksync.io](https://explorer.zksync.io). To do, you will need to:
  1. Open your deployment transaction on [explorer.zksync.io](https://explorer.zksync.io) (make sure to select the testnet if you are using the zkSync Era testnet)
  2. Look for the input data variable named `_input`
  3. Copy paste its value and **strip the `0x prefix** as Etherscan will throw an error otherwise

Use all these artifacts on the contract verification page on Etherscan for your given contract (open your contract on Etherscan, select `Contract` and the link starting with `Verify`). When prompted, enter the compiler versions, the license (we use BSD-3 Clause Clear). Then on the next page, enter your normalized JSON input file, and the contract constructor inputs.

## Additional resources

- [L1 contracts](https://docs.zksync.io/zksync-era/environment/l1-contracts)
- [ZK stack addresses](https://docs.zksync.io/zk-stack/zk-chain-addresses)
