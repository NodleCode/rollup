import { fetchAccount } from "../erc721/erc721";
import { ApprovalLog, TransferLog } from "../types/abi-interfaces/IERC721Metadata";


export function handleTransfer(event: TransferLog): Promise<void>  {
  logger.info('Transfer event:', event)

  return Promise.resolve()
}

export function handleApproval(event: ApprovalLog): Promise<void>  {
  logger.info("Transfer event:", event);
  // const account = fetchAccount();

  return Promise.resolve()
}

export function handleApprovalForAll(event: any): Promise<void>  {
  logger.info("Transfer event:", event);
  return Promise.resolve();
}
