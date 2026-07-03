FROM mcr.microsoft.com/devcontainers/base:jammy

USER vscode

ENV NODE_VERSION=22.13.0
RUN curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash && \
    export NVM_DIR="$HOME/.nvm" && \
    [ -s "$NVM_DIR/nvm.sh" ] && \
    \. "$NVM_DIR/nvm.sh" && \
    nvm install ${NODE_VERSION} && \
    nvm use v${NODE_VERSION} && \
    nvm alias default v${NODE_VERSION} && \
    npm install -g yarn
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | zsh -s -- -y && \
    . "$HOME/.cargo/env" && \
    rustup toolchain install stable

ENV PATH="${PATH}:/home/vscode/.cargo/bin:/home/vscode/.yarn/bin:/home/vscode/.foundry/bin:/home/vscode/.nvm/versions/node/v${NODE_VERSION}/bin:/home/vscode/.solc"

RUN sudo apt update && \
    sudo apt install --yes \
    pkg-config build-essential cmake \
    clang libssl-dev libclang-dev \
    docker-compose software-properties-common && \
    sudo rm -rf /var/lib/apt/lists/* && \
    sudo apt clean

RUN yarn global add zksync-cli && yarn global add @graphprotocol/graph-cli

ARG KNOWN_GOOD_FORGE_COMMIT=574943e798a1351735e6535453141fdddf123808
RUN git clone https://github.com/matter-labs/foundry-zksync.git /tmp/foundry-zksync && \
    cd /tmp/foundry-zksync && \
    git checkout ${KNOWN_GOOD_FORGE_COMMIT} && \
    cargo install --path ./crates/forge --force --locked && \
    cargo install --path ./crates/cast --force --locked && \
    rm -rf /tmp/foundry-zksync

ENTRYPOINT [ "zsh" ]
