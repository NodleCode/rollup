import assert from "assert";
import { fetchAccount } from "../utils/utils";
import { ProposalVote } from "../types";
import {
  GrantedLog,
  VoteStartedLog,
  VotedLog,
} from "../types/abi-interfaces/GrantsMigrationAbi";
import { fetchProposal, fetchContract, fetchGrantProposal } from "../utils/migration";

export async function handleGrantsVoteStarted(
  event: VoteStartedLog
): Promise<void> {
  if (!event.args) {
    logger.error("No event.args");
    return;
  }

  const contract = await fetchContract(event.address);
  if (contract) {
    const timestamp = event.block.timestamp * BigInt(1000);
    const proposalId = event.args.proposal.toString();
    const recipient = await fetchAccount(event.args.user, timestamp);
    const initiator = await fetchAccount(event.args.oracle, timestamp);
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
    const timestamp = event.block.timestamp * BigInt(1000);
    const voter = await fetchAccount(event.args.oracle, timestamp);
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
