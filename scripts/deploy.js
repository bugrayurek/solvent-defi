const hre = require("hardhat");

// Arc Testnet USDC/EURC ERC-20 interface addresses (verify against
// https://docs.arc.io/arc/references/contract-addresses before real use —
// these can change while Arc is on testnet).
// USDC's ERC-20 interface lives at a special system address on Arc; the
// same underlying balance also acts as native gas.
const USDC_ADDRESS = process.env.USDC_ADDRESS || "0x3600000000000000000000000000000000000000";
const EURC_ADDRESS = process.env.EURC_ADDRESS || "0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a";

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  console.log("Deploying with:", deployer.address);

  const Pool = await hre.ethers.getContractFactory("SolventLendingPool");
  const pool = await Pool.deploy();
  await pool.waitForDeployment();
  console.log("SolventLendingPool deployed to:", await pool.getAddress());

  let usdc = USDC_ADDRESS;
  let eurc = EURC_ADDRESS;

  if (!usdc || !eurc) {
    console.log("No USDC/EURC address supplied — deploying mocks for testing.");
    const Mock = await hre.ethers.getContractFactory("MockERC20");

    const mockUsdc = await Mock.deploy("Mock USD Coin", "mUSDC", 6);
    await mockUsdc.waitForDeployment();
    usdc = await mockUsdc.getAddress();
    console.log("MockUSDC deployed to:", usdc);

    const mockEurc = await Mock.deploy("Mock Euro Coin", "mEURC", 6);
    await mockEurc.waitForDeployment();
    eurc = await mockEurc.getAddress();
    console.log("MockEURC deployed to:", eurc);
  }

  // List markets: collateral factor, liquidation bonus, reserve factor (bps),
  // then base/slope/jumpSlope rates (annualized bps) and the utilization kink.
  const tx1 = await pool.listMarket(usdc, 8500, 500, 1000, 200, 800, 6000, 8000);
  await tx1.wait();
  console.log("Listed USDC market");

  const tx2 = await pool.listMarket(eurc, 8000, 700, 1000, 250, 900, 6500, 8000);
  await tx2.wait();
  console.log("Listed EURC market");

  console.log("\nDone. Pool address:", await pool.getAddress());
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
