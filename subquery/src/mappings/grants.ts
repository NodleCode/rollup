import {
  VestingSchedule,
  VestingScheduleCanceled,
  VestingScheduleClaimed,
  VestingScheduleRenounced,
} from "../types";
import {
  ClaimedLog,
  RenouncedLog,
  VestingScheduleAddedLog,
  VestingSchedulesCanceledLog,
} from "../types/abi-interfaces/GrantsAbi";
import { fetchTransaction } from "../utils/utils";

export async function handleClaimed(event: ClaimedLog): Promise<void> {
  if (!event.args) {
    logger.error("No event.args");
    return;
  }

  const who = event.args.who?.toString();
  const amount = event.args.amount?.toBigInt();
  const id = event.transactionHash + "-" + event.logIndex.toString();
  const start = event.args.start?.toBigInt();
  const end = event.args.end?.toBigInt();

  const transaction = await fetchTransaction(
    event.transactionHash,
    event.block.timestamp,
    BigInt(event.block.number)
  );

  const claimTransaction = new VestingScheduleClaimed(id, who, transaction.id);

  claimTransaction.amount = amount;
  claimTransaction.start = start;
  claimTransaction.end = end;

  await claimTransaction.save();
}

export async function handleRenounced(event: RenouncedLog): Promise<void> {
  if (!event.args) {
    logger.error("No event.args");
    return;
  }

  const to = event.args.to.toString();
  const from = event.args.from.toString();
  const start = event.args.start?.toBigInt();
  const end = event.args.end?.toBigInt();
  const id = event.transactionHash + "-" + event.logIndex.toString();
  const transaction = await fetchTransaction(
    event.transactionHash,
    event.block.timestamp,
    BigInt(event.block.number)
  );

  const action = new VestingScheduleRenounced(id, to, transaction.id);

  action.start = start;
  action.end = end;

  const schedules = await VestingSchedule.getByCancelAuthorityId(from, { limit: 100 });

  if (schedules && schedules.length > 0) {
    schedules.forEach((schedule) => {
      schedule.cancelAuthorityId = undefined;
      schedule.cancelled = true;
      schedule.cancelTimestamp = event.block.timestamp * BigInt(1000);
      schedule.cancelTransactionId = transaction.id;
    });

    await store.bulkUpdate("VestingSchedule", schedules);
    action.affectedVestingSchedules = schedules?.map((schedule) => schedule.id);
  }

  action.cancelAuthorityId = from;

  action.save();
}

export async function handleVestingScheduleAdded(
  event: VestingScheduleAddedLog
): Promise<void> {
  if (!event.args) {
    logger.error("No event.args");
    return;
  }

  const id = event.transactionHash + "-" + event.logIndex.toString();
  const to = event.args.to.toString();
  const schedule = event.args.schedule;
  const transaction = await fetchTransaction(
    event.transactionHash,
    event.block.timestamp,
    BigInt(event.block.number)
  );

  const vestingSchedule = new VestingSchedule(id, to, transaction.id);

  vestingSchedule.start = schedule.start.toBigInt();
  vestingSchedule.period = schedule.period.toBigInt();
  vestingSchedule.periodCount = schedule.periodCount;
  vestingSchedule.perPeriodAmount = schedule.perPeriodAmount.toBigInt();

  vestingSchedule.cancelAuthorityId = schedule.cancelAuthority?.toString();

  await vestingSchedule.save();
}

export async function handleVestingSchedulesCanceled(
  event: VestingSchedulesCanceledLog
): Promise<void> {
  if (!event.args) {
    logger.error("No event.args");
    return;
  }

  const from = event.args.from.toString();
  const to = event.args.to.toString();
  const start = event.args.start?.toBigInt();
  const end = event.args.end?.toBigInt();
  const id = event.transactionHash + "-" + event.logIndex.toString();

  const transaction = await fetchTransaction(
    event.transactionHash,
    event.block.timestamp,
    BigInt(event.block.number)
  );

  const action = new VestingScheduleCanceled(id, to, transaction.id);

  action.start = start;
  action.end = end;

  const schedules = await VestingSchedule.getByCancelAuthorityId(from, { limit: 100 });

  if (schedules && schedules.length > 0) {
    schedules?.forEach((schedule) => {
      schedule.cancelled = true;
      schedule.cancelTimestamp = event.block.timestamp * BigInt(1000);
      schedule.cancelTransactionId = transaction.id;
    });

    await store.bulkUpdate("VestingSchedule", schedules);
    action.affectedVestingSchedules = schedules?.map((schedule) => schedule.id);
  }

  action.cancelAuthorityId = from;

  action.save();
}
