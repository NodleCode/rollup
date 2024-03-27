FROM mcr.microsoft.com/devcontainers/base:jammy

USER vscode

ENV NODE_VERSION=20.11.1
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

ENV PATH="${PATH}:/home/vscode/.cargo/bin:/home/vscode/.yarn/bin:/home/vscode/.foundry/bin:/home/vscode/.nvm/versions/node/v${NODE_VERSION}/bin"

RUN sudo apt update && \
    sudo apt install -y software-properties-common && \
    sudo add-apt-repository ppa:ethereum/ethereum && \
    sudo apt update && \
    sudo apt install --yes \
    pkg-config build-essential cmake \
    clang libssl-dev libclang-dev \
    docker-compose software-properties-common \
    solc && \
    rm -rf /var/lib/apt/lists/* && \
    sudo apt clean

RUN yarn global add zksync-cli && yarn global add @graphprotocol/graph-cli

RUN git clone https://github.com/matter-labs/foundry-zksync.git /tmp/foundry-zksync && \
    cd /tmp/foundry-zksync && \
    cargo install --path ./crates/forge --profile local --force --locked && \
    cargo install --path ./crates/cast --profile local --force --locked && \
    rm -rf /tmp/foundry-zksync

ENTRYPOINT [ "zsh" ]