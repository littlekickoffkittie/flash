/* 
Refactored and cleaned EnhancedFlashLoanArbitrage contract for improved readability, consistency, and maintainability.
- Grouped imports and interfaces logically.
- Added comments for clarity.
- Improved naming consistency.
- Refactored large functions into smaller internal functions.
- Ensured consistent error handling and event emissions.
- Removed redundant code.
- Improved formatting and style.
*/

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./ReentrancyGuard.sol";
import "./Pausable.sol";
import "./Ownable.sol";
import "./IERC20.sol";
import "./SafeERC20.sol";

interface IERC20Extended is IERC20 {
    function decimals() external view returns (uint8);
}

interface IUniswapV2Router {
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);

    function getAmountsOut(uint amountIn, address[] calldata path) 
        external 
        view 
        returns (uint[] memory amounts);

    function factory() external pure returns (address);
}

interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

interface IUniswapV2Pair {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function token0() external view returns (address);
    function token1() external view returns (address);
}

interface ILendingPool {
    function flashLoan(
        address receiver,
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata modes,
        address onBehalfOf,
        bytes calldata params,
        uint16 referralCode
    ) external;
}

interface IPriceOracle {
    function getPrice(address token) external view returns (uint256);
    function getPriceWithDecimals(address token) external view returns (uint256 price, uint8 decimals);
}

contract EnhancedFlashLoanArbitrage is ReentrancyGuard, Pausable, Ownable {
    using SafeERC20 for IERC20;

    // Core contracts
    ILendingPool public immutable lendingPool;
    IUniswapV2Router public immutable uniswapRouter;
    IUniswapV2Router public immutable sushiswapRouter;
    IPriceOracle public priceOracle;

    // Configuration structs
    struct ArbitrageConfig {
        uint256 maxSlippage;        // basis points (e.g., 50 = 0.5%)
        uint256 minProfitBps;       // minimum profit in basis points
        uint256 maxGasPrice;        // maximum gas price in wei
        uint256 maxLoanAmount;      // maximum loan amount per token
        bool dynamicSlippage;       // enable dynamic slippage calculation
    }

    struct TokenConfig {
        bool isWhitelisted;
        uint256 maxLoanAmount;
        uint256 customSlippage;     // custom slippage for this token
        bool requiresOracle;        // require oracle price validation
    }

    // State variables
    ArbitrageConfig public config;
    mapping(address => TokenConfig) public tokenConfigs;
    mapping(address => uint256) public dailyVolume;
    mapping(address => uint256) public lastDailyReset;

    // Circuit breaker variables
    uint256 public dailyLossLimit = 1 ether; // 1 ETH worth
    uint256 public dailyLoss;
    uint256 public lastLossReset;
    bool public emergencyStop;

    // Performance tracking struct
    struct PerformanceMetrics {
        uint256 totalTrades;
        uint256 successfulTrades;
        uint256 totalProfit;
        uint256 totalLoss;
        uint256 averageGasUsed;
        uint256 lastUpdateTime;
    }

    PerformanceMetrics public performance;

    // Events
    event ArbitrageExecuted(
        address indexed borrowToken,
        address indexed targetToken,
        uint256 loanAmount,
        uint256 profit,
        uint256 gasUsed,
        bool success
    );

    event ConfigUpdated(
        uint256 maxSlippage,
        uint256 minProfitBps,
        uint256 maxGasPrice,
        uint256 maxLoanAmount,
        bool dynamicSlippage
    );

    event TokenWhitelisted(address indexed token, uint256 maxLoanAmount);
    event TokenBlacklisted(address indexed token);
    event EmergencyStopToggled(bool enabled);
    event ProfitWithdrawn(address indexed token, uint256 amount);
    event LiquidityChecked(address indexed pair, uint256 reserve0, uint256 reserve1);

    // Custom errors
    error OnlyOwner();
    error ContractPaused();
    error EmergencyStopActive();
    error TokenNotWhitelisted(address token);
    error InsufficientProfit(uint256 actual, uint256 required);
    error ExcessiveSlippage(uint256 actual, uint256 maximum);
    error LoanAmountTooHigh(uint256 requested, uint256 maximum);
    error DailyVolumeExceeded(address token, uint256 current, uint256 limit);
    error DailyLossLimitExceeded(uint256 currentLoss, uint256 limit);
    error GasPriceTooHigh(uint256 current, uint256 maximum);
    error InsufficientLiquidity(address pair, uint256 required, uint256 available);
    error CallerNotLendingPool();
    error InitiatorNotContract();
    error SwapFailed();
    error OraclePriceDeviation();
    error InsufficientBalance(uint256 actual, uint256 required);

    // Modifiers
    modifier onlyWhenActive() {
        if (paused()) revert ContractPaused();
        if (emergencyStop) revert EmergencyStopActive();
        if (tx.gasprice > config.maxGasPrice) revert GasPriceTooHigh(tx.gasprice, config.maxGasPrice);
        _;
    }

    modifier validToken(address token) {
        if (!tokenConfigs[token].isWhitelisted) revert TokenNotWhitelisted(token);
        _;
    }

    constructor(
        address _lendingPool,
        address _uniswapRouter,
        address _sushiswapRouter,
        address _priceOracle
    ) {
        lendingPool = ILendingPool(_lendingPool);
        uniswapRouter = IUniswapV2Router(_uniswapRouter);
        sushiswapRouter = IUniswapV2Router(_sushiswapRouter);
        priceOracle = IPriceOracle(_priceOracle);

        // Default configuration
        config = ArbitrageConfig({
            maxSlippage: 50,           // 0.5%
            minProfitBps: 10,          // 0.1%
            maxGasPrice: 50 gwei,
            maxLoanAmount: 100 ether,
            dynamicSlippage: true
        });

        lastLossReset = block.timestamp;
    }

    // Main arbitrage function with enhanced safety
    function executeArbitrage(
        address borrowToken,
        uint256 borrowAmount,
        address targetToken,
        uint256 expectedProfit
    ) external onlyOwner onlyWhenActive validToken(borrowToken) validToken(targetToken) nonReentrant {
        uint256 gasStart = gasleft();
        
        // Pre-execution validations
        _validateTradeParameters(borrowToken, borrowAmount, targetToken, expectedProfit);
        _checkLiquidity(borrowToken, targetToken, borrowAmount);
        _updateDailyVolume(borrowToken, borrowAmount);

        // Execute flash loan
        address[] memory assets = new address[](1);
        assets[0] = borrowToken;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = borrowAmount;
        uint256[] memory modes = new uint256[](1);
        modes[0] = 0;

        bytes memory params = abi.encode(
            borrowToken,
            targetToken,
            borrowAmount,
            expectedProfit,
            gasStart
        );

        lendingPool.flashLoan(
            address(this),
            assets,
            amounts,
            modes,
            address(this),
            params,
            0
        );
    }

    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address initiator,
        bytes calldata params
    ) external returns (bool) {
        if (msg.sender != address(lendingPool)) revert CallerNotLendingPool();
        if (initiator != address(this)) revert InitiatorNotContract();

        (
            address borrowToken,
            address targetToken,
            uint256 borrowAmount,
            uint256 expectedProfit,
            uint256 gasStart
        ) = abi.decode(params, (address, address, uint256, uint256, uint256));

        uint256 loanAmount = amounts[0];
        uint256 premium = premiums[0];
        uint256 totalDebt = loanAmount + premium;

        uint256 initialBalance = IERC20(borrowToken).balanceOf(address(this));
        bool success = false;
        uint256 actualProfit = 0;

        try this._executeArbitrageLogic(borrowToken, targetToken, loanAmount, premium) returns (uint256 profit) {
            actualProfit = profit;
            
            // Validate minimum profit
            uint256 minProfit = (loanAmount * config.minProfitBps) / 10000;
            if (actualProfit < minProfit) {
                revert InsufficientProfit(actualProfit, minProfit);
            }

            // Oracle price validation if required
            if (tokenConfigs[borrowToken].requiresOracle || tokenConfigs[targetToken].requiresOracle) {
                _validateOraclePrice(borrowToken, targetToken, actualProfit, loanAmount);
            }

            success = true;
            _updatePerformanceMetrics(true, actualProfit, gasStart);
        } catch Error(string memory reason) {
            _handleArbitrageFailed(reason, gasStart);
            // Still need to repay the loan
        } catch {
            _handleArbitrageFailed("Unknown error", gasStart);
        }

        // Repay flash loan
        IERC20(borrowToken).safeApprove(address(lendingPool), totalDebt);
        
        uint256 contractBalance = IERC20(borrowToken).balanceOf(address(this));
        if (contractBalance < totalDebt) {
            revert InsufficientBalance(contractBalance, totalDebt);
        }

        uint256 gasUsed = gasStart - gasleft();
        emit ArbitrageExecuted(borrowToken, targetToken, loanAmount, actualProfit, gasUsed, success);

        return true;
    }

    function _executeArbitrageLogic(
        address borrowToken,
        address targetToken,
        uint256 loanAmount,
        uint256 premium
    ) external returns (uint256 profit) {
        require(msg.sender == address(this), "Unauthorized");

        uint256 initialBalance = IERC20(borrowToken).balanceOf(address(this));

        // Calculate dynamic slippage if enabled
        uint256 slippage = config.dynamicSlippage 
            ? _calculateDynamicSlippage(borrowToken, targetToken, loanAmount)
            : config.maxSlippage;

        // Step 1: Buy on Uniswap (or lower price DEX)
        uint256 targetTokens = _executeSwap(
            uniswapRouter,
            borrowToken,
            targetToken,
            loanAmount,
            slippage
        );

        // Step 2: Sell on Sushiswap (or higher price DEX)
        uint256 returnedTokens = _executeSwap(
            sushiswapRouter,
            targetToken,
            borrowToken,
            targetTokens,
            slippage
        );

        uint256 finalBalance = IERC20(borrowToken).balanceOf(address(this));
        
        // Calculate actual profit (accounting for initial balance and premium)
        if (finalBalance > initialBalance + premium) {
            profit = finalBalance - initialBalance - premium;
        } else {
            revert InsufficientProfit(0, premium);
        }
    }

    function _executeSwap(
        IUniswapV2Router router,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 slippage
    ) internal returns (uint256 amountOut) {
        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;

        uint[] memory amountsOut = router.getAmountsOut(amountIn, path);
        uint256 minOut = (amountsOut[1] * (10000 - slippage)) / 10000;

        IERC20(tokenIn).safeApprove(address(router), amountIn);
        
        uint[] memory amounts = router.swapExactTokensForTokens(
            amountIn,
            minOut,
            path,
            address(this),
            block.timestamp + 300
        );

        return amounts[1];
    }

    function _calculateDynamicSlippage(
        address borrowToken,
        address targetToken,
        uint256 loanAmount
    ) internal view returns (uint256) {
        // Get liquidity from both pairs
        address uniPair = IUniswapV2Factory(uniswapRouter.factory()).getPair(borrowToken, targetToken);
        address sushiPair = IUniswapV2Factory(sushiswapRouter.factory()).getPair(borrowToken, targetToken);

        if (uniPair == address(0) || sushiPair == address(0)) {
            return config.maxSlippage;
        }

        (uint112 uniReserve0, uint112 uniReserve1,) = IUniswapV2Pair(uniPair).getReserves();
        (uint112 sushiReserve0, uint112 sushiReserve1,) = IUniswapV2Pair(sushiPair).getReserves();

        // Calculate liquidity impact
        uint256 avgLiquidity = (uint256(uniReserve0) + uint256(sushiReserve0)) / 2;
        uint256 liquidityImpact = (loanAmount * 10000) / avgLiquidity;

        // Dynamic slippage: base slippage + liquidity impact
        uint256 dynamicSlippage = config.maxSlippage + (liquidityImpact / 10);
        
        // Cap at maximum slippage
        return dynamicSlippage > config.maxSlippage * 2 ? config.maxSlippage * 2 : dynamicSlippage;
    }

    function _validateTradeParameters(
        address borrowToken,
        uint256 borrowAmount,
        address targetToken,
        uint256 expectedProfit
    ) internal view {
        // Check loan amount limits
        uint256 maxLoan = tokenConfigs[borrowToken].maxLoanAmount > 0 
            ? tokenConfigs[borrowToken].maxLoanAmount 
            : config.maxLoanAmount;
        
        if (borrowAmount > maxLoan) {
            revert LoanAmountTooHigh(borrowAmount, maxLoan);
        }

        // Check expected profit is reasonable
        uint256 minExpectedProfit = (borrowAmount * config.minProfitBps) / 10000;
        if (expectedProfit < minExpectedProfit) {
            revert InsufficientProfit(expectedProfit, minExpectedProfit);
        }
    }

    function _checkLiquidity(
        address borrowToken,
        address targetToken,
        uint256 loanAmount
    ) internal {
        address uniPair = IUniswapV2Factory(uniswapRouter.factory()).getPair(borrowToken, targetToken);
        address sushiPair = IUniswapV2Factory(sushiswapRouter.factory()).getPair(borrowToken, targetToken);

        if (uniPair != address(0)) {
            (uint112 reserve0, uint112 reserve1,) = IUniswapV2Pair(uniPair).getReserves();
            address token0 = IUniswapV2Pair(uniPair).token0();
            
            uint256 relevantReserve = token0 == borrowToken ? reserve0 : reserve1;
            uint256 requiredLiquidity = loanAmount * 5; // Require 5x liquidity
            
            if (relevantReserve < requiredLiquidity) {
                revert InsufficientLiquidity(uniPair, requiredLiquidity, relevantReserve);
            }
            
            emit LiquidityChecked(uniPair, reserve0, reserve1);
        }
    }

    function _updateDailyVolume(address token, uint256 amount) internal {
        if (block.timestamp > lastDailyReset[token] + 1 days) {
            dailyVolume[token] = 0;
            lastDailyReset[token] = block.timestamp;
        }

        uint256 maxDaily = tokenConfigs[token].maxLoanAmount > 0 
            ? tokenConfigs[token].maxLoanAmount * 10 
            : config.maxLoanAmount * 10;

        if (dailyVolume[token] + amount > maxDaily) {
            revert DailyVolumeExceeded(token, dailyVolume[token] + amount, maxDaily);
        }

        dailyVolume[token] += amount;
    }

    function _validateOraclePrice(
        address borrowToken,
        address targetToken,
        uint256 profit,
        uint256 loanAmount
    ) internal view {
        try priceOracle.getPrice(borrowToken) returns (uint256 borrowPrice) {
            try priceOracle.getPrice(targetToken) returns (uint256 targetPrice) {
                uint256 expectedProfitFromOracle = _calculateExpectedProfit(
                    borrowPrice,
                    targetPrice,
                    loanAmount
                );
                
                // Allow 20% deviation from oracle price
                uint256 deviation = profit > expectedProfitFromOracle 
                    ? ((profit - expectedProfitFromOracle) * 10000) / expectedProfitFromOracle
                    : ((expectedProfitFromOracle - profit) * 10000) / expectedProfitFromOracle;
                
                if (deviation > 2000) { // 20%
                    revert OraclePriceDeviation();
                }
            } catch {
                // Oracle unavailable for target token, skip validation
            }
        } catch {
            // Oracle unavailable for borrow token, skip validation
        }
    }

    function _calculateExpectedProfit(
        uint256 borrowPrice,
        uint256 targetPrice,
        uint256 loanAmount
    ) internal pure returns (uint256) {
        // Simplified calculation - in reality, you'd account for DEX spreads
        return (loanAmount * borrowPrice) / targetPrice;
    }

    function _updatePerformanceMetrics(bool success, uint256 profit, uint256 gasStart) internal {
        performance.totalTrades++;
        if (success) {
            performance.successfulTrades++;
            performance.totalProfit += profit;
        } else {
            uint256 loss = (gasStart - gasleft()) * tx.gasprice;
            performance.totalLoss += loss;
            
            // Update daily loss tracking
            if (block.timestamp > lastLossReset + 1 days) {
                dailyLoss = 0;
                lastLossReset = block.timestamp;
            }
            
            dailyLoss += loss;
            if (dailyLoss > dailyLossLimit) {
                emergencyStop = true;
                emit EmergencyStopToggled(true);
            }
        }
        
        uint256 gasUsed = gasStart - gasleft();
        performance.averageGasUsed = (performance.averageGasUsed * (performance.totalTrades - 1) + gasUsed) / performance.totalTrades;
        performance.lastUpdateTime = block.timestamp;
    }

    function _handleArbitrageFailed(string memory reason, uint256 gasStart) internal {
        _updatePerformanceMetrics(false, 0, gasStart);
        emit ArbitrageExecuted(address(0), address(0), 0, 0, gasStart - gasleft(), false);
    }

    // Configuration functions
    function updateConfig(
        uint256 _maxSlippage,
        uint256 _minProfitBps,
        uint256 _maxGasPrice,
        uint256 _maxLoanAmount,
        bool _dynamicSlippage
    ) external onlyOwner {
        // Update configuration parameters
        config.maxSlippage = _maxSlippage;
        config.minProfitBps = _minProfitBps;
        config.maxGasPrice = _maxGasPrice;
        config.maxLoanAmount = _maxLoanAmount;
        config.dynamicSlippage = _dynamicSlippage;
        
        // Emit event with updated configuration
        emit ConfigUpdated(_maxSlippage, _minProfitBps, _maxGasPrice, _maxLoanAmount, _dynamicSlippage);
    }

    function whitelistToken(
        address token,
        uint256 maxLoanAmount,
        uint256 customSlippage,
        bool requiresOracle
    ) external onlyOwner {
        tokenConfigs[token] = TokenConfig({
            isWhitelisted: true,
            maxLoanAmount: maxLoanAmount,
            customSlippage: customSlippage,
            requiresOracle: requiresOracle
        });
        
        emit TokenWhitelisted(token, maxLoanAmount);
    }

    function blacklistToken(address token) external onlyOwner {
        tokenConfigs[token].isWhitelisted = false;
        emit TokenBlacklisted(token);
    }

    function setPriceOracle(address _priceOracle) external onlyOwner {
        priceOracle = IPriceOracle(_priceOracle);
    }

    // Emergency functions
    function toggleEmergencyStop() external onlyOwner {
        emergencyStop = !emergencyStop;
        emit EmergencyStopToggled(emergencyStop);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // Profit withdrawal

    function withdrawProfits(address token) external onlyOwner {
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance > 0) {
            IERC20(token).safeTransfer(owner(), balance);
            emit ProfitWithdrawn(token, balance);
        }
    }

    function withdrawAllProfits(address[] calldata tokens) external onlyOwner {
        for (uint256 i = 0; i < tokens.length; i++) {
            this.withdrawProfits(tokens[i]);
        }
    }

    function withdrawStuckTokens(address token, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(owner(), amount);
    }

    // Emergency ETH withdrawal
    function withdrawETH() external onlyOwner {
        uint256 balance = address(this).balance;
        if (balance > 0) {
            payable(owner()).transfer(balance);
        }
    }

    // View functions
    function getPerformanceMetrics() external view returns (PerformanceMetrics memory) {
        return performance;
    }

    function getTokenConfig(address token) external view returns (TokenConfig memory) {
        return tokenConfigs[token];
    }

    function getDailyVolume(address token) external view returns (uint256) {
        if (block.timestamp > lastDailyReset[token] + 1 days) {
            return 0;
        }
        return dailyVolume[token];
    }

    function estimateGasCost(
        address borrowToken,
        address targetToken,
        uint256 loanAmount
    ) external view returns (uint256) {
        // Rough estimation - actual implementation would use more sophisticated calculation
        return 300000 * tx.gasprice; // ~300k gas typical for flash loan arbitrage
    }

    // Receive ETH
    receive() external payable {}
}
