// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LiquidityVaultV2} from "../src/LiquidityVaultV2.sol";
import {DynamicFeeHookV2} from "../src/DynamicFeeHookV2.sol";

interface IWETH9 {
    function deposit() external payable;
}

contract SwapHelperLocal is IUnlockCallback {
    IPoolManager public immutable poolManager;
    constructor(IPoolManager _pm) { poolManager = _pm; }

    function doSwap(PoolKey calldata key, bool zeroForOne, int256 amt, uint160 limit) external {
        poolManager.unlock(abi.encode(msg.sender, key, zeroForOne, amt, limit));
    }

    function unlockCallback(bytes calldata raw) external override returns (bytes memory) {
        require(msg.sender == address(poolManager), "NOT_PM");
        (address caller, PoolKey memory key, bool z40, int256 amt, uint160 lim) =
            abi.decode(raw, (address, PoolKey, bool, int256, uint160));
        BalanceDelta d = poolManager.swap(key, SwapParams(z40, amt, lim), "");
        int128 d0 = d.amount0(); int128 d1 = d.amount1();
        if (d0 < 0) { uint256 owed = uint256(uint128(-d0)); poolManager.sync(key.currency0); IERC20(Currency.unwrap(key.currency0)).transferFrom(caller, address(poolManager), owed); poolManager.settle(); }
        if (d1 < 0) { uint256 owed = uint256(uint128(-d1)); poolManager.sync(key.currency1); IERC20(Currency.unwrap(key.currency1)).transferFrom(caller, address(poolManager), owed); poolManager.settle(); }
        if (d0 > 0) poolManager.take(key.currency0, caller, uint256(uint128(d0)));
        if (d1 > 0) poolManager.take(key.currency1, caller, uint256(uint128(d1)));
        return "";
    }
}

contract TestReserveSwap is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function _humanUsdc(uint256 raw) internal pure returns (string memory) {
        // 6 decimals
        return string.concat(_dec(raw / 1e6), ".", _pad6(raw % 1e6));
    }
    function _humanWeth(uint256 raw) internal pure returns (string memory) {
        return string.concat(_dec(raw / 1e18), ".", _pad18(raw % 1e18));
    }
    function _dec(uint256 v) internal pure returns (string memory) { return vm.toString(v); }
    function _pad6(uint256 v) internal pure returns (string memory) {
        bytes memory s = bytes(vm.toString(v));
        if (s.length >= 6) return string(s);
        bytes memory out = new bytes(6);
        uint256 pad = 6 - s.length;
        for (uint256 i; i < pad; ++i) out[i] = "0";
        for (uint256 i; i < s.length; ++i) out[pad + i] = s[i];
        return string(out);
    }
    function _pad18(uint256 v) internal pure returns (string memory) {
        bytes memory s = bytes(vm.toString(v));
        if (s.length >= 18) return string(s);
        bytes memory out = new bytes(18);
        uint256 pad = 18 - s.length;
        for (uint256 i; i < pad; ++i) out[i] = "0";
        for (uint256 i; i < s.length; ++i) out[pad + i] = s[i];
        return string(out);
    }

    function run() external {
        address poolMgr = vm.envAddress("POOL_MANAGER");
        address weth    = vm.envAddress("TOKEN0");          // currency0
        address usdc    = vm.envAddress("TOKEN1");          // currency1
        address hookA   = vm.envAddress("HOOK_ADDR");
        address vaultA  = vm.envAddress("VAULT_ADDR");
        uint24  poolFee = uint24(vm.envUint("POOL_FEE"));
        int24   spacing = int24(vm.envInt("TICK_SPACING"));

        IPoolManager pm = IPoolManager(poolMgr);
        LiquidityVaultV2 vault = LiquidityVaultV2(payable(vaultA));
        DynamicFeeHookV2 hook = DynamicFeeHookV2(hookA);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(weth),
            currency1: Currency.wrap(usdc),
            fee: poolFee,
            tickSpacing: spacing,
            hooks: IHooks(hookA)
        });
        PoolId pid = key.toId();

        // ---------- STAGE 0: read live pool state ----------
        (uint160 sqrtP0,,, ) = pm.getSlot0(pid);
        console2.log("\n==== STAGE 0: live pool state ====");
        console2.log("poolManager sqrtPriceX96:", sqrtP0);
        // Approx: human price USDC/WETH = (sqrtP^2 / 2^192) * 1e12.
        // Compute integer: usdcPerWethE6 = sqrtP^2 / 2^192 * 1e18 / 1e6 = sqrtP^2 * 1e12 >> 192
        uint256 px = uint256(sqrtP0);
        uint256 priceE12 = (px * px) >> 96;
        priceE12 = (priceE12 * 1e12) >> 96;
        console2.log("approx USDC per WETH (raw, 1e6 scale):", priceE12);

        console2.log("\n==== STAGE 1: vault state pre-offer ====");
        uint256 vUsdc = IERC20(usdc).balanceOf(vaultA);
        uint256 vWeth = IERC20(weth).balanceOf(vaultA);
        (uint256 tvl, uint256 sharePrice,,,, ) = vault.getVaultStats();
        console2.log("vault USDC balance:", vUsdc);
        console2.log("vault WETH balance:", vWeth);
        console2.log("totalAssets() (USDC):", tvl);
        console2.log("totalSupply() (shares):", vault.totalSupply());
        console2.log("getVaultStats.sharePrice (1e18):", sharePrice);

        // ---------- STAGE 2: post reserve offer ----------
        // Vault sells 50 USDC at a sqrtPrice ~1bp WORSE for vault (= better for swapper).
        // gate (sellingCurrency1): poolSqrtP <= vaultSqrtP -> set vaultSqrtP just above pool.
        uint160 vaultSqrtP = uint160((uint256(sqrtP0) * 10001) / 10000);
        uint128 sellAmt = 50_000_000; // 50 USDC

        vm.startBroadcast();

        // Wrap 0.05 ETH -> WETH on the deployer (so we have token0 to swap with).
        IWETH9(weth).deposit{value: 0.05 ether}();

        // Owner posts the offer.
        vault.offerReserveToHook(Currency.wrap(usdc), sellAmt, vaultSqrtP, uint64(0));

        // Deploy local SwapHelper.
        SwapHelperLocal helper = new SwapHelperLocal(pm);

        // Approve helper to pull WETH (we are paying token0).
        IERC20(weth).approve(address(helper), type(uint256).max);

        vm.stopBroadcast();

        console2.log("\n==== STAGE 2: reserve offer posted ====");
        console2.log("vaultSqrtPriceX96:", vaultSqrtP);
        console2.log("sellAmount (USDC):", sellAmt);
        DynamicFeeHookV2.ReserveOffer memory o = hook.getOffer(key);
        console2.log("offer.active:", o.active);
        console2.log("offer.sellRemaining:", o.sellRemaining);
        console2.log("hook USDC escrow balance:", IERC20(usdc).balanceOf(hookA));
        console2.log("vault USDC after escrow:", IERC20(usdc).balanceOf(vaultA));

        // ---------- STAGE 3: swap WETH -> USDC through hook ----------
        // exact-in 0.01 WETH; expect ~22.9 USDC out from vault offer at ~$2289/ETH.
        // sqrtPriceLimitX96 for zeroForOne goes DOWN -> use MIN+1.
        uint160 minLimit = 4295128740; // TickMath.MIN_SQRT_PRICE + 1

        uint256 sUsdcBefore = IERC20(usdc).balanceOf(msg.sender);
        uint256 sWethBefore = IERC20(weth).balanceOf(msg.sender);

        vm.startBroadcast();
        helper.doSwap(key, true, -int256(0.01 ether), minLimit);
        vm.stopBroadcast();

        uint256 sUsdcAfter = IERC20(usdc).balanceOf(msg.sender);
        uint256 sWethAfter = IERC20(weth).balanceOf(msg.sender);

        console2.log("\n==== STAGE 3: swap executed ====");
        console2.log("swapper WETH paid:", sWethBefore - sWethAfter);
        console2.log("swapper USDC received:", sUsdcAfter - sUsdcBefore);
        console2.log("hook totalSwaps:", hook.totalSwaps());

        DynamicFeeHookV2.ReserveOffer memory o2 = hook.getOffer(key);
        console2.log("offer.sellRemaining (USDC):", o2.sellRemaining);
        console2.log("hook USDC escrow balance:", IERC20(usdc).balanceOf(hookA));
        console2.log("hook WETH balance (proceeds + escrow):", IERC20(weth).balanceOf(hookA));
        console2.log("vault->WETH proceedsOwed (raw):",
            hook.proceedsOwed(vaultA, Currency.wrap(weth)));

        (uint160 sqrtP1,,, ) = pm.getSlot0(pid);
        console2.log("poolManager sqrtPriceX96 after:", sqrtP1);
        console2.log("pool price moved? ", sqrtP0 != sqrtP1);

        // ---------- STAGE 4: vault collects WETH proceeds ----------
        vm.startBroadcast();
        uint256 collected = vault.collectReserveProceeds(Currency.wrap(weth));
        vm.stopBroadcast();

        console2.log("\n==== STAGE 4: vault collected proceeds ====");
        console2.log("vault.collectReserveProceeds returned:", collected);
        console2.log("vault USDC balance:", IERC20(usdc).balanceOf(vaultA));
        console2.log("vault WETH balance:", IERC20(weth).balanceOf(vaultA));

        // ---------- STAGE 5: NAV + share-price after ----------
        (uint256 tvl2, uint256 sp2,,, uint256 yc, ) = vault.getVaultStats();
        console2.log("\n==== STAGE 5: vault NAV & share price ====");
        console2.log("totalAssets() (USDC):", tvl2);
        console2.log("getVaultStats.sharePrice (1e18):", sp2);
        console2.log("totalYieldCollected:", yc);
        console2.log("totalSupply (shares):", vault.totalSupply());
        console2.log("delta totalAssets (post - pre):", int256(tvl2) - int256(tvl));
        console2.log("delta sharePrice  (post - pre):", int256(sp2) - int256(sharePrice));
    }
}
