import { ethers, network } from "hardhat";

// USDC addresses per network
const USDC_ADDRESSES: Record<string, string> = {
  base: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",       // Base mainnet
  baseSepolia: "0x036CbD53842c5426634e7929541eC2318f3dCF7e", // Base Sepolia
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

  // Resolve USDC address
  let usdcAddress = USDC_ADDRESSES[networkName];

  if (!usdcAddress) {
    // For localhost/hardhat: deploy a mock ERC20 for testing
    if (networkName === "localhost" || networkName === "hardhat") {
      console.log("\nLocal network detected — deploying MockUSDC...");
      const MockUSDC = await ethers.getContractFactory("MockUSDC");
      const mockUsdc = await MockUSDC.deploy();
      await mockUsdc.waitForDeployment();
      usdcAddress = await mockUsdc.getAddress();
      console.log("MockUSDC deployed to:", usdcAddress);
    } else {
      throw new Error(
        `No USDC address configured for network "${networkName}". ` +
        `Supported networks: ${Object.keys(USDC_ADDRESSES).join(", ")}`
      );
    }
  }

  console.log("USDC address:", usdcAddress);

  // Deploy AlphArena
  const AlphArena = await ethers.getContractFactory("AlphArena");
  const arena = await AlphArena.deploy(usdcAddress);
  await arena.waitForDeployment();

  const arenaAddress = await arena.getAddress();
  console.log("\nAlphArena deployed to:", arenaAddress);

  // Auto-set operator on local/test networks
  if (networkName === "localhost" || networkName === "hardhat" || networkName === "baseSepolia") {
    const tx = await arena.setOperator(deployer.address);
    await tx.wait();
    console.log("Operator set to deployer:", deployer.address);
  } else {
    console.log("Remember to call setOperator() with the backend operator address.");
  }

  console.log("\n--- Deployment Summary ---");
  console.log("Network:          ", networkName);
  console.log("AlphArena:        ", arenaAddress);
  console.log("USDC:             ", usdcAddress);
  console.log("Owner:            ", deployer.address);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
