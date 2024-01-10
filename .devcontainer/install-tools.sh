#!/bin/bash

sudo apt update
sudo apt install --yes pkg-config libssl-dev libclang-dev docker-compose

rustup toolchain install nightly

yarn global add zksync-cli
# cargo +nightly install --git https://github.com/matter-labs/foundry-zksync --force zkcast zkforge

# mkdir -p $HOME/.local/share/bash-completion/completions
# zkforge completions bash > $HOME/.local/share/bash-completion/completions/zkforge
# zkcast completions bash > $HOME/.local/share/bash-completion/completions/zkcast