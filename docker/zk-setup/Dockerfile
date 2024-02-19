# Use an official Ubuntu image as the base image
FROM debian:bookworm-slim

USER root

# Install git and other required packages
RUN apt-get update && apt-get install -y \
    git \
    curl \
    bash \
    sudo

# apt-get install -y build-essential pkg-config cmake clang lldb lld libssl-dev postgresql axel
RUN apt-get update && apt-get install -y \
    build-essential \
    pkg-config \
    cmake \
    clang \
    lldb \
    lld \
    libssl-dev \
    postgresql \
    axel

# cargo install sqlx-cli --version 0.7.3
# RUN /bin/bash -c "source /root/.cargo/env && cargo install sqlx-cli --version 0.7.3"

# Install curl and other dependencies required for NVM and Node.js
RUN apt-get update && \
    apt-get install -y curl bash build-essential

# Install NVM (Node Version Manager)
RUN curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.1/install.sh | bash

# Set NVM environment variables
ENV NVM_DIR /root/.nvm
ENV SH_ENV /root/.bashrc

# Load NVM
RUN . $NVM_DIR/nvm.sh && \
    nvm install node && \
    nvm alias default node

# Install Yarn
RUN . $NVM_DIR/nvm.sh && \
    npm install -g yarn

# Display NVM and Yarn versions for verification
RUN . $NVM_DIR/nvm.sh && \
    echo "NVM version: $(nvm --version)" && \
    echo "Node.js version: $(node --version)" && \
    echo "Yarn version: $(yarn --version)"


# Set working directory
WORKDIR /app

# Copy the setup script and the hyperchain-custom.env file
COPY zk-setup.sh .
COPY envs/ /app/envs/

# Set execute permissions for the setup script
RUN chmod +x zk-setup.sh

# Run the setup script when the container starts
CMD ["./zk-setup.sh"]

