import {
  ProposalVote,
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
import {
  GrantedLog,
  VoteStartedLog,
  VotedLog,
} from "../types/abi-interfaces/GrantsMigrationAbi";
import { fetchContract, fetchGrantProposal } from "../utils/migration";
import { fetchAccount, fetchTransaction } from "../utils/utils";

export async function handleGranted(event: GrantedLog): Promise<void> {
  if (!event.args) {
    logger.error("No event.args");
    return;
  }
  const proposalId = event.args.proposal?.toString();

  const proposal = await fetchGrantProposal(proposalId);
  if (proposal) {
    proposal.granted = true;

    await proposal.save();
  }
}

export async function handleGrantsVoteStarted(
  event: VoteStartedLog
): Promise<void> {
  if (!event.args) {
    logger.error("No event.args");
    return;
  }

  const contract = await fetchContract(event.address);
  if (contract) {
    const proposalId = event.args.proposal.toString();
    const recipient = await fetchAccount(event.args.user);
    const initiator = await fetchAccount(event.args.oracle);
    const timestamp = event.block.timestamp * BigInt(1000);
    const hash = event.transaction.hash;

    const proposal = await fetchGrantProposal(proposalId);

    proposal.contractId = contract.id;
    proposal.proposal = proposalId;
    proposal.timestamp = timestamp;
    proposal.hash = hash;
    proposal.recipientId = recipient.id;
    proposal.amount = event.args.amount.toBigInt();
    proposal.initiatorId = initiator.id;

    await proposal.save();
  }
}

export async function handleGrantsVoted(event: VotedLog): Promise<void> {
  if (!event.args) {
    logger.error("No event.args");
    return;
  }
  const proposalId = event.args.proposal?.toString();

  const proposal = await fetchGrantProposal(proposalId);
  if (proposal) {
    const voter = await fetchAccount(event.args.oracle);
    const timestamp = event.block.timestamp * BigInt(1000);
    const hash = event.transaction.hash;

    const vote = new ProposalVote(
      proposal.id.concat("/").concat(voter.id),
      proposal.id,
      voter.id,
      timestamp
    );

    vote.timestamp = timestamp;
    vote.hash = hash;

    await vote.save();
  }
}

export async function handleClaimed(event: ClaimedLog): Promise<void> {
  if (!event.args) {
    logger.error("No event.args");
    return;
  }

  const who = event.args.who?.toString();
  const amount = event.args.amount?.toBigInt();
  const id = event.transactionHash + "-" + event.logIndex.toString();

  const transaction = await fetchTransaction(
    event.transactionHash,
    event.block.timestamp,
    BigInt(event.block.number)
  );

  const claimTransaction = new VestingScheduleClaimed(id, who, transaction.id);

  claimTransaction.amount = amount;

  await claimTransaction.save();
}

export async function handleRenounced(event: RenouncedLog): Promise<void> {
  if (!event.args) {
    logger.error("No event.args");
    return;
  }

  const to = event.args.to.toString();
  const from = event.args.from.toString();
  const id = event.transactionHash + "-" + event.logIndex.toString();
  const transaction = await fetchTransaction(
    event.transactionHash,
    event.block.timestamp,
    BigInt(event.block.number)
  );

  const action = new VestingScheduleRenounced(id, to, transaction.id);

  const schedules = await VestingSchedule.getByCancelAuthorityId(from);

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
  logger.info("schedule: " + JSON.stringify(schedule) + " to: " + to);
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
  const id = event.transactionHash + "-" + event.logIndex.toString();

  const transaction = await fetchTransaction(
    event.transactionHash,
    event.block.timestamp,
    BigInt(event.block.number)
  );

  const action = new VestingScheduleCanceled(id, to, transaction.id);

  const schedules = await VestingSchedule.getByCancelAuthorityId(from);

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
