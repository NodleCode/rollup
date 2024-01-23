# Nodle's Eth L2 rollup powered by zkSync stack
This mono repo will contain all the required smart-contracts and the services that we would need to develop aroung them. This is a proof of concept targeting the needs of our Click dApp as its initial goal.

Each sub-package should feature a `README.md` file explaining how to test and use it.

# Development setup
> We recommend you run within the provided [devcontainer](https://code.visualstudio.com/remote/advancedcontainers/overview) to ensure you have all the necessary tooling with the correct versions and can skip the below steps.

## Local network
Most packages in this repo depend on various services which can easily be deployed locally by running `docker compose up`.

If using a mac with Apple Silicon chip, you may need to run `export DOCKER_DEFAULT_PLATFORM=linux/amd64` first.

### Getting contract addresses
The docker compose should auto deploy the contracts for you. You should be able to see their addresses via `docker compose logs -f deploy-contracts`.

## Dependencies
If developing on this repo, you will need a number of dependencies, you may install them yourself by running `./.devcontainer/install-tools.sh`. This is not necessary if you simply want to use docker compose to start a local testnet.
