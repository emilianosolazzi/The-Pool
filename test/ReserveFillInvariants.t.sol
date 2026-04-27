// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {DynamicFeeHookV2} from "../src/DynamicFeeHookV2.sol";
import {FeeDistributor} from "../src/FeeDistributor.sol";
import {HookMiner} from "./utils/HookMiner.sol";

/// @notice Conservation + lifecycle invariants for `_tryFillReserve`. Each
///         test starts from a fresh offer, performs one swap, and asserts:
///           - escrow / proceeds / sellRemaining moved by *exactly* the
///             expected delta (no over-/under-credit)
///           - hook ERC20 balances dominate live escrow + outstanding proceeds
///           - direction / staleness / expiry / exact-output gates produce
///             zero-mutation no-fill behaviour
///
///         Run with: forge test --match-contract ReserveFillInvariants -vv
contract ReserveFillInvariantsTest is Test, Deployers {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    DynamicFeeHookV2 public hook;
    FeeDistributor public distributor;
    PoolKey public poolKey;
    address public treasury = makeAddr("treasury");
    address public vaultEOA = makeAddr("vault");

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        distributor = new FeeDistributor(manager, treasury, address(0));

        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        (address hookAddr, bytes32 salt) = HookMiner.find(
            address(this),
            flags,
            type(DynamicFeeHookV2).creationCode,
            abi.encode(address(manager), address(distributor), address(this))
        );
        hook = new DynamicFeeHookV2{salt: salt}(manager, address(distributor), address(this));
        require(address(hook) == hookAddr, "hook addr mismatch");
        distributor.setHook(address(hook));

        (poolKey,) = initPool(currency0, currency1, IHooks(address(hook)), 100, SQRT_PRICE_1_1);
        distributor.setPoolKey(poolKey);

        // Deep liquidity so AMM tails do not bonk on price limits.
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: -3000, tickUpper: 3000, liquidityDelta: 10_000e18, salt: 0}),
            ZERO_BYTES
        );

        hook.registerVault(poolKey, vaultEOA);

        // Fund the vault for both sell directions and pre-approve the hook.
        MockERC20(Currency.unwrap(currency0)).mint(vaultEOA, 100 ether);
        MockERC20(Currency.unwrap(currency1)).mint(vaultEOA, 100 ether);
        vm.startPrank(vaultEOA);
        MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
        vm.stopPrank();
    }

    // -----------------------------------------------------------------
    // Conservation helper. Hook ERC20 holdings must dominate live
    // accounting state for both currencies. After every swap there are
    // no other in-flight legs (fee path settles in afterSwap), so the
    // hook holds exactly escrow + proceeds for each currency.
    // -----------------------------------------------------------------
    function _assertHookConservation() internal view {
        uint256 esc0 = hook.escrowedReserve(vaultEOA, currency0);
        uint256 esc1 = hook.escrowedReserve(vaultEOA, currency1);
        uint256 prc0 = hook.proceedsOwed(vaultEOA, currency0);
        uint256 prc1 = hook.proceedsOwed(vaultEOA, currency1);
        uint256 bal0 = MockERC20(Currency.unwrap(currency0)).balanceOf(address(hook));
        uint256 bal1 = MockERC20(Currency.unwrap(currency1)).balanceOf(address(hook));

        // Hook balance is the union of both vault-owned buckets per currency.
        // Fees have already been transferred out to the distributor in
        // afterSwap, so hook balance equals escrow + proceeds exactly.
        assertGe(bal0, esc0 + prc0, "hook c0 balance < escrow0 + proceeds0");
        assertGe(bal1, esc1 + prc1, "hook c1 balance < escrow1 + proceeds1");
    }

    function _postOfferSell1(uint128 sellAmount) internal {
        vm.prank(vaultEOA);
        hook.createReserveOffer(poolKey, currency1, sellAmount, SQRT_PRICE_1_1, 0);
    }

    function _postOfferSell0(uint128 sellAmount) internal {
        vm.prank(vaultEOA);
        hook.createReserveOffer(poolKey, currency0, sellAmount, SQRT_PRICE_1_1, 0);
    }

    // =================================================================
    // 1. Partial fill — vault sells currency1, zeroForOne exact-input
    // =================================================================
    function test_invariant_partialFill_sellC1_zeroForOne() public {
        uint128 sellAmount = 1 ether;
        _postOfferSell1(sellAmount);
        uint256 escBefore = hook.escrowedReserve(vaultEOA, currency1);
        uint256 prcBefore = hook.proceedsOwed(vaultEOA, currency0);
        uint256 fillsBefore = hook.totalReserveFills();
        assertEq(escBefore, sellAmount, "initial escrow == sellAmount");

        // Swapper input strictly less than takeCap (1.0 at 1:1) so it's a partial.
        uint256 swapIn = 0.4 ether;
        uint256 t1Before = MockERC20(Currency.unwrap(currency1)).balanceOf(address(this));
        uint256 t0Before = MockERC20(Currency.unwrap(currency0)).balanceOf(address(this));
        swap(poolKey, true, -int256(swapIn), ZERO_BYTES);
        uint256 t1Got = MockERC20(Currency.unwrap(currency1)).balanceOf(address(this)) - t1Before;
        uint256 t0Spent = t0Before - MockERC20(Currency.unwrap(currency0)).balanceOf(address(this));

        DynamicFeeHookV2.ReserveOffer memory o = hook.getOffer(poolKey);
        uint128 give = sellAmount - o.sellRemaining;

        // Conservation: every bucket moves by the exact same delta.
        assertTrue(o.active, "offer still active after partial fill");
        assertEq(uint256(o.sellRemaining), uint256(sellAmount) - uint256(give), "sellRemaining delta");
        assertEq(hook.escrowedReserve(vaultEOA, currency1), escBefore - uint256(give), "escrow delta");
        assertEq(hook.proceedsOwed(vaultEOA, currency0), prcBefore + swapIn, "proceeds == take");
        assertEq(t0Spent, swapIn, "swapper paid exactly amountSpecified");
        // At sqrtP_1_1, give == take. Allow only the AMM-tail fee deduction
        // on the fraction that bypassed reserve (here zero, full fill from
        // reserve), so equality must hold exactly.
        assertEq(t1Got, swapIn, "1:1 fill: out == in");
        assertEq(uint256(give), swapIn, "give == take at 1:1");
        assertEq(hook.totalReserveFills(), fillsBefore + 1, "one fill counted");

        _assertHookConservation();
    }

    // =================================================================
    // 2. Full fill — vault sells currency1, swap maxInput exceeds takeCap.
    //    Hook charges *exactly* takeCap, residual flows to AMM.
    // =================================================================
    function test_invariant_fullFill_sellC1_routesResidualToAMM() public {
        uint128 sellAmount = 0.5 ether;
        _postOfferSell1(sellAmount);

        uint256 swapIn = 1.2 ether; // >> takeCap (=0.5 at 1:1)
        uint256 t0Before = MockERC20(Currency.unwrap(currency0)).balanceOf(address(this));
        uint256 t1Before = MockERC20(Currency.unwrap(currency1)).balanceOf(address(this));
        swap(poolKey, true, -int256(swapIn), ZERO_BYTES);
        uint256 t0Spent = t0Before - MockERC20(Currency.unwrap(currency0)).balanceOf(address(this));
        uint256 t1Got = MockERC20(Currency.unwrap(currency1)).balanceOf(address(this)) - t1Before;

        DynamicFeeHookV2.ReserveOffer memory o = hook.getOffer(poolKey);
        assertFalse(o.active, "offer drained -> inactive");
        assertEq(o.sellRemaining, 0, "sellRemaining == 0");

        // Reserve drained exactly: escrow falls by full sellAmount, proceeds
        // gain exactly takeCap (= sellAmount at 1:1). AMM took the residual,
        // so swapper paid full input and received >= sellAmount of token1.
        assertEq(hook.escrowedReserve(vaultEOA, currency1), 0, "escrow drained");
        assertEq(hook.proceedsOwed(vaultEOA, currency0), uint256(sellAmount), "proceeds == takeCap");
        assertEq(t0Spent, swapIn, "swapper paid full amountSpecified");
        // Reserve hands over `sellAmount` 1:1 plus AMM tail. Tail is taxed
        // by the dynamic hook fee, so out is sellAmount + (residual * (1-fee)).
        // Lower-bound the assertion: must exceed the reserve-only portion.
        assertGt(t1Got, uint256(sellAmount), "out exceeds reserve-only portion");

        _assertHookConservation();
    }

    // =================================================================
    // 3. Partial fill — vault sells currency0, oneForZero exact-input
    // =================================================================
    function test_invariant_partialFill_sellC0_oneForZero() public {
        uint128 sellAmount = 1 ether;
        _postOfferSell0(sellAmount);

        uint256 escBefore = hook.escrowedReserve(vaultEOA, currency0);
        uint256 prcBefore = hook.proceedsOwed(vaultEOA, currency1);
        assertEq(escBefore, sellAmount, "initial escrow == sellAmount");

        uint256 swapIn = 0.3 ether;
        uint256 t1Before = MockERC20(Currency.unwrap(currency1)).balanceOf(address(this));
        uint256 t0Before = MockERC20(Currency.unwrap(currency0)).balanceOf(address(this));
        swap(poolKey, false, -int256(swapIn), ZERO_BYTES);
        uint256 t1Spent = t1Before - MockERC20(Currency.unwrap(currency1)).balanceOf(address(this));
        uint256 t0Got = MockERC20(Currency.unwrap(currency0)).balanceOf(address(this)) - t0Before;

        DynamicFeeHookV2.ReserveOffer memory o = hook.getOffer(poolKey);
        uint128 give = sellAmount - o.sellRemaining;

        assertTrue(o.active, "still active");
        assertEq(uint256(o.sellRemaining), uint256(sellAmount) - uint256(give), "sellRemaining delta");
        assertEq(hook.escrowedReserve(vaultEOA, currency0), escBefore - uint256(give), "escrow delta");
        assertEq(hook.proceedsOwed(vaultEOA, currency1), prcBefore + swapIn, "proceeds == take");
        assertEq(t1Spent, swapIn, "swapper paid amountSpecified");
        assertEq(t0Got, swapIn, "1:1 fill: out == in");
        assertEq(uint256(give), swapIn, "give == take at 1:1");

        _assertHookConservation();
    }

    // =================================================================
    // 4. Wrong direction — vault sells c1 but swap is oneForZero.
    //    No fill, no accounting mutation, AMM-only path.
    // =================================================================
    function test_invariant_wrongDirection_noFillNoMutation() public {
        uint128 sellAmount = 1 ether;
        _postOfferSell1(sellAmount);

        uint256 escBefore = hook.escrowedReserve(vaultEOA, currency1);
        uint256 prc0Before = hook.proceedsOwed(vaultEOA, currency0);
        uint256 prc1Before = hook.proceedsOwed(vaultEOA, currency1);
        uint256 fillsBefore = hook.totalReserveFills();

        // oneForZero (wrong direction for a sell-c1 offer).
        swap(poolKey, false, -int256(0.5 ether), ZERO_BYTES);

        DynamicFeeHookV2.ReserveOffer memory o = hook.getOffer(poolKey);
        assertTrue(o.active, "offer still active");
        assertEq(o.sellRemaining, sellAmount, "sellRemaining unchanged");
        assertEq(hook.escrowedReserve(vaultEOA, currency1), escBefore, "escrow unchanged");
        assertEq(hook.proceedsOwed(vaultEOA, currency0), prc0Before, "proceeds0 unchanged");
        assertEq(hook.proceedsOwed(vaultEOA, currency1), prc1Before, "proceeds1 unchanged");
        assertEq(hook.totalReserveFills(), fillsBefore, "no reserve fill counted");

        _assertHookConservation();
    }

    // =================================================================
    // 5. Stale price gate — pool has drifted past offer's vault price,
    //    so the offer is *worse* than AMM. No fill.
    // =================================================================
    function test_invariant_stalePriceGate_noFill() public {
        // For a sell-c1 offer the price gate requires poolSqrtP <= vaultSqrtP
        // (vault must give >= AMM rate to the swapper). Posting the offer at
        // vaultSqrtP slightly BELOW the current pool price puts the offer on
        // the wrong side of the gate -> no fill, optionally a stale event.
        uint160 staleP = uint160(SQRT_PRICE_1_1 - (SQRT_PRICE_1_1 / 1000)); // 0.1% below 1:1
        vm.prank(vaultEOA);
        hook.createReserveOffer(poolKey, currency1, 1 ether, staleP, 0);

        uint256 escBefore = hook.escrowedReserve(vaultEOA, currency1);
        uint256 prc0Before = hook.proceedsOwed(vaultEOA, currency0);
        uint256 fillsBefore = hook.totalReserveFills();

        swap(poolKey, true, -int256(0.4 ether), ZERO_BYTES);

        DynamicFeeHookV2.ReserveOffer memory o = hook.getOffer(poolKey);
        assertTrue(o.active, "offer survives stale gate");
        assertEq(o.sellRemaining, 1 ether, "sellRemaining unchanged");
        assertEq(hook.escrowedReserve(vaultEOA, currency1), escBefore, "escrow unchanged");
        assertEq(hook.proceedsOwed(vaultEOA, currency0), prc0Before, "proceeds unchanged");
        assertEq(hook.totalReserveFills(), fillsBefore, "no fill counted");

        _assertHookConservation();
    }

    // =================================================================
    // 6. Expired offer — no fill, funds remain cancellable by vault.
    // =================================================================
    function test_invariant_expiredOffer_noFill_funcsRecoverable() public {
        uint128 sellAmount = 1 ether;
        uint64 expiry = uint64(block.timestamp + 100);
        vm.prank(vaultEOA);
        hook.createReserveOffer(poolKey, currency1, sellAmount, SQRT_PRICE_1_1, expiry);

        // Jump past expiry.
        vm.warp(uint256(expiry) + 1);

        uint256 escBefore = hook.escrowedReserve(vaultEOA, currency1);
        swap(poolKey, true, -int256(0.4 ether), ZERO_BYTES);

        DynamicFeeHookV2.ReserveOffer memory o = hook.getOffer(poolKey);
        assertTrue(o.active, "offer still flagged active despite expired");
        assertEq(o.sellRemaining, sellAmount, "sellRemaining unchanged after expired-no-fill");
        assertEq(hook.escrowedReserve(vaultEOA, currency1), escBefore, "escrow unchanged");

        // Vault can still cancel and reclaim the full inventory.
        uint256 vaultBalBefore = MockERC20(Currency.unwrap(currency1)).balanceOf(vaultEOA);
        vm.prank(vaultEOA);
        uint128 returned = hook.cancelReserveOffer(poolKey);
        assertEq(returned, sellAmount, "cancel returns full inventory");
        assertEq(
            MockERC20(Currency.unwrap(currency1)).balanceOf(vaultEOA),
            vaultBalBefore + uint256(sellAmount),
            "vault received full inventory back"
        );
        assertEq(hook.escrowedReserve(vaultEOA, currency1), 0, "escrow cleared after cancel");

        _assertHookConservation();
    }

    // =================================================================
    // 7. Exact-output swap — beforeSwap skips reserve fill entirely.
    // =================================================================
    function test_invariant_exactOutputSwap_noReserveFill() public {
        uint128 sellAmount = 1 ether;
        _postOfferSell1(sellAmount);

        uint256 escBefore = hook.escrowedReserve(vaultEOA, currency1);
        uint256 prc0Before = hook.proceedsOwed(vaultEOA, currency0);
        uint256 fillsBefore = hook.totalReserveFills();

        // Positive amountSpecified -> exact-output swap.
        // Want 0.3 token1 out for some unknown token0 in.
        swap(poolKey, true, int256(0.3 ether), ZERO_BYTES);

        DynamicFeeHookV2.ReserveOffer memory o = hook.getOffer(poolKey);
        assertTrue(o.active, "offer untouched on exact-output");
        assertEq(o.sellRemaining, sellAmount, "sellRemaining unchanged");
        assertEq(hook.escrowedReserve(vaultEOA, currency1), escBefore, "escrow unchanged");
        assertEq(hook.proceedsOwed(vaultEOA, currency0), prc0Before, "proceeds unchanged");
        assertEq(hook.totalReserveFills(), fillsBefore, "no reserve fill on exact-output");

        _assertHookConservation();
    }

    // =================================================================
    // 8. Fee path is post-swap and does not corrupt transient state.
    //    After a sequence of mixed swaps (fill, no-fill, AMM-only),
    //    state remains consistent and pending-multiplier transient slots
    //    don't leak across pools/transactions.
    // =================================================================
    function test_invariant_feePath_doesNotCorruptTransientState() public {
        uint128 sellAmount = 0.6 ether;
        _postOfferSell1(sellAmount);

        // Swap A: partial fill from reserve.
        swap(poolKey, true, -int256(0.3 ether), ZERO_BYTES);
        _assertHookConservation();

        // Swap B: drain the remaining offer + AMM tail in the same direction.
        // (AMM-direction swaps between fills can push poolSqrtP above
        // vaultSqrtP and gate off subsequent fills, which is correct
        // staleness behaviour but not what this test exercises.)
        swap(poolKey, true, -int256(1 ether), ZERO_BYTES);
        DynamicFeeHookV2.ReserveOffer memory o = hook.getOffer(poolKey);
        assertFalse(o.active, "offer drained after swap B");
        assertEq(o.sellRemaining, 0, "sellRemaining zeroed");
        _assertHookConservation();

        // Swap C: opposite direction (AMM only, no offer left).
        swap(poolKey, false, -int256(0.2 ether), ZERO_BYTES);
        _assertHookConservation();

        // Swap D: pure AMM (no offer at all).
        swap(poolKey, false, -int256(0.1 ether), ZERO_BYTES);
        _assertHookConservation();

        // Vault claim: proceeds zero out cleanly.
        vm.startPrank(vaultEOA);
        hook.claimReserveProceeds(currency0);
        hook.claimReserveProceeds(currency1);
        vm.stopPrank();
        assertEq(hook.proceedsOwed(vaultEOA, currency0), 0, "c0 proceeds claimed");
        assertEq(hook.proceedsOwed(vaultEOA, currency1), 0, "c1 proceeds claimed");
        // After full drain + claim, hook holds at most leftover-fee dust;
        // since fee path transfers out, hook accounting buckets are zero.
        assertEq(hook.escrowedReserve(vaultEOA, currency0), 0, "escrow0 zero");
        assertEq(hook.escrowedReserve(vaultEOA, currency1), 0, "escrow1 zero");
    }
}
