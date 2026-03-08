import { ethers, network } from "hardhat";

// ALPHA token addresses per network
const ALPHA_ADDRESSES: Record<string, string> = {
  base: "0x324f2BD09e908f28217CC19Bb9599b199c736bA3", // Base mainnet
  celo: "0x3B825bED44D0daa21a7e960B913848baebB9c869", // Celo mainnet
};

async function main() {
  const [deployer] = await ethers.getSigners();
  const networkName = network.name;

  console.log("Network:", networkName);
  console.log("Deployer:", deployer.address);
  console.log(
    "Balance:",
    ethers.formatEther(await ethers.provider.getBalance(deployer.address)),
    "ETH"
  );

  // Resolve ALPHA token address
  let alphaAddress = ALPHA_ADDRESSES[networkName];

  if (!alphaAddress) {
    // For localhost/hardhat/testnet: deploy a mock ALPHA token
    if (["localhost", "hardhat", "baseSepolia", "celoSepolia"].includes(networkName)) {
      console.log("\nTest network detected — deploying MockALPHA...");
      const MockALPHA = await ethers.getContractFactory("MockALPHA");
      const mockAlpha = await MockALPHA.deploy();
      await mockAlpha.waitForDeployment();
      alphaAddress = await mockAlpha.getAddress();
      console.log("MockALPHA deployed to:", alphaAddress);
    } else {
      throw new Error(
        `No ALPHA address configured for network "${networkName}". ` +
        `Supported networks: ${Object.keys(ALPHA_ADDRESSES).join(", ")}`
      );
    }
  }

  console.log("ALPHA address:", alphaAddress);

  // Deploy AlphArena
  const AlphArena = await ethers.getContractFactory("AlphArena");
  const arena = await AlphArena.deploy(alphaAddress);
  await arena.waitForDeployment();

  const arenaAddress = await arena.getAddress();
  console.log("\nAlphArena deployed to:", arenaAddress);

  // Auto-set operator to deployer
  const tx = await arena.setOperator(deployer.address);
  await tx.wait();
  console.log("Operator set to deployer:", deployer.address);

  console.log("\n--- Deployment Summary ---");
  console.log("Network:          ", networkName);
  console.log("AlphArena:        ", arenaAddress);
  console.log("ALPHA:            ", alphaAddress);
  console.log("Owner:            ", deployer.address);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
