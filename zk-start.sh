# Copy hyperchain-custom.env file
echo "Copying hyperchain-custom.env file..."
cp ./envs/hyperchain-custom.env $ZKSYNC_HOME/etc/env/.init.env
cp ./envs/hyperchain-custom.env $ZKSYNC_HOME/etc/env/

#create .current file
echo "Creating .current file..."
touch $ZKSYNC_HOME/etc/env/.current

# add content from env to .current file
echo "Adding content to .current file..."
echo "hyperchain-custom.env" > $ZKSYNC_HOME/etc/env/.current

cd $ZKSYNC_HOME

export DOCKER_DEFAULT_PLATFORM=linux/amd64


# Start zk tools
echo "Starting zk tools..."
zk init
