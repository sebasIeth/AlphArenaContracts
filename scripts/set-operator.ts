import { ethers } from "hardhat";

async function main() {
  const ARENA_ADDRESS = "0xB4E12edaf3065071b4AaC780951B120c0bA7cE53";
  const OPERATOR = "0x5A081b2b6E283BF81C5E7De7d4b11162b3D5C069";

  const [signer] = await ethers.getSigners();
  console.log("Signer (owner):", signer.address);

  const arena = await ethers.getContractAt("AlphArena", ARENA_ADDRESS);

  console.log(`Setting operator to ${OPERATOR}...`);
  const tx = await arena.setOperator(OPERATOR);
  console.log("Tx hash:", tx.hash);
  await tx.wait();
  console.log("Done! Operator set successfully.");

  const operator = await arena.operator();
  console.log("Current operator:", operator);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
