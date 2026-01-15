const hre = require("hardhat");

const TOKENS = {
    'USDC': { address: '0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238', decimals: 6 },
    'WETH': { address: '0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14', decimals: 18 },
    'DAI':  { address: '0xFF34B3d4Aee8ddCd6F9AFFFB6Fe49bD371b8a357', decimals: 18 },
    'USDT': { address: '0xaA8E23Fb1079EA71e0a56F48a2aA51851D8433D0', decimals: 6 },
    'WBTC': { address: '0x29f2D40B060688629787a85e92d648F3c49C9521', decimals: 8 },
    'LINK': { address: '0x779877A7B0D9E8603169DdbD7836e478b4624789', decimals: 18 },
    'UNI':  { address: '0x1f9840a85d5af5bf1d1762f925bdaddc4201f984', decimals: 18 },
    'AAVE': { address: '0x300A18b76A5A0A9C224095493208E0F2B0E0D10D', decimals: 18 }
};

const ROUTERS = {
    'UNISWAP_V2': {
        'address': '0xC532a74256D3Db42D0Bf7a0400fEFDbad7694008',
        'factory': '0x7E0987E5b3a30e3f2828572Bb659A548460a3003',
        'type': 0 
    }
};

const FACTORY_ABI = ["function getPair(address,address) view returns (address)", "function getPool(address,address,uint24) view returns (address)"];

class ArbitrageFinder {
    constructor() {
        this.poolCache = new Map();
    }

    async initialize() {
        this.v2Factory = await hre.ethers.getContractAt(FACTORY_ABI, ROUTERS.UNISWAP_V2.factory);
    }

    format(amount, tokenKey) {
        return Number(hre.ethers.formatUnits(amount, TOKENS[tokenKey].decimals)).toFixed(4);
    }

    async poolExists(tokenA, tokenB, type, fee = 0) {
        const key = `${type}-${tokenA}-${tokenB}-${fee}`;
        if (this.poolCache.has(key)) return this.poolCache.get(key);
        let addr;
        try {
            addr = (type === 0) ? await this.v2Factory.getPair(tokenA, tokenB) : await this.v3Factory.getPool(tokenA, tokenB, fee);
        } catch (e) { addr = hre.ethers.ZeroAddress; }
        const exists = addr !== hre.ethers.ZeroAddress;
        this.poolCache.set(key, exists);
        return exists;
    }

    async getBestQuote(amountIn, tokenInKey, tokenOutKey) {
        let bestOut = 0n;
        const tIn = TOKENS[tokenInKey].address;
        const tOut = TOKENS[tokenOutKey].address;

        // Check V2
        if (await this.poolExists(tIn, tOut, 0)) {
            try {
                const router = await hre.ethers.getContractAt(["function getAmountsOut(uint,address[]) view returns (uint[])"], ROUTERS.UNISWAP_V2.address);
                const amounts = await router.getAmountsOut(amountIn, [tIn, tOut]);
                if (amounts[1] > bestOut) bestOut = amounts[1];
            } catch (e) {}
        }

        return bestOut;
    }

    async findTriangularArbitrage(flashAmount, startKey, intermediateKey, bridgeKey) {
        console.log(`\n--- Testing Triangle: ${startKey} -> ${intermediateKey} -> ${bridgeKey} -> ${startKey} ---`);
        
        // Step 1: USDC -> WETH
        const amount1 = await this.getBestQuote(flashAmount, startKey, intermediateKey);
        if (amount1 === 0n) return null;
        console.log(`   Step 1: ${this.format(flashAmount, startKey)} ${startKey} -> ${this.format(amount1, intermediateKey)} ${intermediateKey}`);

        // Step 2: WETH -> USDT
        const amount2 = await this.getBestQuote(amount1, intermediateKey, bridgeKey);
        if (amount2 === 0n) return null;
        console.log(`   Step 2: ${this.format(amount1, intermediateKey)} ${intermediateKey} -> ${this.format(amount2, bridgeKey)} ${bridgeKey}`);

        // Step 3: USDT -> USDC
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
    const finder = new ArbitrageFinder();
    await finder.initialize();

    const flashAmount = 10n * 10n**6n; // $10 USDC
    const results = [];
    const keys = Object.keys(TOKENS);

    console.log("🔍 Initializing Arbitrage Scan...");
    console.log("\n🚀 Starting Full Triangle Scan (Starting from USDC)...");

    // 1. FIXED MANUAL TEST
    // The function expects (amount, startKey, intermediateKey, bridgeKey)
    const res = await finder.findTriangularArbitrage(flashAmount, 'USDC', 'WETH', 'USDT');
    if (res && parseFloat(res.profit) > 0) results.push(res);

    for (let j = 0; j < keys.length; j++) { // Intermediate Token
        for (let k = 0; k < keys.length; k++) { // Bridge Token
            
            const start = 'USDC'; // We lock the start to USDC
            const inter = keys[j];
            const bridge = keys[k];

            // 2. Logic Check: Skip if any tokens in the triangle are the same
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
        console.log("❌ No profitable triangles found on Sepolia.");
        console.log("Tip: Testnets rarely have enough liquidity for 3-hop profit.");
    }
    console.log("=".repeat(50));
}

main().catch(console.error);