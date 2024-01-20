# Nodle's Eth L2 rollup powered by zkSync stack
This mono repo will contain all the required smart-contracts and the services that we would need to develop aroung them. This is a proof of concept targeting the needs of our Click dApp as its initial goal.

Each sub-package should feature a `README.md` file explaining how to test and use it.

# Development setup
> We recommend you run within the provided [devcontainer](https://code.visualstudio.com/remote/advancedcontainers/overview) to ensure you have all the necessary tooling with the correct versions and can skip the below steps.

## Dependencies
A number of dependencies are necessary to support this project, you may install them yourself by running `./.devcontainer/install-tools.sh`.

## Local network
Most packages in this repo depend on various services which can easily be deployed locally by running `docker compose -f docker-compose-dev up`.