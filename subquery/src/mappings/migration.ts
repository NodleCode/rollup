import assert from "assert";
import { fetchAccount } from "../utils/utils";
import { ProposalVote } from "../types";
import {
  VoteStartedLog,
  VotedLog,
  WithdrawnLog,
} from "../types/abi-interfaces/MigrationAbi";
import { fetchProposal, fetchContract } from "../utils/migration";

export async function handleProposal(event: VoteStartedLog): Promise<void> {
  assert(event.args, "No event.args");

  const contract = await fetchContract(event.address);
  if (contract) {
    const proposalId = event.args.proposal.toString();
    const recipient = await fetchAccount(event.args.user);
    const initiator = await fetchAccount(event.args.oracle);
    const timestamp = event.block.timestamp * BigInt(1000);
    const hash = event.transaction.hash;

    const proposal = await fetchProposal(proposalId);

    proposal.contractId = contract.id;
    proposal.timestamp = timestamp;
    proposal.hash = hash;
    proposal.recipientId = recipient.id;
    proposal.amount = event.args.amount.toBigInt();
    proposal.initiatorId = initiator.id;

    await proposal.save();
  }
}

export async function handleVote(event: VotedLog): Promise<void> {
  assert(event.args, "No event.args");
  const proposalId = event.args.proposal?.toString();

  const proposal = await fetchProposal(proposalId);
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

export async function handleWithdrawn(event: WithdrawnLog): Promise<void> {
  assert(event.args, "No event.args");
  const proposalId = event.args.proposal?.toString();

  const proposal = await fetchProposal(proposalId);
  if (proposal) {
    proposal.withdrawn = true;

    await proposal.save();
  }
}
