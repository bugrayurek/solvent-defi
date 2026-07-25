// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./IERC20.sol";
import "./ReentrancyGuard.sol";

/// @title Solvent Lending Pool
/// @notice A stablecoin money market. Built on Arc — Circle's EVM-compatible,
///         USDC-gas Layer-1 network with sub-second finality.
/// @dev    Reference/testnet implementation. Interest and price assumptions are
///         simplified for stablecoin pairs (see NOTE blocks). Get this audited
///         before any mainnet deployment or use with real value.
contract SolventLendingPool is ReentrancyGuard {
    // ---------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------

    struct Market {
        bool listed;               // whether this asset market exists
        uint256 totalSupplied;     // total underlying supplied (principal + accrued)
        uint256 totalBorrowed;     // total underlying borrowed (principal + accrued)
        uint256 supplyIndex;       // cumulative interest index for suppliers, 1e18 = 1.0
        uint256 borrowIndex;       // cumulative interest index for borrowers, 1e18 = 1.0
        uint256 lastAccrualTime;   // last block.timestamp interest was accrued
        uint16  collateralFactorBps;   // e.g. 8000 = 80% of supplied value counts as collateral
        uint16  liquidationBonusBps;   // e.g. 500 = liquidator gets 5% bonus on seized collateral
        uint16  reserveFactorBps;      // e.g. 1000 = 10% of interest goes to protocol reserves
        uint256 baseRateBps;       // interest rate at 0% utilization (annualized, bps)
        uint256 slopeBps;          // interest rate slope up to kink (annualized, bps)
        uint256 jumpSlopeBps;      // interest rate slope above kink (annualized, bps)
        uint256 kinkBps;           // utilization point where jump slope kicks in (bps of 10000)
    }

    struct UserAsset {
        uint256 principal;   // underlying amount at last checkpoint
        uint256 index;       // index snapshot at last checkpoint (supply or borrow)
    }

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------

    address public owner;
    address[] public listedAssets;

    mapping(address => Market) public markets;
    mapping(address => uint256) public reserves; // protocol reserves per asset

    // user => asset => position
    mapping(address => mapping(address => UserAsset)) public supplyPositions;
    mapping(address => mapping(address => UserAsset)) public borrowPositions;

    // user => list of assets they have ever touched, for iteration
    mapping(address => address[]) private userAssetsTouched;
    mapping(address => mapping(address => bool)) private userAssetsTouchedSet;

    uint256 private constant BPS = 10_000;
    uint256 private constant RAY = 1e18;
    uint256 private constant SECONDS_PER_YEAR = 365 days;

    // NOTE: This pool assumes all listed assets are USD-pegged stablecoins
    // (e.g. USDC, EURC bridged 1:1 in USD terms is NOT assumed for EURC —
    // see priceOf()) for simplicity. A production deployment must plug in
    // a real price oracle (e.g. Chainlink) instead of priceOf().
    mapping(address => uint256) public priceOverride1e18; // 0 = use default 1.0

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    event MarketListed(address indexed asset);
    event Supplied(address indexed user, address indexed asset, uint256 amount);
    event Withdrawn(address indexed user, address indexed asset, uint256 amount);
    event Borrowed(address indexed user, address indexed asset, uint256 amount);
    event Repaid(address indexed user, address indexed asset, uint256 amount);
    event Liquidated(
        address indexed liquidator,
        address indexed borrower,
        address indexed debtAsset,
        address collateralAsset,
        uint256 repayAmount,
        uint256 collateralSeized
    );

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    // ---------------------------------------------------------------------
    // Admin: list a market
    // ---------------------------------------------------------------------

    function listMarket(
        address asset,
        uint16 collateralFactorBps,
        uint16 liquidationBonusBps,
        uint16 reserveFactorBps,
        uint256 baseRateBps,
        uint256 slopeBps,
        uint256 jumpSlopeBps,
        uint256 kinkBps
    ) external onlyOwner {
        require(!markets[asset].listed, "already listed");
        require(collateralFactorBps <= BPS, "cf > 100%");
        require(kinkBps <= BPS, "kink > 100%");

        markets[asset] = Market({
            listed: true,
            totalSupplied: 0,
            totalBorrowed: 0,
            supplyIndex: RAY,
            borrowIndex: RAY,
            lastAccrualTime: block.timestamp,
            collateralFactorBps: collateralFactorBps,
            liquidationBonusBps: liquidationBonusBps,
            reserveFactorBps: reserveFactorBps,
            baseRateBps: baseRateBps,
            slopeBps: slopeBps,
            jumpSlopeBps: jumpSlopeBps,
            kinkBps: kinkBps
        });
        listedAssets.push(asset);
        emit MarketListed(asset);
    }

    /// @notice Testnet helper — set a manual USD price (1e18) for an asset,
    ///         e.g. if EURC should not be treated as exactly $1. Defaults to $1.
    function setPriceOverride(address asset, uint256 price1e18) external onlyOwner {
        priceOverride1e18[asset] = price1e18;
    }

    // ---------------------------------------------------------------------
    // Interest accrual
    // ---------------------------------------------------------------------

    function _accrue(address asset) internal {
        Market storage m = markets[asset];
        uint256 elapsed = block.timestamp - m.lastAccrualTime;
        if (elapsed == 0) return;

        uint256 utilBps = _utilizationBps(m);
        uint256 borrowRateBps = _borrowRateBps(m, utilBps);

        // simple (non-compounding within the interval) interest accrual
        uint256 interestFactor = (borrowRateBps * elapsed * RAY) / (BPS * SECONDS_PER_YEAR);

        uint256 interestAccrued = (m.totalBorrowed * interestFactor) / RAY;
        if (interestAccrued > 0) {
            uint256 toReserves = (interestAccrued * m.reserveFactorBps) / BPS;
            uint256 toSuppliers = interestAccrued - toReserves;

            m.totalBorrowed += interestAccrued;
            m.totalSupplied += toSuppliers;
            reserves[asset] += toReserves;

            if (m.totalBorrowed > 0) {
                m.borrowIndex += (m.borrowIndex * interestFactor) / RAY;
            }
            if (m.totalSupplied > 0) {
                uint256 supplyFactor = (toSuppliers * RAY) / m.totalSupplied;
                m.supplyIndex += (m.supplyIndex * supplyFactor) / RAY;
            }
        }
        m.lastAccrualTime = block.timestamp;
    }

    function _utilizationBps(Market storage m) internal view returns (uint256) {
        if (m.totalSupplied == 0) return 0;
        return (m.totalBorrowed * BPS) / m.totalSupplied;
    }

    function _borrowRateBps(Market storage m, uint256 utilBps) internal view returns (uint256) {
        if (utilBps <= m.kinkBps) {
            return m.baseRateBps + (m.slopeBps * utilBps) / BPS;
        }
        uint256 normalRate = m.baseRateBps + (m.slopeBps * m.kinkBps) / BPS;
        uint256 excessUtil = utilBps - m.kinkBps;
        return normalRate + (m.jumpSlopeBps * excessUtil) / BPS;
    }

    /// @notice Current annualized borrow APR in bps, for display in the UI.
    function borrowRateBps(address asset) external view returns (uint256) {
        Market storage m = markets[asset];
        return _borrowRateBps(m, _utilizationBps(m));
    }

    /// @notice Current annualized supply APY in bps (approx), for display in the UI.
    function supplyRateBps(address asset) external view returns (uint256) {
        Market storage m = markets[asset];
        uint256 util = _utilizationBps(m);
        uint256 bRate = _borrowRateBps(m, util);
        uint256 rateAfterReserves = (bRate * (BPS - m.reserveFactorBps)) / BPS;
        return (rateAfterReserves * util) / BPS;
    }

    // ---------------------------------------------------------------------
    // Core actions
    // ---------------------------------------------------------------------

    function supply(address asset, uint256 amount) external nonReentrant {
        require(markets[asset].listed, "market not listed");
        require(amount > 0, "zero amount");
        _accrue(asset);
        _touchAsset(msg.sender, asset);

        _settleSupply(msg.sender, asset);
        Market storage m = markets[asset];

        require(IERC20(asset).transferFrom(msg.sender, address(this), amount), "transfer failed");

        supplyPositions[msg.sender][asset].principal += amount;
        supplyPositions[msg.sender][asset].index = m.supplyIndex;
        m.totalSupplied += amount;

        emit Supplied(msg.sender, asset, amount);
    }

    function withdraw(address asset, uint256 amount) external nonReentrant {
        require(amount > 0, "zero amount");
        _accrue(asset);
        _settleSupply(msg.sender, asset);

        UserAsset storage pos = supplyPositions[msg.sender][asset];
        require(pos.principal >= amount, "insufficient supplied balance");

        pos.principal -= amount;
        Market storage m = markets[asset];
        m.totalSupplied -= amount;

        require(_isHealthy(msg.sender), "withdrawal breaks health factor");
        require(IERC20(asset).transfer(msg.sender, amount), "transfer failed");

        emit Withdrawn(msg.sender, asset, amount);
    }

    function borrow(address asset, uint256 amount) external nonReentrant {
        require(markets[asset].listed, "market not listed");
        require(amount > 0, "zero amount");
        _accrue(asset);
        _touchAsset(msg.sender, asset);
        _settleBorrow(msg.sender, asset);

        Market storage m = markets[asset];
        require(m.totalSupplied - m.totalBorrowed >= amount, "insufficient liquidity");

        borrowPositions[msg.sender][asset].principal += amount;
        borrowPositions[msg.sender][asset].index = m.borrowIndex;
        m.totalBorrowed += amount;

        require(_isHealthy(msg.sender), "borrow breaks health factor");
        require(IERC20(asset).transfer(msg.sender, amount), "transfer failed");

        emit Borrowed(msg.sender, asset, amount);
    }

    function repay(address asset, uint256 amount) external nonReentrant {
        require(amount > 0, "zero amount");
        _accrue(asset);
        _settleBorrow(msg.sender, asset);

        UserAsset storage pos = borrowPositions[msg.sender][asset];
        uint256 payAmount = amount > pos.principal ? pos.principal : amount;
        require(payAmount > 0, "nothing to repay");

        require(IERC20(asset).transferFrom(msg.sender, address(this), payAmount), "transfer failed");

        pos.principal -= payAmount;
        Market storage m = markets[asset];
        m.totalBorrowed -= payAmount;

        emit Repaid(msg.sender, asset, payAmount);
    }

    /// @notice Liquidate an unhealthy borrower's position, seizing collateral at a bonus.
    function liquidate(
        address borrower,
        address debtAsset,
        uint256 repayAmount,
        address collateralAsset
    ) external nonReentrant {
        _accrue(debtAsset);
        _accrue(collateralAsset);
        _settleBorrow(borrower, debtAsset);
        _settleSupply(borrower, collateralAsset);

        require(!_isHealthy(borrower), "borrower is healthy");

        UserAsset storage debtPos = borrowPositions[borrower][debtAsset];
        uint256 actualRepay = repayAmount > debtPos.principal ? debtPos.principal : repayAmount;
        require(actualRepay > 0, "nothing to liquidate");

        require(IERC20(debtAsset).transferFrom(msg.sender, address(this), actualRepay), "transfer failed");

        debtPos.principal -= actualRepay;
        markets[debtAsset].totalBorrowed -= actualRepay;

        // Seize collateral: repaid value + liquidation bonus, converted via price
        uint256 debtValue = (actualRepay * _priceOf(debtAsset)) / RAY;
        uint256 bonusBps = markets[collateralAsset].liquidationBonusBps;
        uint256 seizeValue = (debtValue * (BPS + bonusBps)) / BPS;
        uint256 seizeAmount = (seizeValue * RAY) / _priceOf(collateralAsset);

        UserAsset storage collPos = supplyPositions[borrower][collateralAsset];
        if (seizeAmount > collPos.principal) {
            seizeAmount = collPos.principal; // cap at available collateral
        }
        collPos.principal -= seizeAmount;
        markets[collateralAsset].totalSupplied -= seizeAmount;

        require(IERC20(collateralAsset).transfer(msg.sender, seizeAmount), "transfer failed");

        emit Liquidated(msg.sender, borrower, debtAsset, collateralAsset, actualRepay, seizeAmount);
    }

    // ---------------------------------------------------------------------
    // Internal accounting helpers
    // ---------------------------------------------------------------------

    function _settleSupply(address user, address asset) internal {
        UserAsset storage pos = supplyPositions[user][asset];
        if (pos.principal == 0) {
            pos.index = markets[asset].supplyIndex;
            return;
        }
        uint256 currentIndex = markets[asset].supplyIndex;
        if (pos.index == 0) pos.index = RAY;
        uint256 accrued = (pos.principal * currentIndex) / pos.index;
        pos.principal = accrued;
        pos.index = currentIndex;
    }

    function _settleBorrow(address user, address asset) internal {
        UserAsset storage pos = borrowPositions[user][asset];
        if (pos.principal == 0) {
            pos.index = markets[asset].borrowIndex;
            return;
        }
        uint256 currentIndex = markets[asset].borrowIndex;
        if (pos.index == 0) pos.index = RAY;
        uint256 accrued = (pos.principal * currentIndex) / pos.index;
        pos.principal = accrued;
        pos.index = currentIndex;
    }

    function _touchAsset(address user, address asset) internal {
        if (!userAssetsTouchedSet[user][asset]) {
            userAssetsTouchedSet[user][asset] = true;
            userAssetsTouched[user].push(asset);
        }
    }

    /// @dev NOTE: returns a fixed $1.00 (1e18) unless an owner-set override
    ///      exists. Replace with a real oracle (e.g. Chainlink) before any
    ///      deployment involving real value.
    function _priceOf(address asset) internal view returns (uint256) {
        uint256 override_ = priceOverride1e18[asset];
        return override_ == 0 ? RAY : override_;
    }

    function priceOf(address asset) external view returns (uint256) {
        return _priceOf(asset);
    }

    // ---------------------------------------------------------------------
    // Health factor
    // ---------------------------------------------------------------------

    /// @notice Health factor scaled by 1e18. >= 1e18 is healthy. Returns
    ///         type(uint256).max if the user has no debt.
    function healthFactor(address user) public view returns (uint256) {
        uint256 collateralValue;
        uint256 debtValue;

        address[] memory touched = userAssetsTouched[user];
        for (uint256 i = 0; i < touched.length; i++) {
            address asset = touched[i];
            Market storage m = markets[asset];

            UserAsset memory sp = supplyPositions[user][asset];
            if (sp.principal > 0) {
                uint256 idx = sp.index == 0 ? RAY : sp.index;
                uint256 currentBal = (sp.principal * m.supplyIndex) / idx;
                uint256 value = (currentBal * _priceOf(asset)) / RAY;
                collateralValue += (value * m.collateralFactorBps) / BPS;
            }

            UserAsset memory bp = borrowPositions[user][asset];
            if (bp.principal > 0) {
                uint256 bidx = bp.index == 0 ? RAY : bp.index;
                uint256 currentDebt = (bp.principal * m.borrowIndex) / bidx;
                debtValue += (currentDebt * _priceOf(asset)) / RAY;
            }
        }

        if (debtValue == 0) return type(uint256).max;
        return (collateralValue * RAY) / debtValue;
    }

    function _isHealthy(address user) internal view returns (bool) {
        return healthFactor(user) >= RAY;
    }

    // ---------------------------------------------------------------------
    // View helpers for the frontend
    // ---------------------------------------------------------------------

    function getMarket(address asset) external view returns (Market memory) {
        return markets[asset];
    }

    function getListedAssets() external view returns (address[] memory) {
        return listedAssets;
    }

    function getUserSupply(address user, address asset) external view returns (uint256) {
        UserAsset memory sp = supplyPositions[user][asset];
        if (sp.principal == 0) return 0;
        uint256 idx = sp.index == 0 ? RAY : sp.index;
        return (sp.principal * markets[asset].supplyIndex) / idx;
    }

    function getUserBorrow(address user, address asset) external view returns (uint256) {
        UserAsset memory bp = borrowPositions[user][asset];
        if (bp.principal == 0) return 0;
        uint256 idx = bp.index == 0 ? RAY : bp.index;
        return (bp.principal * markets[asset].borrowIndex) / idx;
    }
}
