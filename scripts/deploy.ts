import { ethers } from "hardhat";

async function main() {
  const [deployer] = await ethers.getSigners();

  console.log("Deploying AlphArena with account:", deployer.address);
  console.log(
    "Account balance:",
    ethers.formatEther(await ethers.provider.getBalance(deployer.address)),
    "ETH"
  );

  const AlphArena = await ethers.getContractFactory("AlphArena");
  const arena = await AlphArena.deploy();

  await arena.waitForDeployment();

  const arenaAddress = await arena.getAddress();
  console.log("AlphArena deployed to:", arenaAddress);

  // Optionally set the operator to the deployer for convenience on testnets
  const networkName = (await ethers.provider.getNetwork()).name;
  if (networkName === "unknown" || networkName === "localhost" || networkName === "hardhat") {
    const tx = await arena.setOperator(deployer.address);
    await tx.wait();
    console.log("Operator set to deployer:", deployer.address);
  } else {
    console.log(
      "Remember to call setOperator() with the backend operator address."
    );
  }

  console.log("\nDeployment complete!");
  console.log("Contract address:", arenaAddress);
  console.log("Owner:", deployer.address);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
