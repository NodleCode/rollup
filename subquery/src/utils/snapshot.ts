import { Account, AccountSnapshot, StatSnapshot } from "../types";
import { TransferLog } from "../types/abi-interfaces/NODLAbi";
import { MintBatchRewardTransaction } from "../types/abi-interfaces/RewardsAbi";

function getDayString(timestamp: bigint) {
  const date = new Date(Number(timestamp));

  // dd-mm-yyyy
  return `${date.getDate()}-${date.getMonth() + 1}-${date.getFullYear()}`;
}

export async function handleSnapshot(
  event: TransferLog,
  account: Account,
  amount: bigint
): Promise<void> {
  const txHash = event.transaction.hash;
  const timestamp = event.block.timestamp * BigInt(1000);
  const dayTimestamp = getDayString(timestamp);
  const dailySnapshotId = `${account.id}-${timestamp}-${txHash}`;

  const dailySnapshot = new AccountSnapshot(
    dailySnapshotId,
    account.id,
    dayTimestamp,
    timestamp
  );

  dailySnapshot.balance = account.balance;

  if (amount > BigInt(0)) {
    dailySnapshot.transferCount = 1;
    dailySnapshot.transferAmount = amount;
  }

  dailySnapshot.save();
}

export async function handleSnapshotMintBatchReward(
  event: MintBatchRewardTransaction,
  account: Account,
  reward: bigint
): Promise<void> {
  const txHash = event.hash;
  const timestamp = event.blockTimestamp * BigInt(1000);
  const dayTimestamp = getDayString(timestamp);
  const dailySnapshotId = `${account.id}-${timestamp}-${txHash}`;

  const dailySnapshot = new AccountSnapshot(
    dailySnapshotId,
    account.id,
    dayTimestamp,
    timestamp
  );

  dailySnapshot.rewardCount = 1;
  dailySnapshot.rewardAmount = reward;

  dailySnapshot.save();
}

export const handleStatSnapshot = async (timestamp: bigint, transferAmount: bigint, rewardAmount: bigint, newWallets: number) => {
  const dayDate = getDayString(timestamp);
  let snapshot = await StatSnapshot.get(dayDate);

  if (!snapshot) {
    snapshot = new StatSnapshot(dayDate, 0, BigInt(0), 0, BigInt(0), 0);
    snapshot.dayDate = new Date(Number(timestamp));
  }

  snapshot.totalTransferAmount += transferAmount;
  snapshot.totalRewardAmount += rewardAmount;
  if (transferAmount > BigInt(0)) {
    snapshot.totalTransfers++;
  }
  if (rewardAmount > BigInt(0)) {
    snapshot.totalRewards++;
  }
  snapshot.newWallets += newWallets;

  snapshot.save();
};
