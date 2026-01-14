// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@aave/core-v3/contracts/flashloan/interfaces/IFlashLoanSimpleReceiver.sol";
import "@aave/core-v3/contracts/interfaces/IPoolAddressesProvider.sol";
import "@aave/core-v3/contracts/interfaces/IPool.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract FlashLoan is IFlashLoanSimpleReceiver {
    address public owner;
    IPoolAddressesProvider public provider;

    constructor(address _provider) {
        owner = msg.sender;
        provider = IPoolAddressesProvider(_provider);
    }

    function executeFlashLoan(address asset, uint256 amount) external {
        require(msg.sender == owner, "Only owner");
        address receiver = address(this);
        bytes memory params = "";
        uint16 referralCode = 0;

        IPool pool = IPool(provider.getPool());
        pool.flashLoanSimple(receiver, asset, amount, params, referralCode);
    }

    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address initiator,
        bytes calldata params
    ) external override returns (bool) {
        // Your arbitrage or logic here (e.g., swap on DEX, profit, repay)
        uint256 amountOwing = amount + premium;
        IERC20(asset).approve(address(provider.getPool()), amountOwing);
        return true;
    }

    // Added: Required by IFlashLoanSimpleReceiver
    function ADDRESSES_PROVIDER() external view override returns (IPoolAddressesProvider) {
        return provider;
    }

    // Added: Required by IFlashLoanSimpleReceiver
    function POOL() external view override returns (IPool) {
        return IPool(provider.getPool());
    }
}