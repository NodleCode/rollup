#!/bin/bash

# Get the address from .nft-contract-address file
address=$(cat ../contracts/.nft-contract-address)

if [ -z "$address" ]
then
      echo "Factory address is empty. Please run yarn deploy-local first."
      exit 1
fi

# Replace the old address in the generated/*.yaml files
echo "Adding address $address to generated/*.yaml files..."
sed -i "s/address: \".*\"/address: \"$address\"/g" generated/content-sign.subgraph.yaml

# run the build command and deploy command
yarn build
echo "Graph build completed. Deploying to local graph node..."
graph deploy --node http://graph-node:8020/ --ipfs http://ipfs:5001 --version-label v0.0.1 content-sign generated/content-sign.subgraph.yaml
echo "Graph local deployed."

