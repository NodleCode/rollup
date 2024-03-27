# Nodle's Eth L2 rollup powered by zkSync stack
![Banner](https://github.com/NodleCode/rollup/assets/10683430/b50803ff-41d1-4faa-99eb-72c9eeaf3194)

# Development setup
> We recommend you run within the provided [devcontainer](https://code.visualstudio.com/remote/advancedcontainers/overview) to ensure you have all the necessary tooling installed such `graph`, `zksync-cli`, and `forge`.

## Dependencies
If developing on this repo, you will need a number of dependencies, you may install them yourself by running `./.devcontainer/install-tools.sh` (only made for Debian based Linux distributions, PRs welcome for other platforms). This is not necessary if you simply want to use docker compose to start a local testnet.

## Repo organization
- `./` contains foundry contracts for Nodle and Click on ZkSync:
  - `./lib` contains libraries we depend on.
  - `./src` contains contract sources.
  - `./scripts` contains deployment scripts.
  - `./test` contains unit tests.
- `./graph` contains a custom SubGraph for this project.
- ...more to come

# Usage

## Build

```shell
$ forge build
```

## Test

```shell
$ forge test
```

## Format

```shell
$ forge fmt
```