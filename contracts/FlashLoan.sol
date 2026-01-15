// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@aave/core-v3/contracts/flashloan/interfaces/IFlashLoanSimpleReceiver.sol";
import "@aave/core-v3/contracts/interfaces/IPoolAddressesProvider.sol";
import "@aave/core-v3/contracts/interfaces/IPool.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

// Import Uniswap interfaces
import {IUniswapV2Router02} from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import {ISwapRouter as IUniswapV3Router} from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import {IQuoter as IUniswapV3Quoter} from "@uniswap/v3-periphery/contracts/interfaces/IQuoter.sol";

// Uniswap V4 imports
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

contract FlashLoan is IFlashLoanSimpleReceiver, IUnlockCallback {
    address public owner;
    IPoolAddressesProvider public provider;
    AggregatorV3Interface public ethUsdOracle;

    uint256 public constant COMMISSION_USD = 2 * 10**18;

    constructor(address _provider, address _ethUsdOracle) {
        owner = msg.sender;
        provider = IPoolAddressesProvider(_provider);
        ethUsdOracle = AggregatorV3Interface(_ethUsdOracle);
    }

    function executeFlashLoan(address asset, uint256 amount, bytes memory params) external payable {
        uint256 ethPriceInUsd = getEthPriceInUsd();
        uint256 requiredFeeInEth = (COMMISSION_USD * 10**18) / ethPriceInUsd;

        require(msg.value >= requiredFeeInEth, "Insufficient commission fee (2 USD in ETH)");

        address receiver = address(this);
        uint16 referralCode = 0;
        IPool pool = IPool(provider.getPool());
        pool.flashLoanSimple(receiver, asset, amount, params, referralCode);

        if (msg.value > requiredFeeInEth) {
            payable(msg.sender).transfer(msg.value - requiredFeeInEth);
        }
    }

    // Single swap configuration
    struct SwapConfig {
        address router;
        uint8 routerType; // 0 = V2, 1 = V3, 2 = V4
        address tokenIn;
        address tokenOut;
        uint24 fee; // For V3/V4
        int24 tickSpacing; // For V4
        address hooks; // For V4
        bool zeroForOne; // For V4
        uint160 sqrtPriceLimitX96; // For V3/V4
        bytes hookData; // For V4
        uint256 amountOutMin; // Slippage protection
    }

    // Multi-swap parameters
    struct MultiSwapParams {
        SwapConfig[] swaps;
    }

    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address initiator,
        bytes calldata params
    ) external override returns (bool) {
        require(msg.sender == address(provider.getPool()), "Caller must be Aave Pool");
        
        MultiSwapParams memory multiSwap = abi.decode(params, (MultiSwapParams));
        require(multiSwap.swaps.length > 0, "No swaps provided");

        // Verify first swap starts with flash loan asset
        require(multiSwap.swaps[0].tokenIn == asset, "First swap must start with flash loan asset");
        
        // Verify last swap ends with flash loan asset
        require(multiSwap.swaps[multiSwap.swaps.length - 1].tokenOut == asset, "Last swap must end with flash loan asset");

        uint256 currentAmount = amount;
        address currentToken = asset;

        // Execute all swaps in sequence
        for (uint256 i = 0; i < multiSwap.swaps.length; i++) {
            SwapConfig memory swap = multiSwap.swaps[i];
            
            // Verify token continuity
            require(swap.tokenIn == currentToken, "Token mismatch in swap chain");

            currentAmount = _executeSwap(swap, currentAmount);
            currentToken = swap.tokenOut;
        }

        // Check repayment
        uint256 amountOwing = amount + premium;
        uint256 assetBack = IERC20(asset).balanceOf(address(this));
        require(assetBack >= amountOwing, "Insufficient to repay (no arbitrage profit)");

        // Approve repayment
        IERC20(asset).approve(address(provider.getPool()), amountOwing);

        // Send profit to initiator
        if (assetBack > amountOwing) {
            IERC20(asset).transfer(initiator, assetBack - amountOwing);
        }

        return true;
    }

    function _executeSwap(SwapConfig memory swap, uint256 amountIn) internal returns (uint256 amountOut) {
        if (swap.routerType == 0) { // Uniswap V2
            IERC20(swap.tokenIn).approve(swap.router, amountIn);
            
            address[] memory path = new address[](2);
            path[0] = swap.tokenIn;
            path[1] = swap.tokenOut;
            
            uint256[] memory amounts = IUniswapV2Router02(swap.router).swapExactTokensForTokens(
                amountIn,
                swap.amountOutMin,
                path,
                address(this),
                block.timestamp + 300
            );
            amountOut = amounts[amounts.length - 1];
            
        } else if (swap.routerType == 1) { // Uniswap V3
            IERC20(swap.tokenIn).approve(swap.router, amountIn);
            
            IUniswapV3Router.ExactInputSingleParams memory v3Params = IUniswapV3Router.ExactInputSingleParams({
                tokenIn: swap.tokenIn,
                tokenOut: swap.tokenOut,
                fee: swap.fee,
                recipient: address(this),
                deadline: block.timestamp + 300,
                amountIn: amountIn,
                amountOutMinimum: swap.amountOutMin,
                sqrtPriceLimitX96: swap.sqrtPriceLimitX96
            });
            amountOut = IUniswapV3Router(swap.router).exactInputSingle(v3Params);
            
        } else if (swap.routerType == 2) { // Uniswap V4
            IERC20(swap.tokenIn).approve(swap.router, amountIn);
            
            bytes memory lockData = abi.encode(
                swap.tokenIn,
                swap.tokenOut,
                amountIn,
                swap.fee,
                swap.tickSpacing,
                swap.hooks,
                swap.zeroForOne,
                swap.sqrtPriceLimitX96,
                swap.hookData,
                swap.amountOutMin
            );
            IPoolManager(swap.router).unlock(lockData);
            amountOut = IERC20(swap.tokenOut).balanceOf(address(this));
            
        } else {
            revert("Invalid router type");
        }
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        (
            address tokenIn,
            address tokenOut,
            uint256 amountIn,
            uint24 fee,
            int24 tickSpacing,
            address hooks,
            bool zeroForOne,
            uint160 sqrtPriceLimitX96,
            bytes memory hookData,
            uint256 amountOutMin
        ) = abi.decode(data, (address, address, uint256, uint24, int24, address, bool, uint160, bytes, uint256));

        IPoolManager manager = IPoolManager(msg.sender);

        // Build PoolKey
        Currency currency0 = Currency.wrap(tokenIn < tokenOut ? tokenIn : tokenOut);
        Currency currency1 = Currency.wrap(tokenIn < tokenOut ? tokenOut : tokenIn);
        
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(hooks)
        });

        // Adjust zeroForOne based on actual currency ordering
        bool actualZeroForOne = (tokenIn == Currency.unwrap(currency0));

        bytes memory swapCalldata = abi.encodeWithSignature(
            "swap((address,address,uint24,int24,address),(bool,int256,uint160),bytes)",
            Currency.unwrap(key.currency0),
            Currency.unwrap(key.currency1),
            key.fee,
            key.tickSpacing,
            address(key.hooks),
            actualZeroForOne,
            -int256(amountIn),
            sqrtPriceLimitX96,
            hookData
        );
        
        (bool success, bytes memory returnData) = address(manager).call(swapCalldata);
        require(success, "V4 swap failed");
        
        BalanceDelta delta = abi.decode(returnData, (BalanceDelta));

        int128 inputDelta = actualZeroForOne ? delta.amount0() : delta.amount1();
        int128 outputDelta = actualZeroForOne ? delta.amount1() : delta.amount0();

        require(inputDelta <= 0, "Invalid input delta");
        require(outputDelta >= 0, "Invalid output delta");
        
        uint128 amountOut = uint128(outputDelta);
        require(amountOut >= amountOutMin, "V4 swap slippage too high");

        // Settle input
        Currency inputCurrency = actualZeroForOne ? key.currency0 : key.currency1;
        uint128 amountToSettle = uint128(-inputDelta);
        
        IERC20(Currency.unwrap(inputCurrency)).transfer(address(manager), amountToSettle);
        manager.sync(inputCurrency);
        manager.settle();

        // Take output
        Currency outputCurrency = actualZeroForOne ? key.currency1 : key.currency0;
        manager.take(outputCurrency, address(this), amountOut);

        return "";
    }

    function withdraw(address token, uint256 withdrawAmount) external {
        require(msg.sender == owner, "Only owner");
        if (token == address(0)) {
            require(address(this).balance >= withdrawAmount, "Insufficient ETH balance");
            payable(owner).transfer(withdrawAmount);
        } else {
            IERC20(token).transfer(owner, withdrawAmount);
        }
    }

    function getEthPriceInUsd() public view returns (uint256) {
        (, int256 price, , , ) = ethUsdOracle.latestRoundData();
        require(price > 0, "Invalid oracle price");
        return uint256(price) * 10**10;
    }

    function ADDRESSES_PROVIDER() external view override returns (IPoolAddressesProvider) {
        return provider;
    }

    function POOL() external view override returns (IPool) {
        return IPool(provider.getPool());
    }

    receive() external payable {}
}