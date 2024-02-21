#!/bin/bash

set -o allexport
source ../contracts/.contracts.env
set +o allexport

if [ -z "$NFT_ADDRESS" ]
then
      echo "Factory address is empty. Please make sure you have deployed the contract"
      exit 1
fi

# Replace the old address in the generated/*.yaml files
echo "Adding address $NFT_ADDRESS to generated/*.yaml files..."
sed -i "s/address: \".*\"/address: \"$NFT_ADDRESS\"/g" generated/content-sign.subgraph.yaml

# run the build command and deploy command
yarn build
echo "Graph build completed. Deploying to local graph node..."
graph create --node http://graph-node:8020/ content-sign
graph deploy --node http://graph-node:8020/ --ipfs http://ipfs:5001 --version-label v0.0.1 content-sign generated/content-sign.subgraph.yaml
echo "Graph local deployed."

