import { Provider, Wallet } from "zksync-ethers";
import { Deployer } from "@matterlabs/hardhat-zksync";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import "@matterlabs/hardhat-zksync-node/dist/type-extensions";
import "@matterlabs/hardhat-zksync-verify/dist/src/type-extensions";
import * as dotenv from "dotenv";

import { deployContract } from "./utils";

dotenv.config();

module.exports = async function (hre: HardhatRuntimeEnvironment) {
    const baseContentSignAddress = process.env.N_CONTENT_SIGN_ADDR!;
    const whitelistNFTAddress = process.env.N_ENS_RESOLVER!;
    const feeTokenAddress = process.env.N_FEE_TOKEN_ADDR!;
    const feeAmount = process.env.N_FEE_TOKEN_AMOUNT || "1000000000000000000"; // Default 1 token
    const adminAddress = process.env.N_ADMIN_ADDR!;

    const rpcUrl = hre.network.config.url!;
    const provider = new Provider(rpcUrl);
    const wallet = new Wallet(process.env.DEPLOYER_PRIVATE_KEY!, provider);
    const deployer = new Deployer(hre, wallet);

    const paymentMiddleware = await deployContract(deployer, "PaymentMiddleware", [
        baseContentSignAddress,
        whitelistNFTAddress,
        feeTokenAddress,
        feeAmount,
        adminAddress,
    ]);

    console.log(`PaymentMiddleware deployed at ${await paymentMiddleware.getAddress()}`);
}; 