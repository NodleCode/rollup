// SPDX-License-Identifier: Apache-2.0

// Auto-generated , DO NOT EDIT
import {EthereumLog, EthereumTransaction, LightEthereumLog} from "@subql/types-ethereum";

import {ApprovalEvent, ApprovalForAllEvent, BatchMetadataUpdateEvent, MetadataUpdateEvent, TransferEvent, Erc721Abi} from '../contracts/Erc721Abi'


export type ApprovalLog = EthereumLog<ApprovalEvent["args"]>

export type ApprovalForAllLog = EthereumLog<ApprovalForAllEvent["args"]>

export type BatchMetadataUpdateLog = EthereumLog<BatchMetadataUpdateEvent["args"]>

export type MetadataUpdateLog = EthereumLog<MetadataUpdateEvent["args"]>

export type TransferLog = EthereumLog<TransferEvent["args"]>


export type LightApprovalLog = LightEthereumLog<ApprovalEvent["args"]>

export type LightApprovalForAllLog = LightEthereumLog<ApprovalForAllEvent["args"]>

export type LightBatchMetadataUpdateLog = LightEthereumLog<BatchMetadataUpdateEvent["args"]>

export type LightMetadataUpdateLog = LightEthereumLog<MetadataUpdateEvent["args"]>

export type LightTransferLog = LightEthereumLog<TransferEvent["args"]>


export type ApproveTransaction = EthereumTransaction<Parameters<Erc721Abi['functions']['approve']>>

export type BalanceOfTransaction = EthereumTransaction<Parameters<Erc721Abi['functions']['balanceOf']>>

export type GetApprovedTransaction = EthereumTransaction<Parameters<Erc721Abi['functions']['getApproved']>>

export type IsApprovedForAllTransaction = EthereumTransaction<Parameters<Erc721Abi['functions']['isApprovedForAll']>>

export type NameTransaction = EthereumTransaction<Parameters<Erc721Abi['functions']['name']>>

export type NextTokenIdTransaction = EthereumTransaction<Parameters<Erc721Abi['functions']['nextTokenId']>>

export type OwnerOfTransaction = EthereumTransaction<Parameters<Erc721Abi['functions']['ownerOf']>>

export type SafeMintTransaction = EthereumTransaction<Parameters<Erc721Abi['functions']['safeMint']>>

export type SafeTransferFrom_address_address_uint256_Transaction = EthereumTransaction<Parameters<Erc721Abi['functions']['safeTransferFrom(address,address,uint256)']>>

export type SafeTransferFrom_address_address_uint256_bytes_Transaction = EthereumTransaction<Parameters<Erc721Abi['functions']['safeTransferFrom(address,address,uint256,bytes)']>>

export type SetApprovalForAllTransaction = EthereumTransaction<Parameters<Erc721Abi['functions']['setApprovalForAll']>>

export type SupportsInterfaceTransaction = EthereumTransaction<Parameters<Erc721Abi['functions']['supportsInterface']>>

export type SymbolTransaction = EthereumTransaction<Parameters<Erc721Abi['functions']['symbol']>>

export type TokenURITransaction = EthereumTransaction<Parameters<Erc721Abi['functions']['tokenURI']>>

export type TransferFromTransaction = EthereumTransaction<Parameters<Erc721Abi['functions']['transferFrom']>>

export type WhitelistPaymasterTransaction = EthereumTransaction<Parameters<Erc721Abi['functions']['whitelistPaymaster']>>

