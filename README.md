# Nodle's Eth L2 rollup powered by zkSync stack
![Banner](https://github.com/NodleCode/rollup/assets/10683430/b50803ff-41d1-4faa-99eb-72c9eeaf3194)

# Development setup
> We recommend you run within the provided [devcontainer](https://code.visualstudio.com/remote/advancedcontainers/overview) to ensure you have all the necessary tooling installed such `zksync-cli`, and `forge`.

For subquery utilization refer to [Nodle-zksync-subquery](/subquery/README.md)

## Repo organization
- `./` contains foundry contracts for Nodle and Click on ZkSync:
  - `./lib` contains libraries we depend on.
  - `./src` contains contract sources.
  - `./scripts` contains deployment scripts.
  - `./test` contains unit tests.
- `./subquery` contains a custom subquery for this project.
- ...more to come

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

**Note**: this is among the least supported, most work in progress feature of the forge zksync fork. Expect these instructions to be broken or outdated.

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
In the following example `VOTER1_ADDR` is the public address of the bridge oracle whose role is going to be a voter for funds coming from
the parachain side. Similarly `VOTER2_ADDR` and `VOTER3_ADDR` are addresses of the other two voter oracles. 
The closer oracle does not need special permissions and thus need not to be mentioned.
NOTE: `i` flag in the command will make the tool prompt you for the private key of the deployer. So remember to have that handy but you don't need to define it in yout environment.
```shell
VOTER1_ADDR="0x18AB6B4310d89e9cc5521D33D5f24Fb6bc6a215E" \
VOTER2_ADDR="0x571C969688991C6A35420C62d44666c47eB3F752" \
VOTER3_ADDR="0x0cBCE4Ab8ADe1398bA10Fca2A19B5Aa332312Fb1" \
forge script script/DeployNodlMigration.sol --zksync --rpc-url https://sepolia.era.zksync.dev --zk-optimizer -i 1 --broadcast
```

Afterwards the user you onboarded should be able to mint NFTs as usual via the `safeMint(ownerAddress, metadataUri)` function.