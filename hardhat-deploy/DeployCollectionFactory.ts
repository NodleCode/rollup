import { Provider, Wallet } from "zksync-ethers";
import { Deployer } from "@matterlabs/hardhat-zksync";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import "@matterlabs/hardhat-zksync-node/dist/type-extensions";
import "@matterlabs/hardhat-zksync-verify/dist/src/type-extensions";
import * as dotenv from "dotenv";

// Load .env-prod for mainnet, .env-test otherwise
const envFile =
  process.env.HARDHAT_NETWORK === "zkSyncMainnet" ? ".env-prod" : ".env-test";
dotenv.config({ path: envFile });

/**
 * Deploys the user collections system (CollectionFactory + UserCollection721 +
 * UserCollection1155) on ZkSync Era, then verifies all four contracts.
 *
 * Mirrors the Envelope/Swarm Hardhat deploy scripts. Preferred over the Foundry
 * flow (ops/deploy_collection_factory_zksync.sh) when source verification of the
 * factory logic is needed: the `@matterlabs/hardhat-zksync-verify` plugin
 * conveys `factoryDependencies` to the verifier, which the standard-JSON helper
 * (ops/verify_zksync_contracts.py) does not — that gap leaves the factory logic
 * unverifiable because it carries the ERC1967Proxy bytecode hash as a dep.
 *
 * Deploy order (matches DeployCollectionFactoryZkSync.s.sol):
 *   1. UserCollection721 implementation  (shared impl behind per-collection proxies)
 *   2. UserCollection1155 implementation
 *   3. CollectionFactory logic
 *   4. ERC1967Proxy(factoryLogic, initialize(admin, operator, impl721, impl1155))
 *
 * Required environment variables (from .env-test / .env-prod):
 *   - DEPLOYER_PRIVATE_KEY: Private key with ETH for gas.
 *   - N_FACTORY_ADMIN:      Address that will hold DEFAULT_ADMIN_ROLE (multisig on mainnet).
 *   - N_FACTORY_OPERATOR:   Backend service address that will hold OPERATOR_ROLE.
 *
 * Usage:
 *   yarn hardhat deploy-zksync \
 *     --script DeployCollectionFactory.ts \
 *     --network zkSyncSepoliaTestnet
 */
module.exports = async function (hre: HardhatRuntimeEnvironment) {
  const ZERO = "0x0000000000000000000000000000000000000000";

  const rpcUrl = hre.network.config.url!;
  const provider = new Provider(rpcUrl);
  const wallet = new Wallet(process.env.DEPLOYER_PRIVATE_KEY!, provider);
  const deployer = new Deployer(hre, wallet);

  const admin = process.env.N_FACTORY_ADMIN ?? "";
  const operator = process.env.N_FACTORY_OPERATOR ?? "";

  if (!admin || admin === ZERO) {
    throw new Error("N_FACTORY_ADMIN is required and must be non-zero");
  }
  if (!operator || operator === ZERO) {
    throw new Error("N_FACTORY_OPERATOR is required and must be non-zero");
  }

  // Mainnet guardrail: this is a permanent, irreversible broadcast. Require an
  // explicit acknowledgement (the deploy task is non-interactive, so we gate on
  // an env flag rather than a prompt).
  if (hre.network.name === "zkSyncMainnet") {
    if (process.env.CONFIRM_MAINNET !== "YES") {
      throw new Error(
        "Refusing MAINNET deploy without CONFIRM_MAINNET=YES. Set it to acknowledge a real, permanent broadcast.",
      );
    }
    if (admin.toLowerCase() === wallet.address.toLowerCase()) {
      console.log(
        "WARNING: N_FACTORY_ADMIN == deployer EOA. This key controls factory upgrades + impl-pointer swaps " +
          "(the bytecode of all FUTURE collections). Rotate DEFAULT_ADMIN_ROLE to a Safe multisig soon after launch.",
      );
    }
  }

  console.log("=== Deploying User Collections on ZkSync ===");
  console.log("Network:  ", hre.network.name);
  console.log("Deployer: ", wallet.address);
  console.log("Admin:    ", admin);
  console.log("Operator: ", operator);
  console.log("");

  // 1. UserCollection721 implementation (CREATE; deployed once, shared by all
  //    per-collection ERC1967Proxy instances the factory spins up later).
  console.log("1. Deploying UserCollection721 implementation...");
  const impl721Artifact = await deployer.loadArtifact("UserCollection721");
  const impl721 = await deployer.deploy(impl721Artifact, []);
  await impl721.waitForDeployment();
  const impl721Addr = await impl721.getAddress();
  console.log("   UserCollection721 Implementation:", impl721Addr);

  // 2. UserCollection1155 implementation.
  console.log("2. Deploying UserCollection1155 implementation...");
  const impl1155Artifact = await deployer.loadArtifact("UserCollection1155");
  const impl1155 = await deployer.deploy(impl1155Artifact, []);
  await impl1155.waitForDeployment();
  const impl1155Addr = await impl1155.getAddress();
  console.log("   UserCollection1155 Implementation:", impl1155Addr);

  // 3. CollectionFactory logic.
  console.log("3. Deploying CollectionFactory logic...");
  const factoryArtifact = await deployer.loadArtifact("CollectionFactory");
  const factoryLogic = await deployer.deploy(factoryArtifact, []);
  await factoryLogic.waitForDeployment();
  const factoryLogicAddr = await factoryLogic.getAddress();
  console.log("   CollectionFactory Implementation:", factoryLogicAddr);

  // 4. ERC1967Proxy + atomic initialize (this is the factory's OWN proxy; the
  //    per-collection proxies are deployed by the factory at createCollection*).
  console.log("4. Deploying ERC1967Proxy(CollectionFactory)...");
  const initData = factoryLogic.interface.encodeFunctionData("initialize", [
    admin,
    operator,
    impl721Addr,
    impl1155Addr,
  ]);
  // Load by fully-qualified name: the hardhat-zksync-upgradable plugin ships a
  // second ERC1967Proxy artifact, so the bare short name is ambiguous (HH701).
  const proxyArtifact = await deployer.loadArtifact(
    "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy",
  );
  const factoryProxy = await deployer.deploy(proxyArtifact, [
    factoryLogicAddr,
    initData,
  ]);
  await factoryProxy.waitForDeployment();
  const factoryProxyAddr = await factoryProxy.getAddress();
  console.log("   CollectionFactory Proxy:", factoryProxyAddr);
  console.log("");

  console.log("=== Deployment Complete ===");
  console.log("CollectionFactory Proxy:         ", factoryProxyAddr);
  console.log("CollectionFactory Implementation:", factoryLogicAddr);
  console.log("UserCollection721 Implementation: ", impl721Addr);
  console.log("UserCollection1155 Implementation:", impl1155Addr);
  console.log("");

  // Verification — the hardhat-zksync-verify plugin handles the factory's
  // factoryDependencies, so all four (incl. the factory logic) verify fully.
  console.log("=== Verifying Contracts ===");

  const verify = async (
    label: string,
    address: string,
    contract: string,
    constructorArguments: any[],
  ) => {
    try {
      console.log(`Verifying ${label}...`);
      await hre.run("verify:verify", { address, contract, constructorArguments });
    } catch (e: any) {
      console.log("Verification failed or already verified:", e.message);
    }
  };

  await verify(
    "UserCollection721",
    impl721Addr,
    "src/collections/UserCollection721.sol:UserCollection721",
    [],
  );
  await verify(
    "UserCollection1155",
    impl1155Addr,
    "src/collections/UserCollection1155.sol:UserCollection1155",
    [],
  );
  await verify(
    "CollectionFactory (logic)",
    factoryLogicAddr,
    "src/collections/CollectionFactory.sol:CollectionFactory",
    [],
  );
  await verify(
    "CollectionFactory (proxy)",
    factoryProxyAddr,
    // Hardhat identifies OZ contracts by their npm remap path (where the
    // artifact lives: artifacts-zk/@openzeppelin/...), NOT the Foundry lib path.
    "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy",
    [factoryLogicAddr, initData],
  );

  console.log("");
  console.log(`=== Add these to ${envFile}: ===`);
  console.log(`COLLECTION_FACTORY_PROXY=${factoryProxyAddr}`);
  console.log(`COLLECTION_FACTORY_IMPL=${factoryLogicAddr}`);
  console.log(`USER_COLLECTION_721_IMPL=${impl721Addr}`);
  console.log(`USER_COLLECTION_1155_IMPL=${impl1155Addr}`);

  if (admin === operator) {
    console.log("");
    console.log(
      "NOTE: N_FACTORY_ADMIN == N_FACTORY_OPERATOR. Fine for testnet, but on mainnet admin should be a multisig and operator a separate backend key.",
    );
  }
};
