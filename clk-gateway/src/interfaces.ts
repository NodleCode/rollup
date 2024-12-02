import { Interface, toBigInt } from "ethers";

// L1 Contract
export const ZKSYNC_DIAMOND_INTERFACE = new Interface([
  `function commitBatchesSharedBridge(
        uint256 _chainId,
        (uint64,bytes32,uint64,uint256,bytes32,bytes32,uint256,bytes32) lastCommittedBatchData,
        (uint64,uint64,uint64,bytes32,uint256,bytes32,bytes32,bytes32,bytes,bytes)[] newBatchesData
    )`,
  `function l2LogsRootHash(uint256 _batchNumber) external view returns (bytes32)`,
  `function storedBatchHash(uint256) public view returns (bytes32)`,
  `event BlockCommit(uint256 indexed batchNumber, bytes32 indexed batchHash, bytes32 indexed commitment)`,
]);

// L1 Contract
export const STORAGE_VERIFIER_INTERFACE = new Interface([
  `function verify(
        ( (uint64 batchNumber,
           uint64 indexRepeatedStorageChanges,
           uint256 numberOfLayer1Txs,
           bytes32 priorityOperationsHash,
           bytes32 l2LogsTreeRoot,
           uint256 timestamp,
           bytes32 commitment ) metadata,
          address account,
          uint256 key,
          bytes32 value,
          bytes32[] path,
          uint64 index ) proof
    ) view returns (bool)`,
]);

// L1 Contract
export const CLICK_RESOLVER_INTERFACE = new Interface([
  "function resolve(bytes calldata _name, bytes calldata _data) external view returns (bytes memory)",
  "function resolveWithProof(bytes memory _response, bytes memory _extraData) external view returns (bytes memory)",
  "error OffchainLookup(address sender, string[] urls, bytes callData, bytes4 callbackFunction, bytes extraData)",
]);

// L2 Contract
export const CLICK_NAME_SERVICE_INTERFACE = new Interface([
  "function expires(uint256 key) public view returns (uint256)",
  "function register(address to, string memory name)",
  "function resolve(string memory name) external view returns (address)",
]);

// The storage slot of ERC721._owners within the ClickNameService contract
export const CLICK_NAME_SERVICE_OWNERS_STORAGE_SLOT = toBigInt(2);

export const STORAGE_PROOF_TYPE =
  "((uint64 batchNumber, uint64 indexRepeatedStorageChanges, uint256 numberOfLayer1Txs, bytes32 priorityOperationsHash, bytes32 l2LogsTreeRoot, uint256 timestamp, bytes32 commitment) metadata, address account, uint256 key, bytes32 value, bytes32[] path, uint64 index)";
