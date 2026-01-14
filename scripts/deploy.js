const { ethers } = require("hardhat");
const { verify } = require("../utils/verify");

async function main() {
  const providerAddress = "0x012bAC54348C0E635dCAc9D5FB99f06F24136C9A"; // Aave V3 PoolAddressesProvider on Sepolia
  const ethUsdOracle = "0x694AA1769357215DE4FAC081bf1f309aDC325306"; // Chainlink ETH/USD on Sepolia
  const FlashLoan = await ethers.getContractFactory("FlashLoan");
  const flashLoan = await FlashLoan.deploy(providerAddress, ethUsdOracle);

  await flashLoan.waitForDeployment(); // Wait for deployment confirmation
  const deployedAddress = await flashLoan.getAddress();
  console.log("FlashLoan deployed to:", deployedAddress);

  // Verify the contract
  await verify(deployedAddress, [providerAddress, ethUsdOracle]);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });