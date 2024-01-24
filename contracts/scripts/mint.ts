import { getProvider, getWallet } from "../deploy/utils";
import { Contract } from "ethers";

const NFT_URI = "https://example.com";
const ContractAddress = "0x8a544924916dCf0f73564750CBC68BBC65Fe1E0B"; // TODO: Should be from the hh config
const ERC721ABI = `
[
    {
      "inputs": [
        {
          "internalType": "address",
          "name": "to",
          "type": "address"
        },
        {
          "internalType": "string",
          "name": "uri",
          "type": "string"
        }
      ],
      "name": "safeMint",
      "outputs": [],
      "stateMutability": "nonpayable",
      "type": "function"
    }
]
`;

async function main() {
    const wallet = getWallet();
    const ContentSignContract = new Contract(ContractAddress, ERC721ABI, wallet);

    console.log("Minting item to:", wallet.address);
    const tx = await ContentSignContract.safeMint(wallet.address, NFT_URI);
    
    console.log("Waiting for tx to be mined...");
    await tx.wait();

    
    console.log("Minted item.");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
      console.error(error);
      process.exit(1);
  });