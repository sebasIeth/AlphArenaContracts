import { ethers } from "hardhat";

async function main() {
  const MOCK_ALPHA_ADDRESSES: Record<string, string> = {
    baseSepolia: "0xd1256efC47916803B5B3802B9fEFFC5a01EF0e18",
    celoSepolia: "0xe3cd5BbcA9053c16a951539d60F97C4A33abAB67",
  };
  const networkName = (await import("hardhat")).network.name;
  const MOCK_ALPHA_ADDRESS = MOCK_ALPHA_ADDRESSES[networkName];
  if (!MOCK_ALPHA_ADDRESS) throw new Error(`No MockALPHA for network ${networkName}`);
  const RECIPIENT = "0x43A3C8772529DEa09D40c97EEfbCDFfF9153bEbb";
  const AMOUNT = ethers.parseEther("1000000000"); // 1B ALPHA (18 decimals)

  const [signer] = await ethers.getSigners();
  console.log("Signer:", signer.address);

  const mockAlpha = await ethers.getContractAt("MockALPHA", MOCK_ALPHA_ADDRESS);

  console.log(`Minting 1,000,000,000 ALPHA to ${RECIPIENT} on ${networkName}...`);
  const tx = await mockAlpha.mint(RECIPIENT, AMOUNT);
  console.log("Tx hash:", tx.hash);
  await tx.wait();
  console.log("Done! Tx confirmed.");

  const balance = await mockAlpha.balanceOf(RECIPIENT);
  console.log(`Recipient balance: ${ethers.formatEther(balance)} ALPHA`);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
