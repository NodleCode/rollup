# Use Debian as base image
FROM debian:bullseye-slim

# Install git and other required packages
RUN apt-get update && apt-get install -y \
    git \
    curl \
    bash \
    && rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /app

# Copy the setup script and the hyperchain-custom.env file
COPY setup_zk_stack.sh .
COPY envs/ /app/envs/

# Set execute permissions for the setup script
RUN chmod +x setup_zk_stack.sh

# Run the setup script when the container starts
CMD ["./setup_zk_stack.sh"]
