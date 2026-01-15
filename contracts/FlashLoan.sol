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

    // Renamed to avoid any conflicts
    struct ArbitrageParams {
        address router1;
        uint8 routerType1; // 0 = V2, 1 = V3, 2 = V4
        address[] path1;
        uint24 fee1;
        int24 tickSpacing1;
        address hooks1;
        bool zeroForOne1;
        uint160 sqrtPriceLimitX961;
        bytes hookData1;
        uint256 amountOutMin1;
        address router2;
        uint8 routerType2;
        address[] path2;
        uint24 fee2;
        int24 tickSpacing2;
        address hooks2;
        bool zeroForOne2;
        uint160 sqrtPriceLimitX962;
        bytes hookData2;
        uint256 amountOutMin2;
    }

    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address initiator,
        bytes calldata params
    ) external override returns (bool) {
        require(msg.sender == address(provider.getPool()), "Caller must be Aave Pool");
        
        ArbitrageParams memory swapData = abi.decode(params, (ArbitrageParams));

        // First swap
        address intermediate;
        uint256 intermediateAmount;
        
        if (swapData.routerType1 == 0) { // V2
            IERC20(asset).approve(swapData.router1, amount);
            uint256[] memory amounts = IUniswapV2Router02(swapData.router1).swapExactTokensForTokens(
                amount,
                swapData.amountOutMin1,
                swapData.path1,
                address(this),
                block.timestamp + 300
            );
            intermediate = swapData.path1[swapData.path1.length - 1];
            intermediateAmount = amounts[amounts.length - 1];
        } else if (swapData.routerType1 == 1) { // V3
            IERC20(asset).approve(swapData.router1, amount);
            IUniswapV3Router.ExactInputSingleParams memory v3Params1 = IUniswapV3Router.ExactInputSingleParams({
                tokenIn: asset,
                tokenOut: swapData.path1[1],
                fee: swapData.fee1,
                recipient: address(this),
                deadline: block.timestamp + 300,
                amountIn: amount,
                amountOutMinimum: swapData.amountOutMin1,
                sqrtPriceLimitX96: swapData.sqrtPriceLimitX961
            });
            intermediateAmount = IUniswapV3Router(swapData.router1).exactInputSingle(v3Params1);
            intermediate = swapData.path1[1];
        } else if (swapData.routerType1 == 2) { // V4
            IERC20(asset).approve(swapData.router1, amount);
            
            bytes memory lockData = abi.encode(
                0, // Flag for first swap
                asset,
                swapData.path1[1],
                amount,
                swapData.fee1,
                swapData.tickSpacing1,
                swapData.hooks1,
                swapData.zeroForOne1,
                swapData.sqrtPriceLimitX961,
                swapData.hookData1,
                swapData.amountOutMin1
            );
            IPoolManager(swapData.router1).unlock(lockData);
            intermediate = swapData.path1[1];
            intermediateAmount = IERC20(intermediate).balanceOf(address(this));
        } else {
            revert("Invalid router type");
        }

        // Second swap
        if (swapData.routerType2 == 0) { // V2
            IERC20(intermediate).approve(swapData.router2, intermediateAmount);
            IUniswapV2Router02(swapData.router2).swapExactTokensForTokens(
                intermediateAmount,
                swapData.amountOutMin2,
                swapData.path2,
                address(this),
                block.timestamp + 300
            );
        } else if (swapData.routerType2 == 1) { // V3
            IERC20(intermediate).approve(swapData.router2, intermediateAmount);
            IUniswapV3Router.ExactInputSingleParams memory v3Params2 = IUniswapV3Router.ExactInputSingleParams({
                tokenIn: intermediate,
                tokenOut: asset,
                fee: swapData.fee2,
                recipient: address(this),
                deadline: block.timestamp + 300,
                amountIn: intermediateAmount,
                amountOutMinimum: swapData.amountOutMin2,
                sqrtPriceLimitX96: swapData.sqrtPriceLimitX962
            });
            IUniswapV3Router(swapData.router2).exactInputSingle(v3Params2);
        } else if (swapData.routerType2 == 2) { // V4
            IERC20(intermediate).approve(swapData.router2, intermediateAmount);
            bytes memory lockData = abi.encode(
                1, // Flag for second swap
                intermediate,
                asset,
                intermediateAmount,
                swapData.fee2,
                swapData.tickSpacing2,
                swapData.hooks2,
                swapData.zeroForOne2,
                swapData.sqrtPriceLimitX962,
                swapData.hookData2,
                swapData.amountOutMin2
            );
            IPoolManager(swapData.router2).unlock(lockData);
        } else {
            revert("Invalid router type");
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

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        (
            uint8 swapFlag,
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
        ) = abi.decode(data, (uint8, address, address, uint256, uint24, int24, address, bool, uint160, bytes, uint256));

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

        // Encode the swap call manually since we can't use the struct type
        // The function signature is: swap(PoolKey key, SwapParams params, bytes hookData)
        // PoolKey is a struct with (Currency, Currency, uint24, int24, IHooks)
        // SwapParams is a struct with (bool, int256, uint160)
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

        // Determine which deltas correspond to input/output
        int128 inputDelta = actualZeroForOne ? delta.amount0() : delta.amount1();
        int128 outputDelta = actualZeroForOne ? delta.amount1() : delta.amount0();

        // For exact input swaps:
        // - inputDelta should be negative (we owe the pool)
        // - outputDelta should be positive (pool owes us)
        require(inputDelta <= 0, "Invalid input delta");
        require(outputDelta >= 0, "Invalid output delta");
        
        uint128 amountOut = uint128(outputDelta);
        require(amountOut >= amountOutMin, "V4 swap slippage too high");

        // Settle input (pay what we owe to the pool)
        Currency inputCurrency = actualZeroForOne ? key.currency0 : key.currency1;
        uint128 amountToSettle = uint128(-inputDelta);
        
        // Transfer tokens to the manager, then call settle
        // In V4, we sync the currency first, then settle
        IERC20(Currency.unwrap(inputCurrency)).transfer(address(manager), amountToSettle);
        manager.sync(inputCurrency);
        manager.settle();

        // Take output (claim what pool owes us)
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
        return uint256(price) * 10**10; // Chainlink ETH/USD has 8 decimals; adjust to 18
    }

    function ADDRESSES_PROVIDER() external view override returns (IPoolAddressesProvider) {
        return provider;
    }

    function POOL() external view override returns (IPool) {
        return IPool(provider.getPool());
    }

    // Allow contract to receive ETH
    receive() external payable {}
}