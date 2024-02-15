#!/bin/bash

# Install Docker
echo "Installing Docker..."
sudo apt-get update
sudo apt-get install -y docker.io
sudo systemctl start docker
sudo systemctl enable docker

# Add current user to docker group
sudo usermod -aG docker $(whoami)

# Install Rust
echo "Installing Rust..."
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh

# Install NVM
echo "Installing NVM..."
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.5/install.sh | bash

# Install build tools and other dependencies
echo "Installing build tools and other dependencies..."
sudo apt-get install -y build-essential pkg-config cmake clang lldb lld libssl-dev postgresql axel

# Install Node.js and Yarn
echo "Installing Node.js and Yarn..."
source ~/.bashrc  # Reload .bashrc to use nvm
nvm install 18
npm install -g yarn
yarn set version 1.22.19

# Install SQLx CLI
echo "Installing SQLx CLI..."
cargo install sqlx-cli --version 0.7.3

# Stop default PostgreSQL (if running)
echo "Stopping default PostgreSQL..."
sudo systemctl stop postgresql

echo "Installation complete."

# Clone the zksync-era repo
echo "Cloning zksync-era repo..."
git clone https://github.com/matter-labs/zksync-era

# Copy hyperchain-custom.env file
echo "Copying hyperchain-custom.env file..."
cp envs/hyperchain-custom.env zksync-era/envs/

cd zksync-era

# Add ZKSYNC_HOME to your path
echo "Adding ZKSYNC_HOME to your path..."
export ZKSYNC_HOME=$(pwd)
echo "export ZKSYNC_HOME=$ZKSYNC_HOME" >> ~/.bashrc
echo "export PATH=\$ZKSYNC_HOME/bin:\$PATH" >> ~/.bashrc
source ~/.bashrc

# Build latest version of zk tools
echo "Building latest version of zk tools..."
zk

# Start the wizard to set up and deploy your new hyperchain
echo "Starting the wizard to set up and deploy your new hyperchain..."
zk stack init
