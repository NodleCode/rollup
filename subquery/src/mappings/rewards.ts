import { Reward } from "../types";
import {
  MintBatchRewardTransaction,
  MintRewardTransaction,
} from "../types/abi-interfaces/RewardsAbi";
import { fetchAccount, fetchTransaction } from "../utils/utils";

export async function handleMintReward(
  call: MintRewardTransaction
): Promise<void> {
  const signature = call.args![1];
  const reward = call.args![0];

  if (!!reward && !!signature) {
    const amount = reward.amount;
    const recipient = await fetchAccount(reward.recipient);
    const sequence = reward.sequence;
    const sender = await fetchAccount(call.from);
    const id = call.hash + "/" + call.transactionIndex.toString();
    const receipt = await call.receipt();

    const status = receipt?.status;

    const transaction = await fetchTransaction(
      call.hash,
      call.blockTimestamp * BigInt(1000),
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
  const _rewards = call.args![0];
  const signature = call.args![1];

  if (!!_rewards && !!signature) {
    const amounts = _rewards.amounts;
    const recipients = _rewards.recipients;
    const sequence = _rewards.sequence;

    const sender = await fetchAccount(call.from);
    const id = call.hash + "/" + call.transactionIndex.toString();
    const receipt = await call.receipt();

    const status = receipt?.status;

    const transaction = await fetchTransaction(
      call.hash,
      call.blockTimestamp * BigInt(1000),
      BigInt(call.blockNumber)
    );

    const toSave: Reward[] = [];
    recipients.forEach(async (recipient, index) => {
      const account = await fetchAccount(recipient);
      const object = new Reward(id, sender.id, account.id, transaction.id);
      object.amount = BigInt(amounts[index].toString());
      object.sequence = BigInt(sequence.toString());
      object.signature = signature.toString();
      object.status = status;

      toSave.push(object);
    });

    store.bulkCreate("Reward", toSave);
  }
}
