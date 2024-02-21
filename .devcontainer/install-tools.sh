#!/bin/bash

sudo apt update
sudo apt install --yes pkg-config build-essential cmake clang libssl-dev libclang-dev docker-compose software-properties-common jq
#sudo apt install --yes lldb lld postgresql axel

sudo add-apt-repository --yes ppa:ethereum/ethereum
sudo apt-get update
sudo apt-get install solc

# rustup toolchain install nightly

# cargo install cargo-nextest
# cargo install sqlx-cli

yarn global add zksync-cli
yarn global add @graphprotocol/graph-cli

if [ -z "$SKIP_FOUNDRY" ]; then
    curl -L https://foundry.paradigm.xyz | sh
    ~/.foundry/bin/foundryup
fi

# zk init || echo "zk init failed - ignored | you may want to run cd $ZKSYNC_HOME && git reset --hard && zk init"
# zk down