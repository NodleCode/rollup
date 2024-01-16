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

# install and build zk tool
export ZKSYNC_HOME=/home/$USER/zksync-era
export PATH=$ZKSYNC_HOME/bin:$PATH

git clone https://github.com/matter-labs/zksync-era $ZKSYNC_HOME
cd $ZKSYNC_HOME
git checkout core-v19.1.1 # TODO: update to auto select latest release?
mkdir -p $ZKSYNC_HOME/volumes || true
sudo chown -R $USER:$USER $ZKSYNC_HOME/volumes
zk