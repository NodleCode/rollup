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

### Upgrading
tbd