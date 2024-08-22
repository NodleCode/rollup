import { ProposalVote } from "../types";
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
import { fetchAccount } from "../utils/utils";

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
}

export async function handleRenounced(event: RenouncedLog): Promise<void> {
  if (!event.args) {
    logger.error("No event.args");
    return;
  }
}

export async function handleVestingScheduleAdded(
  event: VestingScheduleAddedLog
): Promise<void> {
  if (!event.args) {
    logger.error("No event.args");
    return;
  }
}

export async function handleVestingSchedulesCanceled(
  event: VestingSchedulesCanceledLog
): Promise<void> {
  if (!event.args) {
    logger.error("No event.args");
    return;
  }
}
