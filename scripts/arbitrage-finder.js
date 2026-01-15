const hre = require("hardhat");

const chainConfigs = {
  sepolia: {
    tokens: {
      'USDC': { address: '0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238', decimals: 6 },
      'WETH': { address: '0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14', decimals: 18 },
      'DAI':  { address: '0xFF34B3d4Aee8ddCd6F9AFFFB6Fe49bD371b8a357', decimals: 18 },
      'USDT': { address: '0xaA8E23Fb1079EA71e0a56F48a2aA51851D8433D0', decimals: 6 },
      'WBTC': { address: '0x29f2D40B060688629787a85e92d648F3c49C9521', decimals: 8 },
      'LINK': { address: '0x779877A7B0D9E8603169DdbD7836e478b4624789', decimals: 18 },
      'UNI':  { address: '0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984', decimals: 18 },
      'AAVE': { address: '0x300A18b76A5A0A9C224095493208E0F2B0E0D10D', decimals: 18 }
    },
    routers: {
      'UNISWAP_V2': {
        'address': '0xC532a74256D3Db42D0Bf7a0400fEFDbad7694008',
        'factory': '0x7E0987E5b3a30e3f2828572Bb659A548460a3003',
        'type': 0 
      },
      'SUSHISWAP_V2': {
        'address': '0xeaBcE3E74EF41FB40024a21Cc2ee2F5dDc615791',
        'factory': '0x115934131916c8b277DD010Ee02de727c4123a9f',
        'type': 0 
      },
    }
  },
  ethereum: {
    tokens: {
      'USDC': { address: '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48', decimals: 6 },
      'WETH': { address: '0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2', decimals: 18 },
      'DAI':  { address: '0x6B175474E89094C44Da98b954EedeAC495271d0F', decimals: 18 },
      'USDT': { address: '0xdAC17F958D2ee523a2206206994597C13D831ec7', decimals: 6 },
      'WBTC': { address: '0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599', decimals: 8 },
      'LINK': { address: '0x514910771AF9Ca656af840dff83e8264EcF986CA', decimals: 18 },
      'UNI':  { address: '0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984', decimals: 18 },
      'AAVE': { address: '0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9', decimals: 18 }
    },
    routers: {
      'UNISWAP_V2': {
        'address': '0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D',
        'factory': '0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f',
        'type': 0 
      },
      'SUSHISWAP_V2': {
        'address': '0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F',
        'factory': '0xC0AEe478e3658e2610c5F7A4A2E1777cE9e4f2Ac',
        'type': 0 
      },
    }
  },
  polygon: {
    tokens: {
      'USDC': { address: '0x3c499c542cEF5E3811e1192ce70d8cc03d5c3359', decimals: 6 },
      'WETH': { address: '0x7ceB23fD6bC0add59E62ac25578270cFf1b9f619', decimals: 18 },
      'DAI':  { address: '0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063', decimals: 18 },
      'USDT': { address: '0xc2132D05D31c914a87C6611c10748AEb04B58e8F', decimals: 6 },
      'WBTC': { address: '0x1BFD67037B42Cf73acF20470665bd510a2B9D122', decimals: 8 },
      'LINK': { address: '0x53E0bca35eC356BD5ddDFebbD1Fc0bD1Ee4C7664', decimals: 18 },
      'UNI':  { address: '0xb33EaAd8d9226Ee4d49a7E38F3f7EB9cbae6794e', decimals: 18 },
      'AAVE': { address: '0xD6DF932A45C0f255f85145f286eA0b292B21C90B', decimals: 18 }
    },
    routers: {
      'QUICKSWAP_V2': {
        'address': '0xa5E0829CaCEd8fFDD4De3c53af7D7F506e4f37f5',
        'factory': '0x5757371414417b8C6caad45bAeF941aBc7d3Ab32',
        'type': 0 
      },
      'SUSHISWAP_V2': {
        'address': '0x1b02dA8Cb0d097eB8D57A175b88c7D8b4797e3Cf',
        'factory': '0xc35DADB65012eC5796536bd9864eD8773aBc74C4',
        'type': 0 
      },
    }
  }
};

class ArbitrageFinder {
    constructor(config) {
        this.config = config;
        this.poolCache = new Map();
    }

    async initialize() {
        this.factories = {};
        for (const [name, info] of Object.entries(this.config.routers)) {
            this.factories[name] = await hre.ethers.getContractAt(["function getPair(address,address) view returns (address)"], info.factory);
        }
    }

    format(amount, tokenKey) {
        return Number(hre.ethers.formatUnits(amount, this.config.tokens[tokenKey].decimals)).toFixed(4);
    }

    async poolExists(routerName, tokenA, tokenB) {
        const key = `${routerName}-${tokenA}-${tokenB}`;
        if (this.poolCache.has(key)) return this.poolCache.get(key);
        let addr;
        try {
            addr = await this.factories[routerName].getPair(tokenA, tokenB);
        } catch (e) { addr = hre.ethers.ZeroAddress; }
        const exists = addr !== hre.ethers.ZeroAddress;
        this.poolCache.set(key, exists);
        return exists;
    }

    async getBestQuote(amountIn, tokenInKey, tokenOutKey) {
        let bestOut = 0n;
        let bestRouter = null;
        const tIn = this.config.tokens[tokenInKey].address;
        const tOut = this.config.tokens[tokenOutKey].address;

        for (const [name, info] of Object.entries(this.config.routers)) {
            if (await this.poolExists(name, tIn, tOut)) {
                try {
                    const router = await hre.ethers.getContractAt(["function getAmountsOut(uint,address[]) view returns (uint[])"], info.address);
                    const amounts = await router.getAmountsOut(amountIn, [tIn, tOut]);
                    if (amounts[1] > bestOut) {
                        bestOut = amounts[1];
                        bestRouter = name;
                    }
                } catch (e) {}
            }
        }

        if (bestRouter) {
            console.log(`     Best quote from: ${bestRouter}`);
        }

        return bestOut;
    }

    async findTriangularArbitrage(flashAmount, startKey, intermediateKey, bridgeKey) {
        console.log(`\n--- Testing Triangle: ${startKey} -> ${intermediateKey} -> ${bridgeKey} -> ${startKey} ---`);
        
        // Step 1
        const amount1 = await this.getBestQuote(flashAmount, startKey, intermediateKey);
        if (amount1 === 0n) return null;
        console.log(`   Step 1: ${this.format(flashAmount, startKey)} ${startKey} -> ${this.format(amount1, intermediateKey)} ${intermediateKey}`);

        // Step 2
        const amount2 = await this.getBestQuote(amount1, intermediateKey, bridgeKey);
        if (amount2 === 0n) return null;
        console.log(`   Step 2: ${this.format(amount1, intermediateKey)} ${intermediateKey} -> ${this.format(amount2, bridgeKey)} ${bridgeKey}`);

        // Step 3
        const amount3 = await this.getBestQuote(amount2, bridgeKey, startKey);
        if (amount3 === 0n) return null;
        console.log(`   Step 3: ${this.format(amount2, bridgeKey)} ${bridgeKey} -> ${this.format(amount3, startKey)} ${startKey}`);

        const aaveFee = (flashAmount * 9n) / 10000n;
        const profit = amount3 - flashAmount - aaveFee;
        console.log(`   💰 Final Profit: ${this.format(profit, startKey)} ${startKey}`);

        if (profit > 0n) return { path: `${startKey}->${intermediateKey}->${bridgeKey}->${startKey}`, profit: this.format(profit, startKey) };
        return null;
    }
}

async function main() {
    const networkName = hre.network.name;
    const config = chainConfigs[networkName];
    if (!config) {
        throw new Error(`Unsupported network: ${networkName}. Supported: sepolia, mainnet, polygon`);
    }
    console.log(`Running on ${networkName.toUpperCase()}...`);

    const finder = new ArbitrageFinder(config);
    await finder.initialize();

    const flashAmount = 10n * 10n**6n; // $10 USDC
    const results = [];
    const keys = Object.keys(config.tokens);

    console.log("🔍 Initializing Arbitrage Scan...");
    console.log("\n🚀 Starting Full Triangle Scan (Starting from USDC)...");

    // FIXED MANUAL TEST
    const res = await finder.findTriangularArbitrage(flashAmount, 'USDC', 'WETH', 'USDT');
    if (res && parseFloat(res.profit) > 0) results.push(res);

    for (let j = 0; j < keys.length; j++) { // Intermediate Token
        for (let k = 0; k < keys.length; k++) { // Bridge Token
            
            const start = 'USDC'; // We lock the start to USDC
            const inter = keys[j];
            const bridge = keys[k];

            // Skip if any tokens in the triangle are the same
            if (inter !== start && bridge !== start && inter !== bridge) {
                
                const result = await finder.findTriangularArbitrage(flashAmount, start, inter, bridge);
                
                if (result && parseFloat(result.profit) > 0) {
                    results.push(result);
                }
            }
        }
    }

    console.log("\n" + "=".repeat(50));
    if (results.length > 0) {
        console.log("✅ PROFITABLE OPPORTUNITIES FOUND:");
        console.table(results);
    } else {
        console.log("❌ No profitable triangles found.");
        console.log("Tip: Networks may have varying liquidity for 3-hop profit.");
    }
    console.log("=".repeat(50));
}

main().catch(console.error);