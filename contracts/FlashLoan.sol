// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@aave/core-v3/contracts/flashloan/interfaces/IFlashLoanSimpleReceiver.sol";
import "@aave/core-v3/contracts/interfaces/IPoolAddressesProvider.sol";
import "@aave/core-v3/contracts/interfaces/IPool.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol"; // For oracle

contract FlashLoan is IFlashLoanSimpleReceiver {
    address public owner;
    IPoolAddressesProvider public provider;
    AggregatorV3Interface public ethUsdOracle; // Chainlink ETH/USD on Sepolia: 0x694AA1769357215DE4FAC081bf1f309aDC325306

    uint256 public constant COMMISSION_USD = 2 * 10**18; // 2 USD with 18 decimals for calculations

    constructor(address _provider, address _ethUsdOracle) {
        owner = msg.sender;
        provider = IPoolAddressesProvider(_provider);
        ethUsdOracle = AggregatorV3Interface(_ethUsdOracle);
    }

    // Payable to receive ETH commission; removed owner restriction
    function executeFlashLoan(address asset, uint256 amount, bytes memory params) external payable {
        // Calculate required commission: 2 USD in ETH wei
        uint256 ethPriceInUsd = getEthPriceInUsd(); // e.g., 2000 USD per ETH
        uint256 requiredFeeInEth = (COMMISSION_USD * 10**18) / ethPriceInUsd; // 2 USD / ETH price * 10^18

        require(msg.value >= requiredFeeInEth, "Insufficient commission fee (2 USD in ETH)");

        // Execute flash loan
        address receiver = address(this);
        uint16 referralCode = 0;
        IPool pool = IPool(provider.getPool());
        pool.flashLoanSimple(receiver, asset, amount, params, referralCode);

        // Refund excess ETH if sent more
        if (msg.value > requiredFeeInEth) {
            payable(msg.sender).transfer(msg.value - requiredFeeInEth);
        }
    }

    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address initiator,
        bytes calldata params
    ) external override returns (bool) {
        // Your logic here (e.g., swaps)
        uint256 amountOwing = amount + premium;
        IERC20(asset).approve(address(provider.getPool()), amountOwing);
        return true;
    }

    // Withdraw function for owner to pull ETH or tokens
    function withdraw(address token, uint256 withdrawAmount) external {
        require(msg.sender == owner, "Only owner");
        if (token == address(0)) {
            // Withdraw ETH
            require(address(this).balance >= withdrawAmount, "Insufficient ETH balance");
            payable(owner).transfer(withdrawAmount);
        } else {
            // Withdraw ERC20 token
            IERC20(token).transfer(owner, withdrawAmount);
        }
    }

    // Get ETH price from Chainlink (returns with 18 decimals)
    function getEthPriceInUsd() public view returns (uint256) {
        (, int256 price, , , ) = ethUsdOracle.latestRoundData();
        require(price > 0, "Invalid oracle price");
        return uint256(price) * 10**10; // Chainlink ETH/USD has 8 decimals; adjust to 18
    }

    // Existing view functions
    function ADDRESSES_PROVIDER() external view override returns (IPoolAddressesProvider) {
        return provider;
    }

    function POOL() external view override returns (IPool) {
        return IPool(provider.getPool());
    }
}