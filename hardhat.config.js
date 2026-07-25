require("@nomicfoundation/hardhat-toolbox");

// Arc Testnet — see https://docs.arc.io/arc/references/connect-to-arc for the
// current RPC URL, chain ID, and explorer (these can change while Arc is on
// testnet, so double check before deploying).
const ARC_TESTNET_RPC = process.env.ARC_TESTNET_RPC || "https://rpc.testnet.arc.network";
const ARC_TESTNET_CHAIN_ID = Number(process.env.ARC_TESTNET_CHAIN_ID || 5042002);

module.exports = {
  solidity: {
    version: "0.8.24",
    settings: {
      optimizer: { enabled: true, runs: 200 },
    },
  },
  networks: {
    arcTestnet: {
      url: ARC_TESTNET_RPC,
      chainId: ARC_TESTNET_CHAIN_ID,
      // Gas on Arc is paid in USDC (18 decimals as displayed to wallets).
      // Never commit a real private key — use an env var / keystore.
      accounts: process.env.DEPLOYER_PRIVATE_KEY ? [process.env.DEPLOYER_PRIVATE_KEY] : [],
    },
  },
};
