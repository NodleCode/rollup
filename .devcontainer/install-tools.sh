#!/bin/bash

sudo apt update
sudo apt install --yes pkg-config build-essential pkg-config cmake clang lldb lld libssl-dev libclang-dev docker-compose postgresql axel software-properties-common

sudo add-apt-repository --yes ppa:ethereum/ethereum
sudo apt-get update
sudo apt-get install solc

rustup toolchain install nightly

cargo install cargo-nextest
cargo install sqlx-cli

yarn global add zksync-cli