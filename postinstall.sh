#!/bin/bash

# This script copies OpenZeppelin and zkSync contracts to a place where our contracts look for them when Hardhat compiles them.
# This is needed to allow the same contracts to be compiled by both forge and hardhat.

# Create necessary directories
mkdir -p ./openzeppelin-contracts/contracts ./zksync-contracts

# Copy OpenZeppelin contracts
cp -r node_modules/@openzeppelin/contracts ./openzeppelin-contracts/

# Copy zkSync contracts
cp -r node_modules/@matterlabs/zksync-contracts ./
