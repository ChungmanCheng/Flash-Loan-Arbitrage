const { ethers } = require("hardhat");
const { verify } = require("../utils/verify");

async function main() {
  
  const chainId = network.config.chainId;
  let providerAddress, ethUsdOracle;

  if (chainId === 11155111) { // Sepolia
    providerAddress = "0x012bAC54348C0E635dCAc9D5FB99f06F24136C9A";
    ethUsdOracle = "0x694AA1769357215DE4FAC081bf1f309aDC325306";
  } else if (chainId === 1) { // Ethereum Mainnet
    providerAddress = "0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e";
    ethUsdOracle = "0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419";
  } else if (chainId === 137) { // Polygon Mainnet
    providerAddress = "0xa97684ead0e402dC232d5A977953DF7ECBaB3CDb";
    ethUsdOracle = "0xF9680D99D6C9589e2a93a78A04A279e509205945";
  } else {
    throw new Error(`Unsupported network with chainId: ${chainId}`);
  }

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