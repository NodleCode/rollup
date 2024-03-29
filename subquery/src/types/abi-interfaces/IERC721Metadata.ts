// SPDX-License-Identifier: Apache-2.0

// Auto-generated , DO NOT EDIT
import {EthereumLog, EthereumTransaction, LightEthereumLog} from "@subql/types-ethereum";

import {ApprovalEvent, ApprovalForAllEvent, TransferEvent, IERC721Metadata} from '../contracts/IERC721Metadata'


export type ApprovalLog = EthereumLog<ApprovalEvent["args"]>

export type ApprovalForAllLog = EthereumLog<ApprovalForAllEvent["args"]>

export type TransferLog = EthereumLog<TransferEvent["args"]>


export type LightApprovalLog = LightEthereumLog<ApprovalEvent["args"]>

export type LightApprovalForAllLog = LightEthereumLog<ApprovalForAllEvent["args"]>

export type LightTransferLog = LightEthereumLog<TransferEvent["args"]>


export type ApproveTransaction = EthereumTransaction<Parameters<IERC721Metadata['functions']['approve']>>

export type BalanceOfTransaction = EthereumTransaction<Parameters<IERC721Metadata['functions']['balanceOf']>>

export type GetApprovedTransaction = EthereumTransaction<Parameters<IERC721Metadata['functions']['getApproved']>>

export type IsApprovedForAllTransaction = EthereumTransaction<Parameters<IERC721Metadata['functions']['isApprovedForAll']>>

export type NameTransaction = EthereumTransaction<Parameters<IERC721Metadata['functions']['name']>>

export type OwnerOfTransaction = EthereumTransaction<Parameters<IERC721Metadata['functions']['ownerOf']>>

export type SafeTransferFrom_address_address_uint256_Transaction = EthereumTransaction<Parameters<IERC721Metadata['functions']['safeTransferFrom(address,address,uint256)']>>

export type SafeTransferFrom_address_address_uint256_bytes_Transaction = EthereumTransaction<Parameters<IERC721Metadata['functions']['safeTransferFrom(address,address,uint256,bytes)']>>

export type SetApprovalForAllTransaction = EthereumTransaction<Parameters<IERC721Metadata['functions']['setApprovalForAll']>>

export type SupportsInterfaceTransaction = EthereumTransaction<Parameters<IERC721Metadata['functions']['supportsInterface']>>

export type SymbolTransaction = EthereumTransaction<Parameters<IERC721Metadata['functions']['symbol']>>

export type TokenURITransaction = EthereumTransaction<Parameters<IERC721Metadata['functions']['tokenURI']>>

export type TransferFromTransaction = EthereumTransaction<Parameters<IERC721Metadata['functions']['transferFrom']>>

