# Copy nodle-l2-testnet.env file
echo "Copying nodle-l2-testnet.env file..."
cp ./envs/nodle-l2-testnet.env $ZKSYNC_HOME/etc/env/.init.env
cp ./envs/nodle-l2-testnet.env $ZKSYNC_HOME/etc/env/

#create .current file
echo "Creating .current file..."
touch $ZKSYNC_HOME/etc/env/.current

# add content from env to .current file
echo "Adding content to .current file..."
echo "nodle-l2-testnet.env" > $ZKSYNC_HOME/etc/env/.current

cd $ZKSYNC_HOME

# Start zk tools
echo "Starting zk tools..."
zk init
