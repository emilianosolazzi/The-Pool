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
import {DynamicFeeHookV2, ReservePricingMode} from "../src/DynamicFeeHookV2.sol";
import {FeeDistributor} from "../src/FeeDistributor.sol";

interface IWETH9Audit { function deposit() external payable; }

contract SwapHelperAudit is IUnlockCallback {
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

contract TestExhaustAndAMM is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function _OK(string memory tag, bool cond) internal pure {
        if (cond) console2.log(string.concat("  [OK]   ", tag));
        else { console2.log(string.concat("  [FAIL] ", tag)); revert(tag); }
    }

    function run() external {
        address poolMgr = vm.envAddress("POOL_MANAGER");
        address weth    = vm.envAddress("TOKEN0");
        address usdc    = vm.envAddress("TOKEN1");
        address hookA   = vm.envAddress("HOOK_ADDR");
        address vaultA  = vm.envAddress("VAULT_ADDR");
        address distA   = vm.envAddress("DIST_ADDR");
        address treas   = vm.envAddress("TREASURY");
        uint24  poolFee = uint24(vm.envUint("POOL_FEE"));
        int24   spacing = int24(vm.envInt("TICK_SPACING"));

        IPoolManager pm = IPoolManager(poolMgr);
        LiquidityVaultV2 vault = LiquidityVaultV2(payable(vaultA));
        DynamicFeeHookV2 hook = DynamicFeeHookV2(hookA);
        FeeDistributor dist = FeeDistributor(distA);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(weth),
            currency1: Currency.wrap(usdc),
            fee: poolFee,
            tickSpacing: spacing,
            hooks: IHooks(hookA)
        });
        PoolId pid = key.toId();

        // ============================================================
        // PART (a): EXHAUSTING SWAP — RESERVE 100% + AMM RESIDUAL
        // ============================================================
        console2.log("\n========== PART (a): EXHAUST + AMM RESIDUAL ==========");

        (uint160 sqrtP0,,,) = pm.getSlot0(pid);
        console2.log("pool sqrtPriceX96 pre :", sqrtP0);
        uint128 sellAmt = 50_000_000; // 50 USDC

        // Vault sqrtP slightly > pool (sellingCurrency1 gate: poolSqrtP <= vaultSqrtP).
        uint160 vaultSqrtP = uint160((uint256(sqrtP0) * 10001) / 10000);

        vm.startBroadcast();
        IWETH9Audit(weth).deposit{value: 0.5 ether}();
        vault.offerReserveToHook(Currency.wrap(usdc), sellAmt, vaultSqrtP, uint64(0));
        SwapHelperAudit helper = new SwapHelperAudit(pm);
        IERC20(weth).approve(address(helper), type(uint256).max);
        vm.stopBroadcast();

        // Snapshot fee/dist counters BEFORE swap
        uint256 feesPre   = hook.totalFeesRouted();
        uint256 failedPre = hook.failedDistribution(usdc);
        uint256 toLpPre   = dist.totalToLPs();
        uint256 toTrPre   = dist.totalToTreasury();
        uint256 distCntPre = dist.distributionCount();
        uint256 treasUsdcPre = IERC20(usdc).balanceOf(treas);

        // takeCap analytical estimate (logging only)
        uint256 sp = uint256(vaultSqrtP);
        uint256 t1 = (sellAmt * (1 << 96)) / sp;
        uint256 takeCap = (t1 * (1 << 96)) / sp;
        console2.log("analytical takeCap (WETH wei):", takeCap);

        // Swap 0.05 WETH (well above takeCap so AMM residual is forced).
        uint160 minLimit = 4295128740; // TickMath.MIN_SQRT_PRICE + 1

        uint256 sUsdcBefore = IERC20(usdc).balanceOf(msg.sender);
        uint256 sWethBefore = IERC20(weth).balanceOf(msg.sender);

        vm.startBroadcast();
        helper.doSwap(key, true, -int256(0.05 ether), minLimit);
        vm.stopBroadcast();

        uint256 sUsdcAfter = IERC20(usdc).balanceOf(msg.sender);
        uint256 sWethAfter = IERC20(weth).balanceOf(msg.sender);
        (uint160 sqrtP1,,,) = pm.getSlot0(pid);

        DynamicFeeHookV2.ReserveOffer memory o = hook.getOffer(key);
        uint256 proceedsWeth = hook.proceedsOwed(vaultA, Currency.wrap(weth));

        console2.log("\n-- swap result --");
        console2.log("WETH paid by swapper :", sWethBefore - sWethAfter);
        console2.log("USDC recv by swapper :", sUsdcAfter - sUsdcBefore);
        console2.log("offer.sellRemaining  :", o.sellRemaining);
        console2.log("offer.active         :", o.active);
        console2.log("proceedsOwed[WETH]   :", proceedsWeth);
        console2.log("pool sqrtPriceX96 post:", sqrtP1);

        uint256 feesPost   = hook.totalFeesRouted();
        uint256 failedPost = hook.failedDistribution(usdc);
        uint256 toLpPost   = dist.totalToLPs();
        uint256 toTrPost   = dist.totalToTreasury();
        uint256 distCntPost = dist.distributionCount();
        uint256 treasUsdcPost = IERC20(usdc).balanceOf(treas);

        console2.log("\n-- fee accounting --");
        console2.log("hook.totalFeesRouted delta :", feesPost - feesPre);
        console2.log("dist.totalToLPs      delta :", toLpPost - toLpPre);
        console2.log("dist.totalToTreasury delta :", toTrPost - toTrPre);
        console2.log("dist.distributionCount delta :", distCntPost - distCntPre);
        console2.log("treasury USDC balance delta :", treasUsdcPost - treasUsdcPre);
        console2.log("hook.failedDistribution[USDC]:", failedPost);

        // ---- Assertions ----
        console2.log("\n-- assertions --");
        _OK("reserve sellRemaining == 0", o.sellRemaining == 0);
        _OK("reserve offer.active == false", !o.active);
        _OK("proceedsOwed[WETH] == takeCap (full inventory consumed)", proceedsWeth == takeCap);
        _OK("pool sqrtPriceX96 moved DOWN (zeroForOne)", sqrtP1 < sqrtP0);
        _OK("hook.totalFeesRouted incremented", feesPost > feesPre);
        _OK("dist.distributionCount incremented", distCntPost == distCntPre + 1);
        _OK("dist.totalToLPs incremented (donate)", toLpPost > toLpPre);
        _OK("dist.totalToTreasury incremented", toTrPost > toTrPre);
        _OK("treasury USDC balance increased", treasUsdcPost > treasUsdcPre);
        _OK("dist 20/80 split: treasury == 20% of fee", (toTrPost - toTrPre) == ((feesPost - feesPre) * 20) / 100);
        _OK("dist 20/80 split: LP == 80% of fee",       (toLpPost - toLpPre) == (feesPost - feesPre) - ((feesPost - feesPre) * 20) / 100);
        _OK("treasury delta >= dist.totalToTreasury delta (swapper==treasury here)", (treasUsdcPost - treasUsdcPre) >= (toTrPost - toTrPre));
        _OK("no failedDistribution incrementation", failedPost == failedPre);

        // Sanity: WETH paid by swapper should be takeCap + AMM residual <= 0.05e18
        uint256 wethPaid = sWethBefore - sWethAfter;
        _OK("swapper WETH paid >= takeCap (reserve part)", wethPaid >= takeCap);
        _OK("swapper WETH paid <= 0.05e18 (full input)",  wethPaid <= 0.05 ether);
        // unspecified delta seen by afterSwap = AMM USDC out only.
        // fee = unspec * 25 bps. Reverse-engineer expected:
        //   USDC recv by swapper = 50 USDC (reserve) + (USDC out of AMM) - hook fee taken from PM
        // We can't recover unspec directly, but feesPost-feesPre is in USDC (currency1).
        // It must be > 0 and ~0.25% of (USDC recv by swapper - 50e6 + fee).
        // Reverse-engineer AMM gross USDC out: swapper got = ammNet + reserveFill + distTreasuryShare
        //                                       ammNet = ammGross - fee
        // -> ammGross = (recv - 50e6 - distTreasuryShare) + fee
        uint256 fee = feesPost - feesPre;
        uint256 ammUsdcGross = (sUsdcAfter - sUsdcBefore) - 50_000_000 - (toTrPost - toTrPre) + fee;
        uint256 expectedFee = (ammUsdcGross * 25) / 10000;
        _OK("hook fee == 25 bps of AMM USDC out (within 1 wei rounding)",
            fee == expectedFee || fee == expectedFee - 1 || fee == expectedFee + 1);

        console2.log("\nPART (a): all assertions OK");
    }
}

contract TestCancelAndRebalance is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function _OK(string memory tag, bool cond) internal pure {
        if (cond) console2.log(string.concat("  [OK]   ", tag));
        else { console2.log(string.concat("  [FAIL] ", tag)); revert(tag); }
    }

    function run() external {
        address poolMgr = vm.envAddress("POOL_MANAGER");
        address weth    = vm.envAddress("TOKEN0");
        address usdc    = vm.envAddress("TOKEN1");
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

        // ============================================================
        // PART (b1): FULL CANCEL — escrow returns exactly
        // ============================================================
        console2.log("\n========== PART (b1): FULL CANCEL ==========");
        // Note: prior PART(a) ran already, so vault USDC may be < 100. Whatever it is, snapshot.
        uint256 vaultUsdcBefore = IERC20(usdc).balanceOf(vaultA);
        require(vaultUsdcBefore >= 30_000_000, "need >=30 USDC in vault for b1");
        console2.log("vault USDC before offer:", vaultUsdcBefore);

        (uint160 sqrtP,,,) = pm.getSlot0(pid);
        uint160 vaultSqrtP = uint160((uint256(sqrtP) * 10001) / 10000);

        vm.startBroadcast();
        vault.offerReserveToHook(Currency.wrap(usdc), 30_000_000, vaultSqrtP, uint64(0));
        vm.stopBroadcast();

        _OK("offer active after post", hook.offerActive(key));
        _OK("vault USDC -= 30e6", IERC20(usdc).balanceOf(vaultA) == vaultUsdcBefore - 30_000_000);

        vm.startBroadcast();
        uint128 returnedB1 = vault.cancelReserveOffer(Currency.wrap(usdc));
        vm.stopBroadcast();

        _OK("cancel returned == 30e6 (full)", returnedB1 == 30_000_000);
        _OK("offer no longer active", !hook.offerActive(key));
        _OK("vault USDC restored exactly", IERC20(usdc).balanceOf(vaultA) == vaultUsdcBefore);

        // ============================================================
        // PART (b2): PARTIAL FILL THEN CANCEL — exact remainder
        // ============================================================
        console2.log("\n========== PART (b2): PARTIAL FILL + CANCEL ==========");
        uint256 vaultUsdcB2 = IERC20(usdc).balanceOf(vaultA);
        uint256 hookWethBefore = IERC20(weth).balanceOf(hookA);

        vm.startBroadcast();
        vault.offerReserveToHook(Currency.wrap(usdc), 30_000_000, vaultSqrtP, uint64(0));
        // Need WETH to pay the swapper. msg.sender already has WETH from PART(a).
        SwapHelperAudit helper = new SwapHelperAudit(pm);
        IERC20(weth).approve(address(helper), type(uint256).max);
        // Wrap a bit more if needed.
        IWETH9Audit(weth).deposit{value: 0.05 ether}();
        // Small swap: 0.005 WETH -> takes ~11.4 USDC at vault price.
        helper.doSwap(key, true, -int256(0.005 ether), 4295128740);
        vm.stopBroadcast();

        DynamicFeeHookV2.ReserveOffer memory o = hook.getOffer(key);
        require(o.sellRemaining > 0 && o.sellRemaining < 30_000_000, "expected partial fill");
        uint128 expectedReturn = o.sellRemaining;
        uint256 wethConsumedReserve = IERC20(weth).balanceOf(hookA) - hookWethBefore;
        // wethConsumedReserve includes the AMM-added WETH paid by swapper that doesn't cross via reserve;
        // but in this case PART(a) had already routed AMM residual through hook? No - AMM WETH
        // goes to PoolManager, not hook. Only reserve-fill input lands at hook.
        // Note: hook also got 25-bp fee in WETH? No — fee currency is unspecified = USDC for zeroForOne.
        console2.log("offer.sellRemaining after partial fill:", o.sellRemaining);
        console2.log("expected reserve consumption (USDC):", uint256(30_000_000) - o.sellRemaining);
        console2.log("hook WETH balance delta (proceeds):", wethConsumedReserve);

        vm.startBroadcast();
        uint128 returnedB2 = vault.cancelReserveOffer(Currency.wrap(usdc));
        vm.stopBroadcast();

        _OK("cancel returned == sellRemaining", returnedB2 == expectedReturn);
        _OK("vault USDC restored exactly minus filled portion",
            IERC20(usdc).balanceOf(vaultA) == vaultUsdcB2 - 30_000_000 + expectedReturn);

        // ============================================================
        // PART (b3): collectReserveProceeds works after partial fill
        // ============================================================
        console2.log("\n========== PART (b3): COLLECT PROCEEDS ==========");
        uint256 vaultWethBefore = IERC20(weth).balanceOf(vaultA);
        uint256 owed = hook.proceedsOwed(vaultA, Currency.wrap(weth));
        console2.log("proceedsOwed[vault][WETH]:", owed);
        require(owed > 0, "expected proceedsOwed > 0 from b2 partial fill");

        vm.startBroadcast();
        uint256 collected = vault.collectReserveProceeds(Currency.wrap(weth));
        vm.stopBroadcast();
        _OK("collected == proceedsOwed", collected == owed);
        _OK("proceedsOwed cleared",     hook.proceedsOwed(vaultA, Currency.wrap(weth)) == 0);
        _OK("vault WETH credited exactly",
            IERC20(weth).balanceOf(vaultA) == vaultWethBefore + owed);

        // ============================================================
        // PART (b4): rebalanceOffer when NO active offer (skips cancel)
        // ============================================================
        console2.log("\n========== PART (b4): REBALANCE WHEN INACTIVE ==========");
        require(!hook.offerActive(key), "offer should be inactive");
        uint256 vaultUsdcB4 = IERC20(usdc).balanceOf(vaultA);

        vm.startBroadcast();
        vault.rebalanceOffer(Currency.wrap(usdc), 25_000_000, vaultSqrtP, uint64(0));
        vm.stopBroadcast();

        DynamicFeeHookV2.ReserveOffer memory oB4 = hook.getOffer(key);
        _OK("rebalance posted new offer", oB4.active);
        _OK("new offer sellRemaining == 25e6", oB4.sellRemaining == 25_000_000);
        _OK("new offer sqrtP set", oB4.vaultSqrtPriceX96 == vaultSqrtP);
        _OK("vault USDC -= 25e6 (no double-cancel/post)",
            IERC20(usdc).balanceOf(vaultA) == vaultUsdcB4 - 25_000_000);

        // ============================================================
        // PART (b5): rebalanceOffer when ACTIVE — cancel then post w/ new price
        // ============================================================
        console2.log("\n========== PART (b5): REBALANCE WHEN ACTIVE ==========");
        require(hook.offerActive(key), "must be active from b4");
        uint256 vaultUsdcB5 = IERC20(usdc).balanceOf(vaultA);
        uint160 newSqrtP = uint160((uint256(sqrtP) * 10005) / 10000); // wider spread

        vm.startBroadcast();
        vault.rebalanceOffer(Currency.wrap(usdc), 20_000_000, newSqrtP, uint64(0));
        vm.stopBroadcast();

        DynamicFeeHookV2.ReserveOffer memory oB5 = hook.getOffer(key);
        _OK("rebalance kept offer active", oB5.active);
        _OK("rebalance new sellRemaining == 20e6", oB5.sellRemaining == 20_000_000);
        _OK("rebalance new sqrtP applied",   oB5.vaultSqrtPriceX96 == newSqrtP);
        // Net USDC effect: cancel returns 25e6, post locks 20e6 -> vault delta = +5e6
        _OK("vault USDC = previous + 25e6 - 20e6 = +5e6",
            IERC20(usdc).balanceOf(vaultA) == vaultUsdcB5 + 5_000_000);

        console2.log("\nPART (b): all assertions OK");
    }
}

// =====================================================================
// PART (c) : VAULT_SPREAD mode end-to-end on the Arbitrum fork.
// Vault sells USDC at a sqrtP BELOW pool spot, so when a swapper does
// zeroForOne (pays WETH for USDC) the gate poolSqrtP >= vaultSqrtP
// passes and the vault earns the spread vs. AMM mid.
// =====================================================================
contract TestVaultSpread is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function _OK(string memory tag, bool cond) internal pure {
        if (cond) console2.log(string.concat("  [OK]   ", tag));
        else { console2.log(string.concat("  [FAIL] ", tag)); revert(tag); }
    }

    function run() external {
        address poolMgr = vm.envAddress("POOL_MANAGER");
        address weth    = vm.envAddress("TOKEN0");
        address usdc    = vm.envAddress("TOKEN1");
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

        console2.log("\n========== PART (c1): VAULT_SPREAD WRONG SIDE SKIPS ==========");
        (uint160 sqrtP0,,,) = pm.getSlot0(pid);
        // Wrong side: vault sqrtP ABOVE pool -> gate poolSqrtP >= vaultSqrtP fails.
        uint160 vaultSqrtPHigh = uint160((uint256(sqrtP0) * 10010) / 10000);
        uint256 vaultUsdcStart = IERC20(usdc).balanceOf(vaultA);
        require(vaultUsdcStart >= 30_000_000, "vault needs >=30 USDC");

        vm.startBroadcast();
        // Clean any prior active offer left by sibling audits.
        DynamicFeeHookV2.ReserveOffer memory _existing = hook.getOffer(key);
        if (_existing.active) vault.cancelReserveOffer(Currency.wrap(usdc));
        vault.offerReserveToHookWithMode(
            Currency.wrap(usdc), 30_000_000, vaultSqrtPHigh, uint64(0), ReservePricingMode.VAULT_SPREAD
        );
        // Wrap a bit of WETH for the swap.
        IWETH9Audit(weth).deposit{value: 0.05 ether}();
        SwapHelperAudit helper = new SwapHelperAudit(pm);
        IERC20(weth).approve(address(helper), type(uint256).max);
        vm.stopBroadcast();

        uint256 fillsBefore = hook.totalReserveFills();
        vm.startBroadcast();
        helper.doSwap(key, true, -int256(0.005 ether), 4295128740);
        vm.stopBroadcast();
        _OK("VAULT_SPREAD wrong side: no fill", hook.totalReserveFills() == fillsBefore);
        DynamicFeeHookV2.ReserveOffer memory oC1 = hook.getOffer(key);
        _OK("offer remained active and untouched", oC1.active && oC1.sellRemaining == 30_000_000);

        // Cancel before next sub-case.
        vm.startBroadcast();
        vault.cancelReserveOffer(Currency.wrap(usdc));
        vm.stopBroadcast();

        console2.log("\n========== PART (c2): VAULT_SPREAD CORRECT SIDE FILLS, NAV UP ==========");
        (uint160 sqrtP1,,,) = pm.getSlot0(pid);
        // Correct side: vault sqrtP BELOW pool -> gate passes for sellingCurrency1.
        uint160 vaultSqrtPLow = uint160((uint256(sqrtP1) * 9990) / 10000);

        // Snapshot NAV (USDC + WETH worth) approximated as raw USDC + WETH balances.
        uint256 vaultUsdcPre = IERC20(usdc).balanceOf(vaultA);
        uint256 vaultWethPre = IERC20(weth).balanceOf(vaultA);
        uint256 distCntPre   = FeeDistributor(vm.envAddress("DIST_ADDR")).distributionCount();

        vm.startBroadcast();
        vault.offerReserveToHookWithMode(
            Currency.wrap(usdc), 30_000_000, vaultSqrtPLow, uint64(0), ReservePricingMode.VAULT_SPREAD
        );
        vm.stopBroadcast();

        DynamicFeeHookV2.ReserveOffer memory oC2 = hook.getOffer(key);
        _OK("offer posted with VAULT_SPREAD mode",
            oC2.active && uint8(oC2.pricingMode) == uint8(ReservePricingMode.VAULT_SPREAD));

        // Swap that exhausts the offer and forces AMM residual (forces fee path).
        uint256 escrowBefore   = hook.escrowedReserve(vaultA, Currency.wrap(usdc));
        uint256 proceedsBefore = hook.proceedsOwed(vaultA, Currency.wrap(weth));

        vm.startBroadcast();
        helper.doSwap(key, true, -int256(0.05 ether), 4295128740);
        vm.stopBroadcast();

        DynamicFeeHookV2.ReserveOffer memory oC2post = hook.getOffer(key);
        uint256 escrowAfter   = hook.escrowedReserve(vaultA, Currency.wrap(usdc));
        uint256 proceedsAfter = hook.proceedsOwed(vaultA, Currency.wrap(weth));
        uint256 distCntPost   = FeeDistributor(vm.envAddress("DIST_ADDR")).distributionCount();

        uint256 usdcGiven  = escrowBefore - escrowAfter;
        uint256 wethTaken  = proceedsAfter - proceedsBefore;
        console2.log("USDC given by vault :", usdcGiven);
        console2.log("WETH taken by vault :", wethTaken);

        _OK("offer fully consumed",                    !oC2post.active && oC2post.sellRemaining == 0);
        _OK("vault inventory drained",                  usdcGiven == 30_000_000);
        _OK("vault accrued WETH proceeds",              wethTaken > 0);
        // Spread proof: proceeds@vaultSqrtP > proceeds@poolSqrtP (i.e. vault took
        // strictly more WETH than the AMM mid would have given for the same USDC).
        // takeCap_pool = 30e6 * 2^192 / poolSqrtP^2 ; takeCap_vault = 30e6 * 2^192 / vaultSqrtP^2.
        // Since vaultSqrtP < poolSqrtP, takeCap_vault > takeCap_pool.
        uint256 spP = uint256(sqrtP1);
        uint256 vp  = uint256(vaultSqrtPLow);
        uint256 capPool  = (((30_000_000 * (uint256(1) << 96)) / spP) * (uint256(1) << 96)) / spP;
        uint256 capVault = (((30_000_000 * (uint256(1) << 96)) / vp ) * (uint256(1) << 96)) / vp;
        console2.log("AMM-mid notional WETH for 30e6 USDC :", capPool);
        console2.log("Vault-quoted WETH for 30e6 USDC     :", capVault);
        _OK("vault took == its quoted takeCap (full inventory)", wethTaken == capVault);
        _OK("vault took strictly MORE than AMM-mid notional",     wethTaken > capPool);

        // AMM residual happened => fee path triggered, distributor count incremented.
        _OK("distributor incremented (AMM residual produced fee)", distCntPost == distCntPre + 1);

        // Collect proceeds and confirm NAV grew by `wethTaken`.
        vm.startBroadcast();
        uint256 collected = vault.collectReserveProceeds(Currency.wrap(weth));
        vm.stopBroadcast();
        _OK("collected == proceeds owed", collected == wethTaken);
        // NAV change: vault USDC dropped by 30e6 (escrowed), now collects WETH worth `wethTaken`.
        // Convert wethTaken to USDC at AMM-mid (poolSqrtP^2 / 2^192) and check it exceeds 30e6.
        // wethToUsdcAtPool = wethTaken * sqrtP^2 / 2^192
        uint256 m = (wethTaken * spP) / (uint256(1) << 96);
        uint256 wethTakenInUsdc = (m * spP) / (uint256(1) << 96);
        console2.log("WETH-taken priced at AMM-mid (USDC) :", wethTakenInUsdc);
        _OK("WETH proceeds @ AMM-mid > 30e6 USDC sold (NAV up)", wethTakenInUsdc > 30_000_000);

        uint256 vaultUsdcPost = IERC20(usdc).balanceOf(vaultA);
        uint256 vaultWethPost = IERC20(weth).balanceOf(vaultA);
        _OK("vault USDC delta == -30e6 (sold)", vaultUsdcPost == vaultUsdcPre - 30_000_000);
        _OK("vault WETH delta == +collected",   vaultWethPost == vaultWethPre + collected);

        console2.log("\nPART (c): all assertions OK");
    }
}