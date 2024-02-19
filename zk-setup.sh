#!/bin/bash

# Install SQLx CLI
echo "Installing SQLx CLI..."
cargo install sqlx-cli --version 0.7.3

# Stop default PostgreSQL (if running)
echo "Stopping default PostgreSQL..."
sudo systemctl stop postgresql

echo "Installation complete."

# Copy hyperchain-custom.env file
echo "Copying hyperchain-custom.env file..."
cp envs/hyperchain-custom.env $ZKSYNC_HOME/etc/env/.init.env
cp envs/hyperchain-custom.env $ZKSYNC_HOME/etc/env/

#create .current file
echo "Creating .current file..."
touch zksync-era/etc/env/.current

cd $ZKSYNC_HOME


# Build latest version of zk tools
echo "Building latest version of zk tools..."
zk

# Start the wizard to set up and deploy your new hyperchain
echo "Starting the wizard to set up and deploy your new hyperchain..."
zk stack init
