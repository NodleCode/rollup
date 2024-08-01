import { fetchContract } from "../utils/erc20";
import { ApprovalLog, TransferLog } from "../types/abi-interfaces/Erc20Abi";
import { fetchAccount, fetchTransaction } from "../utils/utils";
import { ERC20Approval, ERC20Transfer } from "../types";

export async function handleERC20Transfer(event: TransferLog): Promise<void> {
  if (!event.args) {
    logger.error("No event.args");
    return;
  }
 // logger.info("handleERC20Transfer");

  const contract = await fetchContract(event.address);
  if (contract) {
    const from = await fetchAccount(event.args.from);
    const to = await fetchAccount(event.args.to);
    const emmiter = await fetchAccount(event.transaction.from);
    const value = event.args.value.toBigInt();
    const timestamp = event.block.timestamp * BigInt(1000);
    const hash = event.transaction.hash;

    const transfer = await fetchTransaction(
      hash,
      timestamp,
      BigInt(event.blockNumber)
    );

    const transferEvent = new ERC20Transfer(
      contract.id
        .concat("/")
        .concat(hash)
        .concat("/")
        .concat(`${event.logIndex}`),
      emmiter.id,
      transfer.id,
      timestamp,
      from.id,
      to.id,
      value
    );

    transferEvent.hash = hash;
    transferEvent.contractId = contract.id;
    transferEvent.emitterId = emmiter.id;
    //logger.info("Saving transferEvent");
    return transferEvent.save()
  }
}

export async function handleERC20Approval(event: ApprovalLog): Promise<void> {
  if (!event.args) {
    logger.error("No event.args");
    return;
  }
  // logger.info("handleERC20Approval");

  const contract = await fetchContract(event.address);
  if (contract) {
    const owner = await fetchAccount(event.args.owner);
    const spender = await fetchAccount(event.args.spender);
    const value = event.args.value.toBigInt();
    const timestamp = event.block.timestamp * BigInt(1000);
    const hash = event.transaction.hash;
    const emmiter = await fetchAccount(event.transaction.from);

    const transfer = await fetchTransaction(
      hash,
      timestamp,
      BigInt(event.blockNumber)
    );

    const approval = new ERC20Approval(
      contract.id.concat("/").concat(hash),
      emmiter.id,
      transfer.id,
      timestamp,
      owner.id,
      spender.id,
      value
    );

    approval.contractId = contract.id;
    approval.hash = hash;

    return approval.save()
  }
}
