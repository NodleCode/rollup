// SPDX-License-Identifier: Apache-2.0

// Auto-generated , DO NOT EDIT
import {EthereumLog, EthereumTransaction, LightEthereumLog} from "@subql/types-ethereum";

import {RoleAdminChangedEvent, RoleGrantedEvent, RoleRevokedEvent, Accesscontrol} from '../contracts/Accesscontrol'


export type RoleAdminChangedLog = EthereumLog<RoleAdminChangedEvent["args"]>

export type RoleGrantedLog = EthereumLog<RoleGrantedEvent["args"]>

export type RoleRevokedLog = EthereumLog<RoleRevokedEvent["args"]>


export type LightRoleAdminChangedLog = LightEthereumLog<RoleAdminChangedEvent["args"]>

export type LightRoleGrantedLog = LightEthereumLog<RoleGrantedEvent["args"]>

export type LightRoleRevokedLog = LightEthereumLog<RoleRevokedEvent["args"]>


export type DEFAULT_ADMIN_ROLETransaction = EthereumTransaction<Parameters<Accesscontrol['functions']['DEFAULT_ADMIN_ROLE']>>

export type WHITELIST_ADMIN_ROLETransaction = EthereumTransaction<Parameters<Accesscontrol['functions']['WHITELIST_ADMIN_ROLE']>>

export type WITHDRAWER_ROLETransaction = EthereumTransaction<Parameters<Accesscontrol['functions']['WITHDRAWER_ROLE']>>

export type AddWhitelistedContractsTransaction = EthereumTransaction<Parameters<Accesscontrol['functions']['addWhitelistedContracts']>>

export type AddWhitelistedUsersTransaction = EthereumTransaction<Parameters<Accesscontrol['functions']['addWhitelistedUsers']>>

export type GetRoleAdminTransaction = EthereumTransaction<Parameters<Accesscontrol['functions']['getRoleAdmin']>>

export type GrantRoleTransaction = EthereumTransaction<Parameters<Accesscontrol['functions']['grantRole']>>

export type HasRoleTransaction = EthereumTransaction<Parameters<Accesscontrol['functions']['hasRole']>>

export type IsWhitelistedContractTransaction = EthereumTransaction<Parameters<Accesscontrol['functions']['isWhitelistedContract']>>

export type IsWhitelistedUserTransaction = EthereumTransaction<Parameters<Accesscontrol['functions']['isWhitelistedUser']>>

export type PostTransactionTransaction = EthereumTransaction<Parameters<Accesscontrol['functions']['postTransaction']>>

export type RemoveWhitelistedContractsTransaction = EthereumTransaction<Parameters<Accesscontrol['functions']['removeWhitelistedContracts']>>

export type RemoveWhitelistedUsersTransaction = EthereumTransaction<Parameters<Accesscontrol['functions']['removeWhitelistedUsers']>>

export type RenounceRoleTransaction = EthereumTransaction<Parameters<Accesscontrol['functions']['renounceRole']>>

export type RevokeRoleTransaction = EthereumTransaction<Parameters<Accesscontrol['functions']['revokeRole']>>

export type SupportsInterfaceTransaction = EthereumTransaction<Parameters<Accesscontrol['functions']['supportsInterface']>>

export type ValidateAndPayForPaymasterTransactionTransaction = EthereumTransaction<Parameters<Accesscontrol['functions']['validateAndPayForPaymasterTransaction']>>

export type WithdrawTransaction = EthereumTransaction<Parameters<Accesscontrol['functions']['withdraw']>>

