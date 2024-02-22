#!/bin/bash

# Install SQLx CLI
echo "Installing SQLx CLI..."
cargo install sqlx-cli --version 0.7.3

# Stop default PostgreSQL (if running)
echo "Stopping default PostgreSQL..."
sudo systemctl stop postgresql

echo "Installation complete."

# install and build zk tool

echo "export ZKSYNC_HOME=/home/$USER/zksync-era/repo" >> ~/.zshrc
echo "export PATH=\$ZKSYNC_HOME/bin:\$PATH" >> ~/.zshrc

source ~/.zshrc

# clean yarn cache 
yarn cache clean --force

export DOCKER_DEFAULT_PLATFORM=linux/amd64

export VERSION=`./.devcontainer/version.sh matter-labs zksync-era`
git clone https://github.com/matter-labs/zksync-era $ZKSYNC_HOME
cd $ZKSYNC_HOME
git checkout $VERSION

sudo mkdir -p $ZKSYNC_HOME/volumes || true
sudo chown -R $USER:$USER $ZKSYNC_HOME/volumes

# Build latest version of zk tools
echo "Building latest version of zk tools..."
zk
