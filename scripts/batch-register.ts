import { Provider, Wallet, types, utils } from "zksync-ethers";
import { ethers } from "ethers";
import { createReadStream } from "fs";
import { parse } from "csv-parse";
import * as fs from "fs";

// ABI fragment for the register function
const ABI = [
    "function register(address to, string memory name) public",
];

interface NameRegistration {
    name: string;
    address: string;
}

async function main() {
    // Check command line arguments
    if (process.argv.length !== 3) {
        console.error(
            "Usage: ts-node batch-register.ts <csv_file>"
        );
        process.exit(1);
    }

    // Load environment variables
    const contractAddress = process.env.REGISTRAR_ADDR;
    const rpcUrl = process.env.ETH_RPC_URL;
    const privateKey = process.env.DEPLOYER_PRIVATE_KEY;

    if (!contractAddress || !rpcUrl || !privateKey) {
        console.error("Missing required environment variables");
        process.exit(1);
    }

    const [, , csvFile] = process.argv;

    // Validate CSV file exists
    if (!fs.existsSync(csvFile)) {
        console.error(`Error: CSV file '${csvFile}' not found`);
        process.exit(1);
    }

    // Setup zkSync provider and wallet
    const provider = new Provider(rpcUrl);
    const wallet = new Wallet(privateKey, provider);

    // Create contract instance
    const contract = new ethers.Contract(contractAddress, ABI, wallet);

    // Setup logging
    const timestamp = new Date().toISOString().replace(/[:.]/g, "-");
    const logFile = `registration_${timestamp}.log`;
    const logStream = fs.createWriteStream(logFile, { flags: "a" });

    const log = (message: string, consoleOnly = false) => {
        console.log(message);
        if (!consoleOnly) {
            logStream.write(message + "\n");
        }
    };

    log(`Starting registration process at ${new Date().toISOString()}`);
    log(`Contract Address: ${contractAddress}`);

    // Process CSV file
    const registrations: NameRegistration[] = [];

    await new Promise((resolve, reject) => {
        createReadStream(csvFile)
            .pipe(parse({ columns: true, trim: true }))
            .on("data", (row) => {
                registrations.push({
                    name: row.name.trim(),
                    address: row.address.trim(),
                });
            })
            .on("end", resolve)
            .on("error", reject);
    });

    // Process each registration
    for (const reg of registrations) {
        // Validate address format
        if (!ethers.isAddress(reg.address)) {
            log(`Error: Invalid address format for name '${reg.name}': ${reg.address}`);
            continue;
        }

        reg.name = reg.name.toLowerCase();

        log(`Registering name: ${reg.name} for address: ${reg.address}`);

        try {
            // Send transaction
            const tx = await contract.register(reg.address, reg.name);
            const receipt = await tx.wait();

            log(`✅ Successfully registered ${reg.name} to ${reg.address}`);
            log(`Transaction hash: ${receipt.hash}`);
        } catch (error: unknown) {
            log(`❌ Failed to register ${reg.name} to ${reg.address}`);
            const errorMessage = error instanceof Error ? error.message : String(error);
            log(`Error: ${errorMessage}`);
        }

        // Add delay between transactions
        await new Promise(resolve => setTimeout(resolve, 1000));
    }

    log(`Registration process completed at ${new Date().toISOString()}`);
    log(`Log file saved as: ${logFile}`);

    logStream.end();
}

// Execute the script
main().catch((error) => {
    console.error("Fatal error:", error);
    process.exit(1);
}); 