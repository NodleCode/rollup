#!/bin/bash

sudo apt update
sudo apt install --yes pkg-config build-essential cmake clang libssl-dev libclang-dev docker-compose software-properties-common

yarn global add zksync-cli
yarn global add @graphprotocol/graph-cli

git clone https://github.com/matter-labs/foundry-zksync.git /tmp/foundry-zksync
cd /tmp/foundry-zksync
cargo install --path ./crates/forge --profile local --force --locked