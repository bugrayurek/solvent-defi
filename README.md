# Solvent - Built on Arc

A stablecoin money market (lending/borrowing protocol) deployed on Arc Testnet.

Live app: https://solvent-lending.netlify.app
Pool contract: 0x6C895585e22D792543A43069B4BADC8c3860720D on Arc Testnet
Explorer: https://testnet.arcscan.app/address/0x6C895585e22D792543A43069B4BADC8c3860720D

## What it does
- Supply USDC or EURC to earn yield
- Borrow against posted collateral
- Real-time interest rates based on utilization
- Health factor tracking and liquidation support

## Structure
- contracts/ - Solidity smart contracts (SolventLendingPool, mocks)
- scripts/ - Hardhat deployment script
- index.html - frontend (connects via ethers.js + MetaMask)

## Deploy your own
npm install --save-dev hardhat @nomicfoundation/hardhat-toolbox
npx hardhat compile
npx hardhat run scripts/deploy.js --network arcTestnet

Built on Arc (https://www.arc.io), Circle's Layer-1 network. This is an independent project - not affiliated with or endorsed by Circle.
