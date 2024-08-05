import { EthereumBlock } from "@subql/types-ethereum";
import { ERC20Approval, ERC20Transfer, ERC721Transfer } from "../types";
import { ethers } from "ethers";
import { abi, erc721Abi } from "../utils/const";
import { handleApproval, handleTransfer } from "./common";
import { ApprovalLog, TransferLog } from "../types/abi-interfaces/Erc721Abi";

export const handleBlock = async (block: EthereumBlock): Promise<void> => {
  logger.info(`Processing block ${block.number}`);
  const transactions = block.transactions;
  const nftTransfersToSave: ERC721Transfer[] = [];
  const erc20TransfersToSave: ERC20Transfer[] = [];
  const erc20ApprovalsToSave: ERC20Approval[] = [];

  for (const log of block.logs) {
    try {
      const isPossibleERC721 = log.topics.length === 4;
      let iface = new ethers.utils.Interface(
        isPossibleERC721 ? erc721Abi : abi
      );
      let _log = iface.parseLog(log);
      logger.info(`Processing log ${_log.name}`);

      if (_log.name === "Transfer") {
        log.args = _log.args as any;

        const tosave = await handleTransfer(log as TransferLog);

        if (tosave && tosave._name === "ERC20Transfer") {
          erc20TransfersToSave.push(tosave as ERC20Transfer);
        } else if (tosave && tosave._name === "ERC721Transfer") {
          nftTransfersToSave.push(tosave as ERC721Transfer);
        }
      }

      if (_log.name === "Approval") {
        log.args = _log.args as any;
        const tosave = await handleApproval(log as ApprovalLog);

        if (tosave) {
          erc20ApprovalsToSave.push(tosave);
        }
      }
    } catch (error: any) {
      if (error?.reason === "no matching event") {
        // logger.info(`No matching event for log`);
      } else {
        logger.error(`Error processing log: ${JSON.stringify(error)}`);
      }
    }
  }

  await Promise.all([
    nftTransfersToSave.length &&
      store.bulkCreate("ERC721Transfer", nftTransfersToSave),
    erc20TransfersToSave.length &&
      store.bulkCreate("ERC20Transfer", erc20TransfersToSave),
    erc20ApprovalsToSave.length &&
      store.bulkCreate("ERC20Approval", erc20ApprovalsToSave),
  ]);

  logger.info(`Processed block ${block.number}`);
};

/* export const handleContractDeployed = async (
  event: ContractDeployedEvent
): Promise<void> => {
  const [, , contractAddress] = event.args;

  const { symbol, name, isErc721, isErc20 } = await getContractDetails(
    contractAddress
  );

  logger.info(`Contract details: ${symbol}, ${name}, ${isErc721}, ${isErc20}`);

  if (isErc721) {
    const contract = new ERC721Contract(contractAddress, contractAddress);
    contract.isValid = isErc721;
    contract.symbol = symbol;
    contract.name = name;
    return contract.save();
  } else if (isErc20) {
    const contract = new ERC20Contract(contractAddress, contractAddress);
    contract.isValid = isErc20;
    contract.symbol = symbol;
    contract.name = name;
    await contract.save();
  }
}; */
