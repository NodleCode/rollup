#!/bin/bash

set -o allexport
source ../contracts/.contracts.env
set +o allexport

if [ -z "$NFT_ADDRESS" ]
then
      echo "Factory address is empty. Please make sure you have deployed the contract"
      exit 1
fi

# Replace the old address in the src/*.yaml files
echo "Adding addresses $NFT_ADDRESS and $WHITELIST_PAYMASTER_ADDRESS to src/*.yaml files..."
node ./prepare.js

# run the build command and deploy command
yarn build
echo "Graph build completed. Deploying to local graph node..."
graph create --node http://graph-node:8020/ content-sign
graph deploy --node http://graph-node:8020/ --ipfs http://ipfs:5001 --version-label v0.0.1 content-sign src/content-sign.subgraph.yaml
echo "Graph local deployed."

