#!/bin/bash

sudo apt update
sudo apt install --yes pkg-config libssl-dev libclang-dev docker-compose

rustup toolchain install nightly

yarn global add zksync-cli
cargo +nightly install --git https://github.com/matter-labs/foundry-zksync --force zkcast zkforge
