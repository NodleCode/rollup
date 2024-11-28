import { Account, AccountSnapshot, StatSnapshot, UsersLevelsStats } from "../types";
import { TransferLog } from "../types/abi-interfaces/NODLAbi";
import { MintBatchRewardTransaction } from "../types/abi-interfaces/RewardsAbi";

function getDayString(timestamp: bigint) {
  const date = new Date(Number(timestamp));

  // dd-mm-yyyy
  return `${date.getDate()}-${date.getMonth() + 1}-${date.getFullYear()}`;
}

const levelsTrackPoints = [
  100, 1000, 5000, 10000, 25000, 50000, 100000, 500000, 1000000, 5000000,
];

const findCurrentLevelIndex = (balance: bigint) => {
  for (let i = levelsTrackPoints.length - 1; i >= 0; i--) {
    if (balance >= BigInt(levelsTrackPoints[i])) {
      return i;
    }
  }
  return -1;
};

export async function handleLevel(
  balance: bigint,
  prevBalance: bigint,
  timestamp: bigint
) {
  // To be into the next level, the balance must be greater than the level point
  const level = findCurrentLevelIndex(balance);
  const prevLevel = findCurrentLevelIndex(prevBalance);

  if (level === prevLevel) {
    return;
  }
  const toSave = [];
  const levelId = String(level + 1);
  let levelStats = await UsersLevelsStats.get(levelId);
  if (!levelStats) {
    levelStats = new UsersLevelsStats(
      levelId,
      Number(levelId),
      0,
      BigInt(0),
      timestamp,
      timestamp
    );
  }

  levelStats.members++;
  const totalBalanceAccumulated = levelStats.total + balance;
  levelStats.total = totalBalanceAccumulated;
  levelStats.updatedAt = timestamp;
  toSave.push(levelStats);

  if (prevLevel > -1) {
    const prevLevelId = String(prevLevel + 1);
    let prevLevelStats = await UsersLevelsStats.get(prevLevelId);
    if (!prevLevelStats) {
      prevLevelStats = new UsersLevelsStats(
        prevLevelId,
        Number(prevLevelId),
        0,
        BigInt(0),
        timestamp,
        timestamp
      );
    }

    prevLevelStats.members--;
    prevLevelStats.total -= prevBalance;
    prevLevelStats.updatedAt = timestamp;
    toSave.push(prevLevelStats);
  }
  
  Promise.all(toSave.map((s) => s.save()));
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

  dailySnapshot.balance = account.balance || BigInt(0);

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

export const handleStatSnapshot = async (
  timestamp: bigint,
  transferAmount: bigint,
  rewardAmount: bigint,
  newWallets: number
) => {
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
