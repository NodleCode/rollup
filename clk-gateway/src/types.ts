/** Processed batch */
export interface StoredBatchInfo {
  batchNumber: bigint;
  batchHash: string;
  indexRepeatedStorageChanges: bigint;
  numberOfLayer1Txs: bigint;
  priorityOperationsHash: string;
  l2LogsTreeRoot: string;
  timestamp: bigint;
  commitment: string;
}

/** Metadata of the batch passed to the contract */
export type BatchMetadata = Omit<StoredBatchInfo, "batchHash">;

/** Struct passed to contract by the sequencer for each batch */
export interface CommitBatchInfo {
  batchNumber: bigint;
  timestamp: bigint;
  indexRepeatedStorageChanges: bigint;
  newStateRoot: string;
  numberOfLayer1Txs: bigint;
  priorityOperationsHash: string;
  bootloaderHeapInitialContentsHash: string;
  eventsQueueStateHash: string;
  systemLogs: string;
  totalL2ToL1Pubdata: Uint8Array;
}

/** Proof returned by zkSync RPC */
export type RpcProof = {
  account: string;
  key: string;
  path: Array<string>;
  value: string;
  index: number;
};

export type StorageProofBatch = {
  metadata: BatchMetadata;
  proofs: RpcProof[];
};

export type StorageProof = RpcProof & {
  metadata: BatchMetadata;
};

export type ZyfiSponsoredRequest = {
  chainId: number;
  feeTokenAddress: string;
  gasLimit: string;
  isTestnet: boolean;
  checkNft: boolean;
  txData: {
    from: string;
    to: string;
    value: string;
    data: string;
  };
  sponsorshipRatio: number;
  replayLimit: number;
};

export interface ZyfiSponsoredResponse {
  txData: {
    chainId: number;
    from: string;
    to: string;
    value: string;
    data: string;
    customData: {
      paymasterParams: {
        paymaster: string;
        paymasterInput: string;
      };
      gasPerPubdata: number;
    };
    maxFeePerGas: string;
    gasLimit: number;
  };
  gasLimit: string;
  gasPrice: string;
  tokenAddress: string;
  tokenPrice: string;
  feeTokenAmount: string;
  feeTokendecimals: string;
  feeUSD: string;
  markup: string;
  expirationTime: string;
  expiresIn: string;
  maxNonce: string;
  protocolAddress: string;
  sponsorshipRatio: string;
  warnings: string[];
}
