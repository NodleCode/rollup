import { Reward, Wallet } from "../types";
import {
  MintBatchRewardTransaction,
  MintRewardTransaction,
} from "../types/abi-interfaces/RewardsAbi";
import {
  handleSnapshotMintBatchReward,
  handleStatSnapshot,
} from "../utils/snapshot";
import { fetchAccount, fetchTransaction } from "../utils/utils";

export async function handleMintReward(
  call: MintRewardTransaction
): Promise<void> {
  const receipt = await call.receipt();

  if (!receipt.status) {
    // skip failed transactions
    return;
  }

  if (!call.args || !call.logs) {
    throw new Error("No tx.args or tx.logs");
  }

  const signature = call.args![1];
  const reward = call.args![0];

  if (!!reward && !!signature) {
    const amount = reward.amount;
    const timestamp = call.blockTimestamp * BigInt(1000);
    const recipient = await fetchAccount(reward.recipient, timestamp);
    const sequence = reward.sequence;
    const sender = await fetchAccount(call.from, timestamp);
    const id = call.hash + "/" + call.transactionIndex.toString();
    const receipt = await call.receipt();

    // Create wallet
    let newWallet = 0;
    const toWallet = await Wallet.get(recipient.id);
    if (!toWallet) {
      newWallet = 1;
      const wallet = new Wallet(recipient.id, recipient.id, timestamp);
      wallet.save();
    }

    const status = receipt?.status;

    if (status) {
      await Promise.all([
        handleSnapshotMintBatchReward(
          call as any,
          recipient,
          BigInt(amount.toString())
        ),
        handleStatSnapshot(
          timestamp,
          BigInt(0),
          BigInt(amount.toString()),
          newWallet
        ),
      ]);
    }

    const transaction = await fetchTransaction(
      call.hash,
      timestamp,
      BigInt(call.blockNumber)
    );

    const toSave = new Reward(id, sender.id, recipient.id, transaction.id);

    toSave.amount = BigInt(amount.toString());
    toSave.sequence = BigInt(sequence.toString());
    toSave.signature = signature.toString();
    toSave.status = status;

    await toSave.save();
  }
}

export async function handleMintBatchReward(
  call: MintBatchRewardTransaction
): Promise<void> {
  const receipt = await call.receipt();

  if (!receipt.status) {
    // skip failed transactions
    return;
  }

  if (!call.args || !call.logs) {
    throw new Error("No tx.args or tx.logs");
  }

  const _rewards = call.args![0];
  const signature = call.args![1];

  if (!!_rewards && !!signature) {
    const amounts = _rewards.amounts;
    const recipients = _rewards.recipients;
    const sequence = _rewards.sequence;
    const timestamp = call.blockTimestamp * BigInt(1000);
    const sender = await fetchAccount(call.from, timestamp);
    const id = call.hash + "/" + call.transactionIndex.toString();
    const receipt = await call.receipt();

    const status = receipt?.status;

    const transaction = await fetchTransaction(
      call.hash,
      timestamp,
      BigInt(call.blockNumber)
    );

    const toSave: Reward[] = [];
    const walletsToSave: Wallet[] = [];
    recipients.forEach(async (recipient, index) => {
      const account = await fetchAccount(recipient, timestamp);

      const toWallet = await Wallet.get(account.id);
      let newWallets = 0;
      if (!toWallet) {
        newWallets = 1;
        const wallet = new Wallet(account.id, account.id, timestamp);
        walletsToSave.push(wallet);
      }
      const object = new Reward(id, sender.id, account.id, transaction.id);
      object.amount = BigInt(amounts[index].toString());
      object.sequence = BigInt(sequence.toString());
      object.signature = signature.toString();
      object.status = status;
      if (status) {
        await Promise.all([
          handleSnapshotMintBatchReward(call, account, object.amount),
          handleStatSnapshot(timestamp, BigInt(0), object.amount, newWallets),
        ]);
      }
      toSave.push(object);
    });

    store.bulkCreate("Wallet", walletsToSave);
    store.bulkCreate("Reward", toSave);
  }
}
