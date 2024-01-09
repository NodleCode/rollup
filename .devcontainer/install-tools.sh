#!/bin/bash

sudo apt update
sudo apt install --yes pkg-config libssl-dev

rustup toolchain install nightly

yarn global add zksync-cli
cargo +nightly install --git https://github.com/matter-labs/foundry-zksync --force anvil cast chisel forge zkcast zkforge
