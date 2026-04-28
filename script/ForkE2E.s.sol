// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

interface IVault {
    function asset() external view returns (address);
    function owner() external view returns (address);
    function deposit(uint256 assets, address receiver) external returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function totalAssets() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function totalDepositors() external view returns (uint256);
    function totalLiquidityDeployed() external view returns (uint256);
    function assetsDeployed() external view returns (uint256);
    function totalYieldCollected() external view returns (uint256);
    function poolKey() external view returns (
        Currency currency0,
        Currency currency1,
        uint24 fee,
        int24 tickSpacing,
        IHooks hooks
    );
    function offerReserveToHookWithMode(
        Currency sellCurrency,
        uint128 sellAmount,
        uint160 vaultSqrtPriceX96,
        uint64 expiry,
        uint8 mode
    ) external;
    function collectReserveProceeds(Currency currency) external returns (uint256);
}

interface IVaultLens {
    function getVaultStats(address vault) external view returns (
        uint256 tvl,
        uint256 sharePrice,
        uint256 depositors,
        uint256 liqDeployed,
        uint256 yieldColl,
        string memory feeDesc
    );
    function vaultStatus(address vault) external view returns (uint8);
}

interface IHook {
    function totalSwaps() external view returns (uint256);
    function totalFeesRouted() external view returns (uint256);
    function totalReserveFills() external view returns (uint256);
    function totalReserveSold() external view returns (uint256);
    function proceedsOwed(address vault, Currency currency) external view returns (uint256);
}

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
    function allowance(address owner, address token, address spender)
        external view returns (uint160 amount, uint48 expiration, uint48 nonce);
}

interface IV4Quoter {
    struct PoolKeyView {
        Currency currency0;
        Currency currency1;
        uint24 fee;
        int24 tickSpacing;
        IHooks hooks;
    }
    struct QuoteExactSingleParams {
        PoolKeyView poolKey;
        bool zeroForOne;
        uint128 exactAmount;
        bytes hookData;
    }
    function quoteExactInputSingle(QuoteExactSingleParams memory params)
        external returns (uint256 amountOut, uint256 gasEstimate);
}

/// @title ForkE2E
/// @notice End-to-end smoke test against an Arbitrum One fork at latest block.
///         Steps 1-10 from the user spec. Runs in ONE forge script invocation
///         with broadcast switching: depositor (test wallet PK) for deposits
///         and UR swaps; impersonated Ledger (vault owner) for the reserve
///         offer post.
///
/// Required env:
///   FORK_DEPOSITOR        EOA used as test wallet (anvil PK #0)
///   FORK_DEPOSITOR_PK     uint256 form of the test wallet PK (for vm.envUint)
///   VAULT_OWNER           Ledger (vault.owner()) - must be unlocked on anvil
///   VAULT, LENS, HOOK     V2.1 deployments
///   POOL_MANAGER, V4_QUOTER, UNIVERSAL_ROUTER, PERMIT2
///   USDC, WETH, POOL_FEE, TICK_SPACING
contract ForkE2E is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // Pre-loaded env (set in run()).
    address depositor;
    uint256 depositorPk;
    address ledgerOwner;

    address vaultAddr;
    address lensAddr;
    address hookAddr;
    address poolMgrAddr;
    address quoterAddr;
    address routerAddr;
    address permit2Addr;
    address usdcAddr;
    address wethAddr;
    uint24  poolFee;
    int24   tickSpacing;

    // UR opcodes (Arbitrum mainnet UR).
    uint8 constant CMD_V4_SWAP            = 0x10;
    uint8 constant ACT_SWAP_EXACT_IN_SINGLE = 0x06;
    uint8 constant ACT_SETTLE_ALL         = 0x0c;
    uint8 constant ACT_TAKE_ALL           = 0x0f;

    function run() external {
        depositor    = vm.envAddress("FORK_DEPOSITOR");
        depositorPk  = vm.envUint("FORK_DEPOSITOR_PK");
        ledgerOwner  = vm.envAddress("VAULT_OWNER");
        vaultAddr    = vm.envAddress("VAULT");
        lensAddr     = vm.envAddress("LENS");
        hookAddr     = vm.envAddress("HOOK");
        poolMgrAddr  = vm.envAddress("POOL_MANAGER");
        quoterAddr   = vm.envAddress("V4_QUOTER");
        routerAddr   = vm.envAddress("UNIVERSAL_ROUTER");
        permit2Addr  = vm.envAddress("PERMIT2");
        usdcAddr     = vm.envAddress("USDC");
        wethAddr     = vm.envAddress("WETH");
        poolFee      = uint24(vm.envUint("POOL_FEE"));
        tickSpacing  = int24(vm.envInt("TICK_SPACING"));

        PoolKey memory key = _poolKey();

        console2.log("\n============================================================");
        console2.log("ForkE2E - Arbitrum One fork");
        console2.log("============================================================");
        console2.log("depositor :", depositor);
        console2.log("vault     :", vaultAddr);
        console2.log("lens      :", lensAddr);
        console2.log("hook      :", hookAddr);

        // ---- snapshot pre-state -------------------------------------------
        Snap memory pre = _snap();

        // The live mainnet vault has never been seeded with WETH, so a pure
        // USDC deposit cannot mint v4 liquidity (in-range positions need both
        // tokens). Pre-seed by wrapping ETH from the depositor and dropping
        // the WETH directly on the vault BEFORE the deposit call. This makes
        // the deposit-triggered _deployBalancedLiquidity actually fire.
        _seedVaultWithWETH(0.1 ether);

        // ===== STEPS 2-4: deposit 500 USDC =================================
        _depositPhase();

        Snap memory post1 = _snap();
        _assertLensProgress(pre, post1);

        // ===== STEP 5: assert totalLiquidityDeployed/assetsDeployed grew ====
        require(post1.totalLiquidityDeployed > pre.totalLiquidityDeployed,
                "totalLiquidityDeployed did not grow after deposit");
        require(post1.assetsDeployed > pre.assetsDeployed,
                "assetsDeployed did not grow after deposit");
        console2.log("\n[STEP 5] vault redeployed liquidity OK");
        console2.log("  totalLiquidityDeployed:", post1.totalLiquidityDeployed);
        console2.log("  assetsDeployed       :", post1.assetsDeployed);

        // ===== STEPS 6-7: V4Quoter + UR USDC->WETH =========================
        uint256 wethRecvd = _quoteAndSwapUSDCtoWETH(key, 50_000_000); // 50 USDC

        // ===== STEP 8: hook stats updated ==================================
        Snap memory post2 = _snap();
        require(post2.totalSwaps == pre.totalSwaps + 1,
                "hook.totalSwaps did not bump by 1");
        require(post2.totalFeesRouted >= pre.totalFeesRouted,
                "hook.totalFeesRouted regressed");
        console2.log("\n[STEP 8] hook stats moved OK");
        console2.log("  totalSwaps       :", pre.totalSwaps, "->", post2.totalSwaps);
        console2.log("  totalFeesRouted  :", pre.totalFeesRouted, "->", post2.totalFeesRouted);
        require(wethRecvd > 0, "no WETH received");

        // The deposit-time _deployBalancedLiquidity drains the vault's idle
        // USDC into the LP position, so we top up a small idle balance for
        // the reserve offer to escrow against. Same idea as collected yield
        // accumulating between rebalances.
        _topUpVaultUSDC(50_000_000); // 50 USDC idle on vault

        // ===== STEP 9: post VAULT_SPREAD reserve offer (impersonated Ledger)
        _postVaultSpreadOffer(key, 25_000_000, 25); // 25 USDC at +25 bps

        // ===== STEP 10: WETH -> USDC consumes the reserve ==================
        _swapWETHtoUSDC(key, uint128(wethRecvd));

        Snap memory post3 = _snap();
        require(post3.totalReserveFills > post2.totalReserveFills,
                "reserve fill did not register");
        console2.log("\n[STEP 10] reserve filled OK");
        console2.log("  totalReserveFills:", post2.totalReserveFills, "->", post3.totalReserveFills);
        console2.log("  totalReserveSold :", post2.totalReserveSold, "->", post3.totalReserveSold);
        console2.log("  proceedsOwed[WETH]:", post3.proceedsOwedWeth);

        // Collect proceeds back to vault.
        if (post3.proceedsOwedWeth > 0) {
            vm.startBroadcast(depositorPk);
            // collectReserveProceeds is permissionless on V2 - anyone can pull.
            // (See LiquidityVaultV2: nonReentrant only.)
            uint256 collected = IVault(vaultAddr).collectReserveProceeds(Currency.wrap(wethAddr));
            vm.stopBroadcast();
            console2.log("  vault.collectReserveProceeds returned:", collected);
        }

        console2.log("\nForkE2E PASSED.");
    }

    // ----------------------------------------------------------------------
    // Internal helpers
    // ----------------------------------------------------------------------

    struct Snap {
        uint256 tvl;
        uint256 sharePrice;
        uint256 depositors;
        uint256 lensLiqDeployed;
        uint256 totalLiquidityDeployed;
        uint256 assetsDeployed;
        uint256 totalSwaps;
        uint256 totalFeesRouted;
        uint256 totalReserveFills;
        uint256 totalReserveSold;
        uint256 proceedsOwedWeth;
        uint8   vaultStatus;
        uint256 depositorUsdc;
        uint256 depositorWeth;
        uint256 depositorShares;
    }

    function _snap() internal returns (Snap memory s) {
        (s.tvl, s.sharePrice, s.depositors, s.lensLiqDeployed,,) =
            IVaultLens(lensAddr).getVaultStats(vaultAddr);
        s.totalLiquidityDeployed = IVault(vaultAddr).totalLiquidityDeployed();
        s.assetsDeployed         = IVault(vaultAddr).assetsDeployed();
        s.totalSwaps             = IHook(hookAddr).totalSwaps();
        s.totalFeesRouted        = IHook(hookAddr).totalFeesRouted();
        s.totalReserveFills      = IHook(hookAddr).totalReserveFills();
        s.totalReserveSold       = IHook(hookAddr).totalReserveSold();
        s.proceedsOwedWeth       = IHook(hookAddr).proceedsOwed(vaultAddr, Currency.wrap(wethAddr));
        s.vaultStatus            = IVaultLens(lensAddr).vaultStatus(vaultAddr);
        s.depositorUsdc          = IERC20(usdcAddr).balanceOf(depositor);
        s.depositorWeth          = IERC20(wethAddr).balanceOf(depositor);
        s.depositorShares        = IVault(vaultAddr).balanceOf(depositor);
    }

    function _poolKey() internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(wethAddr),
            currency1: Currency.wrap(usdcAddr),
            fee: poolFee,
            tickSpacing: tickSpacing,
            hooks: IHooks(hookAddr)
        });
    }

    function _topUpVaultUSDC(uint256 amount) internal {
        console2.log("\n[topup] transfer", amount, "USDC to vault for reserve escrow");
        vm.startBroadcast(depositorPk);
        IERC20(usdcAddr).transfer(vaultAddr, amount);
        vm.stopBroadcast();
        console2.log("  vault USDC bal:", IERC20(usdcAddr).balanceOf(vaultAddr));
    }

    function _seedVaultWithWETH(uint256 ethAmount) internal {
        console2.log("\n[seed] wrap", ethAmount, "ETH and transfer WETH to vault");
        vm.startBroadcast(depositorPk);
        // WETH.deposit() — no ABI import; raw call.
        (bool ok,) = wethAddr.call{value: ethAmount}(abi.encodeWithSignature("deposit()"));
        require(ok, "WETH wrap failed");
        IERC20(wethAddr).transfer(vaultAddr, ethAmount);
        vm.stopBroadcast();
        console2.log("  vault WETH bal:", IERC20(wethAddr).balanceOf(vaultAddr));
    }

    function _depositPhase() internal {
        console2.log("\n[STEPS 2-4] approve + deposit 500 USDC");
        uint256 amt = 500_000_000; // 500 USDC
        require(IERC20(usdcAddr).balanceOf(depositor) >= amt + 100_000_000,
                "depositor must hold >= 600 USDC (1000 funded)");

        vm.startBroadcast(depositorPk);
        IERC20(usdcAddr).approve(vaultAddr, amt);
        uint256 shares = IVault(vaultAddr).deposit(amt, depositor);
        vm.stopBroadcast();

        console2.log("  shares minted:", shares);
        require(shares > 0, "no shares minted");
    }

    function _assertLensProgress(Snap memory pre, Snap memory post) internal pure {
        require(post.tvl > pre.tvl, "lens.tvl did not grow");
        require(post.depositors >= pre.depositors, "lens.depositors regressed");
        require(post.depositorShares > pre.depositorShares, "depositor share balance did not increase");
        console2.log("\n[STEP 4] lens views moved");
        console2.log("  tvl       :", pre.tvl, "->", post.tvl);
        console2.log("  sharePrice:", pre.sharePrice, "->", post.sharePrice);
        console2.log("  depositors:", pre.depositors, "->", post.depositors);
    }

    function _quoteAndSwapUSDCtoWETH(PoolKey memory key, uint128 amountIn)
        internal
        returns (uint256 wethOut)
    {
        console2.log("\n[STEP 6] V4Quoter quote USDC -> WETH");
        IV4Quoter.QuoteExactSingleParams memory qp = IV4Quoter.QuoteExactSingleParams({
            poolKey: IV4Quoter.PoolKeyView({
                currency0: key.currency0,
                currency1: key.currency1,
                fee: key.fee,
                tickSpacing: key.tickSpacing,
                hooks: key.hooks
            }),
            zeroForOne: false, // USDC (currency1) -> WETH (currency0)
            exactAmount: amountIn,
            hookData: ""
        });
        // V4Quoter is non-view but eth_call simulates fine; broadcast then
        // capture the return.
        vm.startBroadcast(depositorPk);
        (uint256 amountOut, uint256 gasEst) =
            IV4Quoter(quoterAddr).quoteExactInputSingle(qp);
        vm.stopBroadcast();
        console2.log("  amountIn (USDC, 6dp):", amountIn);
        console2.log("  amountOut (WETH, wei):", amountOut);
        console2.log("  quoter gasEstimate    :", gasEst);
        require(amountOut > 0, "quoter returned 0");

        console2.log("\n[STEP 7] UR.execute USDC -> WETH (V4_SWAP / EXACT_IN_SINGLE)");
        uint256 minOut = (amountOut * 9_900) / 10_000; // 1% slippage floor
        wethOut = _urSwap(key, /*zeroForOne*/ false, amountIn, uint128(minOut));
        require(wethOut >= minOut, "swap got less than min");
        console2.log("  WETH received:", wethOut);
    }

    function _swapWETHtoUSDC(PoolKey memory key, uint128 amountIn) internal {
        console2.log("\n[STEP 10a] UR.execute WETH -> USDC (consumes reserve)");
        // No min-out floor (reserve is at vault-spread = swap will under-fill
        // vs raw pool, which is the whole point). Set floor to 0 so the
        // worse-priced reserve fill still settles.
        _urSwap(key, /*zeroForOne*/ true, amountIn, 0);
    }

    function _urSwap(PoolKey memory key, bool zeroForOne, uint128 amountIn, uint128 minOut)
        internal
        returns (uint256 outDelta)
    {
        address inTok  = zeroForOne ? wethAddr : usdcAddr;
        address outTok = zeroForOne ? usdcAddr : wethAddr;

        uint256 outBefore = IERC20(outTok).balanceOf(depositor);

        vm.startBroadcast(depositorPk);

        // ERC20 -> Permit2 (max). Idempotent across runs but cheap.
        IERC20(inTok).approve(permit2Addr, type(uint256).max);

        // Permit2 -> UR (max160, 30d expiry).
        IPermit2(permit2Addr).approve(
            inTok,
            routerAddr,
            type(uint160).max,
            uint48(block.timestamp + 30 days)
        );

        // commands = [V4_SWAP]
        bytes memory commands = abi.encodePacked(CMD_V4_SWAP);

        // actions = [SWAP_EXACT_IN_SINGLE, SETTLE_ALL, TAKE_ALL]
        bytes memory actions = abi.encodePacked(
            ACT_SWAP_EXACT_IN_SINGLE,
            ACT_SETTLE_ALL,
            ACT_TAKE_ALL
        );

        // params[0] = ExactInputSingleParams
        bytes memory swapParam = abi.encode(
            ExactInputSingleParams({
                poolKey: key,
                zeroForOne: zeroForOne,
                amountIn: amountIn,
                amountOutMinimum: minOut,
                hookData: ""
            })
        );
        // params[1] = (currencyIn, amountIn) for SETTLE_ALL
        bytes memory settleParam = abi.encode(Currency.wrap(inTok), uint256(amountIn));
        // params[2] = (currencyOut, minOut) for TAKE_ALL
        bytes memory takeParam = abi.encode(Currency.wrap(outTok), uint256(minOut));

        bytes[] memory params = new bytes[](3);
        params[0] = swapParam;
        params[1] = settleParam;
        params[2] = takeParam;

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);

        IUniversalRouter(routerAddr).execute(commands, inputs, block.timestamp + 600);
        vm.stopBroadcast();

        uint256 outAfter = IERC20(outTok).balanceOf(depositor);
        outDelta = outAfter - outBefore;
    }

    function _postVaultSpreadOffer(PoolKey memory key, uint128 sellAmount, uint16 spreadBps) internal {
        console2.log("\n[STEP 9] impersonated Ledger posts VAULT_SPREAD reserve offer");
        PoolId pid = key.toId();
        (uint160 poolSqrtP,,,) = IPoolManager(poolMgrAddr).getSlot0(pid);
        require(poolSqrtP > 0, "pool sqrt = 0");

        // Selling currency1 (USDC) under VAULT_SPREAD: vault sqrt must be
        // BELOW pool sqrt so gate `poolSqrtP >= vaultSqrtP` passes.
        uint160 vaultSqrt =
            uint160((uint256(poolSqrtP) * (20_000 - uint256(spreadBps))) / 20_000);

        uint64 expiry = uint64(block.timestamp + 900); // 15 min

        // Broadcast as the unlocked Ledger account (must be impersonated on
        // anvil before invoking forge script with --unlocked).
        vm.startBroadcast(ledgerOwner);
        IVault(vaultAddr).offerReserveToHookWithMode(
            Currency.wrap(usdcAddr),
            sellAmount,
            vaultSqrt,
            expiry,
            uint8(1) // ReservePricingMode.VAULT_SPREAD
        );
        vm.stopBroadcast();

        console2.log("  poolSqrt :", poolSqrtP);
        console2.log("  vaultSqrt:", vaultSqrt);
        console2.log("  sellAmt  :", sellAmount, "(USDC, 6dp)");
        console2.log("  spreadBps:", spreadBps);
    }

    // Local mirror of v4 ExactInputSingleParams (5-field, matches Arbitrum UR).
    struct ExactInputSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        bytes hookData;
    }
}
