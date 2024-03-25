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

ADD ./install-tools.sh /tmp/install-tools.sh
RUN /tmp/install-tools.sh

ENTRYPOINT [ "zsh" ]