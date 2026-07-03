import { Provider, Wallet } from "zksync-ethers";
import { Deployer } from "@matterlabs/hardhat-zksync";
import { ethers } from "ethers";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import "@matterlabs/hardhat-zksync-node/dist/type-extensions";
import "@matterlabs/hardhat-zksync-verify/dist/src/type-extensions";
import * as dotenv from "dotenv";
import { deployContract } from "./utils";

dotenv.config({ path: ".env-test" });

/**
 * Deploys the upgradeable swarm contracts on ZkSync Era
 *
 * Required environment variables:
 * - DEPLOYER_PRIVATE_KEY: Private key for deployment
 * - BOND_TOKEN: Address of the ERC20 bond token
 * - BASE_BOND: Base bond amount in wei
 * - L2_ADMIN: Owner address for all deployed L2 contracts (ZkSync Safe multisig)
 */
module.exports = async function (hre: HardhatRuntimeEnvironment) {
  const bondToken = process.env.BOND_TOKEN!;
  const baseBond = BigInt(process.env.BASE_BOND!);
  const countryMultiplier = BigInt(process.env.COUNTRY_MULTIPLIER || "0");

  const rpcUrl = hre.network.config.url!;
  const provider = new Provider(rpcUrl);
  const wallet = new Wallet(process.env.DEPLOYER_PRIVATE_KEY!, provider);
  const deployer = new Deployer(hre, wallet);

  const owner = process.env.L2_ADMIN;
  if (!owner) {
    throw new Error(
      "L2_ADMIN environment variable is required (ZkSync Safe multisig)",
    );
  }

  console.log("=== Deploying Upgradeable Swarm Contracts on ZkSync ===");
  console.log("Bond Token:", bondToken);
  console.log("Base Bond:", baseBond.toString());
  console.log("Country Multiplier:", countryMultiplier.toString());
  console.log("Owner:", owner);
  console.log("Deployer:", wallet.address);
  console.log("");

  // 1. Deploy ServiceProviderUpgradeable Implementation
  console.log("1. Deploying ServiceProviderUpgradeable...");
  const serviceProviderArtifact = await deployer.loadArtifact(
    "ServiceProviderUpgradeable",
  );
  const serviceProviderImpl = await deployer.deploy(
    serviceProviderArtifact,
    [],
  );
  await serviceProviderImpl.waitForDeployment();
  const serviceProviderImplAddr = await serviceProviderImpl.getAddress();
  console.log("   Implementation:", serviceProviderImplAddr);

  // Deploy ServiceProvider Proxy
  const serviceProviderInitData =
    serviceProviderImpl.interface.encodeFunctionData("initialize", [owner]);
  const proxyArtifact = await deployer.loadArtifact("ERC1967Proxy");
  const serviceProviderProxy = await deployer.deploy(proxyArtifact, [
    serviceProviderImplAddr,
    serviceProviderInitData,
  ]);
  await serviceProviderProxy.waitForDeployment();
  const serviceProviderProxyAddr = await serviceProviderProxy.getAddress();
  console.log("   Proxy:", serviceProviderProxyAddr);
  console.log("");

  // 2. Deploy FleetIdentityUpgradeable Implementation
  console.log("2. Deploying FleetIdentityUpgradeable...");
  const fleetIdentityArtifact = await deployer.loadArtifact(
    "FleetIdentityUpgradeable",
  );
  const fleetIdentityImpl = await deployer.deploy(fleetIdentityArtifact, []);
  await fleetIdentityImpl.waitForDeployment();
  const fleetIdentityImplAddr = await fleetIdentityImpl.getAddress();
  console.log("   Implementation:", fleetIdentityImplAddr);

  // Deploy FleetIdentity Proxy
  const fleetIdentityInitData = fleetIdentityImpl.interface.encodeFunctionData(
    "initialize",
    [owner, bondToken, baseBond.toString(), countryMultiplier.toString()],
  );
  const fleetIdentityProxy = await deployer.deploy(proxyArtifact, [
    fleetIdentityImplAddr,
    fleetIdentityInitData,
  ]);
  await fleetIdentityProxy.waitForDeployment();
  const fleetIdentityProxyAddr = await fleetIdentityProxy.getAddress();
  console.log("   Proxy:", fleetIdentityProxyAddr);
  console.log("");

  // 3. Deploy SwarmRegistryUniversalUpgradeable Implementation
  console.log("3. Deploying SwarmRegistryUniversalUpgradeable...");
  const swarmRegistryArtifact = await deployer.loadArtifact(
    "SwarmRegistryUniversalUpgradeable",
  );
  const swarmRegistryImpl = await deployer.deploy(swarmRegistryArtifact, []);
  await swarmRegistryImpl.waitForDeployment();
  const swarmRegistryImplAddr = await swarmRegistryImpl.getAddress();
  console.log("   Implementation:", swarmRegistryImplAddr);

  // Deploy SwarmRegistry Proxy
  const swarmRegistryInitData = swarmRegistryImpl.interface.encodeFunctionData(
    "initialize",
    [fleetIdentityProxyAddr, serviceProviderProxyAddr, owner],
  );
  const swarmRegistryProxy = await deployer.deploy(proxyArtifact, [
    swarmRegistryImplAddr,
    swarmRegistryInitData,
  ]);
  await swarmRegistryProxy.waitForDeployment();
  const swarmRegistryProxyAddr = await swarmRegistryProxy.getAddress();
  console.log("   Proxy:", swarmRegistryProxyAddr);
  console.log("");

  // Summary
  console.log("=== Deployment Complete ===");
  console.log("ServiceProvider Implementation:", serviceProviderImplAddr);
  console.log("ServiceProvider Proxy:", serviceProviderProxyAddr);
  console.log("FleetIdentity Implementation:", fleetIdentityImplAddr);
  console.log("FleetIdentity Proxy:", fleetIdentityProxyAddr);
  console.log("SwarmRegistry Implementation:", swarmRegistryImplAddr);
  console.log("SwarmRegistry Proxy:", swarmRegistryProxyAddr);
  console.log("");

  // Verify contracts
  console.log("=== Verifying Contracts ===");
  try {
    console.log("Verifying ServiceProviderUpgradeable Implementation...");
    await hre.run("verify:verify", {
      address: serviceProviderImplAddr,
      contract:
        "src/swarms/ServiceProviderUpgradeable.sol:ServiceProviderUpgradeable",
      constructorArguments: [],
    });
  } catch (e: any) {
    console.log("Verification failed or already verified:", e.message);
  }

  try {
    console.log("Verifying FleetIdentityUpgradeable Implementation...");
    await hre.run("verify:verify", {
      address: fleetIdentityImplAddr,
      contract:
        "src/swarms/FleetIdentityUpgradeable.sol:FleetIdentityUpgradeable",
      constructorArguments: [],
    });
  } catch (e: any) {
    console.log("Verification failed or already verified:", e.message);
  }

  try {
    console.log(
      "Verifying SwarmRegistryUniversalUpgradeable Implementation...",
    );
    await hre.run("verify:verify", {
      address: swarmRegistryImplAddr,
      contract:
        "src/swarms/SwarmRegistryUniversalUpgradeable.sol:SwarmRegistryUniversalUpgradeable",
      constructorArguments: [],
    });
  } catch (e: any) {
    console.log("Verification failed or already verified:", e.message);
  }

  try {
    console.log("Verifying ServiceProvider Proxy...");
    await hre.run("verify:verify", {
      address: serviceProviderProxyAddr,
      contract:
        "lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy",
      constructorArguments: [serviceProviderImplAddr, serviceProviderInitData],
    });
  } catch (e: any) {
    console.log("Verification failed or already verified:", e.message);
  }

  try {
    console.log("Verifying FleetIdentity Proxy...");
    await hre.run("verify:verify", {
      address: fleetIdentityProxyAddr,
      contract:
        "lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy",
      constructorArguments: [fleetIdentityImplAddr, fleetIdentityInitData],
    });
  } catch (e: any) {
    console.log("Verification failed or already verified:", e.message);
  }

  try {
    console.log("Verifying SwarmRegistry Proxy...");
    await hre.run("verify:verify", {
      address: swarmRegistryProxyAddr,
      contract:
        "lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy",
      constructorArguments: [swarmRegistryImplAddr, swarmRegistryInitData],
    });
  } catch (e: any) {
    console.log("Verification failed or already verified:", e.message);
  }

  console.log("");
  console.log("=== Add these to .env-test: ===");
  console.log(`SERVICE_PROVIDER_PROXY=${serviceProviderProxyAddr}`);
  console.log(`SERVICE_PROVIDER_IMPL=${serviceProviderImplAddr}`);
  console.log(`FLEET_IDENTITY_PROXY=${fleetIdentityProxyAddr}`);
  console.log(`FLEET_IDENTITY_IMPL=${fleetIdentityImplAddr}`);
  console.log(`SWARM_REGISTRY_PROXY=${swarmRegistryProxyAddr}`);
  console.log(`SWARM_REGISTRY_IMPL=${swarmRegistryImplAddr}`);
};
