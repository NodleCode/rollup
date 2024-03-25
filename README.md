# Nodle's Eth L2 rollup powered by zkSync stack
![Banner](https://github.com/NodleCode/rollup/assets/10683430/b50803ff-41d1-4faa-99eb-72c9eeaf3194)

This mono repo will contain all the required smart-contracts and the services that we would need to develop aroung them. This is a proof of concept targeting the needs of our Click dApp as its initial goal.

Each sub-package should feature a `README.md` file explaining how to test and use it.

# Development setup
> We recommend you run within the provided [devcontainer](https://code.visualstudio.com/remote/advancedcontainers/overview) to ensure you have all the necessary tooling installed such `graph`, `zksync-dev`, and `foundry`.

## Dependencies
If developing on this repo, you will need a number of dependencies, you may install them yourself by running `./.devcontainer/install-tools.sh` (only made for Debian based Linux distributions, PRs welcome for other platforms). This is not necessary if you simply want to use docker compose to start a local testnet.

## Repo organization


## TODOs
- [ ] reorg folders
- [ ] move contracts to forge
- [ ] local testing instructions