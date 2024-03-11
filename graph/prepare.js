const fs = require("fs");

const NFT_ADDRESS = process.env.NFT_ADDRESS; // Get the NFT_ADDRESS from environment variable
const WHITELIST_PAYMASTER_ADDRESS = process.env.WHITELIST_PAYMASTER_ADDRESS; // Get the WHITELIST_PAYMASTER_ADDRESS from environment variable

if (!NFT_ADDRESS || !WHITELIST_PAYMASTER_ADDRESS) {
  console.error("NFT_ADDRESS environment variable is not set.");
  process.exit(1);
}

const filePath = "src/content-sign.subgraph.yaml"; // Path to the file

fs.readFile(filePath, "utf8", (err, data) => {
  if (err) {
    console.error("Error reading the file:", err);
    process.exit(1);
  }

  const lines = data.split("\n");
  const toBeReplacedAddresses = [NFT_ADDRESS, WHITELIST_PAYMASTER_ADDRESS];

  // Find the index of the latest occurrence of the pattern
  for (let i = lines.length - 1; i >= 0; i--) {
    if (lines[i].match(/address: ".*"/)) {
      lines[i] = lines[i].replace(
        /address: ".*"/,
        `address: "${toBeReplacedAddresses.pop()}"`
      );
      if (toBeReplacedAddresses.length === 0) {
        break;
      }
    }
  }

  // Write the modified content back to the file
  fs.writeFile(filePath, lines.join("\n"), "utf8", (err) => {
    if (err) {
      console.error("Error writing to the file:", err);
      process.exit(1);
    }
    console.log("Replacement completed successfully.");
  });
});
