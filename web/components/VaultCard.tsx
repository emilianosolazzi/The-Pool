'use client';

import { useMemo, useState } from 'react';
import {
  useAccount,
  useChainId,
  useReadContract,
  useReadContracts,
  useWaitForTransactionReceipt,
  useWriteContract,
} from 'wagmi';
import { arbitrum, arbitrumSepolia } from 'wagmi/chains';
import { erc20Abi, lensAbi, v4QuoterAbi, vaultAbi } from '@/lib/abis';
import { fmtUnits } from '@/lib/format';
import { getSwapInfra, type AppChainId, type Deployment } from '@/lib/deployments';
import { maxUint256, parseUnits, type Address } from 'viem';

type Tab = 'deposit' | 'withdraw';

const WITHDRAW_BUFFER_BPS = 500n;
const BPS_DENOMINATOR = 10_000n;

// Slippage guard (0.5%) applied to V4-quoted minOtherOut and the
// previewDeposit-derived minSharesOut. Conservative; users will hit it on
// quote-stale rejections, not on normal Arbitrum mempool latency.
const ZAP_SLIPPAGE_BPS = 50n;
const ZAP_DEADLINE_SECONDS = 5 * 60;

// VaultLens.VaultStatus enum order — must match VaultLens.sol.
const VAULT_STATUS = {
  UNCONFIGURED: 0,
  PAUSED: 1,
  IN_RANGE: 2,
  OUT_OF_RANGE: 3,
} as const;

export function VaultCard({ deployment, chainId }: { deployment: Deployment; chainId: number }) {
  const { address } = useAccount();
  const connectedChainId = useChainId();
  const onCorrectChain = address ? connectedChainId === chainId : true;
  const [tab, setTab] = useState<Tab>('deposit');
  const [amount, setAmount] = useState('');

  const vault = deployment.vault as Address | undefined;
  const asset = deployment.asset as Address | undefined;
  const lens = deployment.lens as Address | undefined;
  const dec = deployment.assetDecimals;
  const ready = Boolean(vault && asset);
  const swapInfra = getSwapInfra(chainId as AppChainId);
  const txExplorerBase =
    chainId === arbitrumSepolia.id ? 'https://sepolia.arbiscan.io' : 'https://arbiscan.io';

  // ── Zap deposit settings ────────────────────────────────────────────────
  // When VaultLens.vaultStatus(vault) == IN_RANGE, the vault must mint LP at
  // a tick range that requires both tokens, so a USDC-only deposit would sit
  // idle. We default to depositWithZap with a 50/50 split. The user can drag
  // the slider, or enable "Plain deposit (advanced)" to opt back to deposit().
  const [swapPct, setSwapPct] = useState<number>(50);
  const [forcePlain, setForcePlain] = useState<boolean>(false);

  const { data: wallet, refetch: refetchWallet } = useReadContracts({
    contracts:
      ready && address
        ? ([
            { address: asset!, abi: erc20Abi, functionName: 'balanceOf', args: [address], chainId },
            { address: asset!, abi: erc20Abi, functionName: 'allowance', args: [address, vault!], chainId },
            { address: vault!, abi: vaultAbi, functionName: 'balanceOf', args: [address], chainId },
            { address: vault!, abi: vaultAbi, functionName: 'previewRedeem', args: [0n], chainId },
          ] as const)
        : [],
    query: { enabled: ready && Boolean(address), refetchInterval: 15_000 },
  });

  const assetBalance = wallet?.[0]?.result as bigint | undefined;
  const allowance = wallet?.[1]?.result as bigint | undefined;
  const shares = wallet?.[2]?.result as bigint | undefined;

  const { data: rawShareDecimals } = useReadContract({
    address: vault,
    abi: vaultAbi,
    functionName: 'decimals',
    chainId,
    query: { enabled: Boolean(vault), refetchInterval: 60_000 },
  });

  const shareDecimals = rawShareDecimals as number | undefined;

  // ── Vault status & pool key (drive deposit-flow branching) ─────────────
  const { data: rawVaultStatus } = useReadContract({
    address: lens,
    abi: lensAbi,
    functionName: 'vaultStatus',
    args: vault ? [vault] : undefined,
    chainId,
    query: { enabled: Boolean(lens && vault), refetchInterval: 30_000 },
  });
  const vaultStatus = rawVaultStatus as number | undefined;
  const isInRange = vaultStatus === VAULT_STATUS.IN_RANGE;

  const { data: poolKey } = useReadContract({
    address: vault,
    abi: vaultAbi,
    functionName: 'poolKey',
    chainId,
    query: { enabled: Boolean(vault), refetchInterval: 60_000 },
  });

  // Default flow: zap when IN_RANGE, plain when OUT_OF_RANGE / PAUSED /
  // UNCONFIGURED. `forcePlain` lets advanced users override the IN_RANGE
  // default at their own risk.
  const useZap = isInRange && !forcePlain && Boolean(swapInfra);

  const parsed = useMemo(() => {
    if (!amount) return 0n;
    try {
      if (tab === 'withdraw') {
        if (shareDecimals === undefined) return 0n;
        return parseUnits(amount, shareDecimals);
      }
      return parseUnits(amount, dec);
    } catch {
      return 0n;
    }
  }, [amount, dec, shareDecimals, tab]);

  const conservativeMaxShares = useMemo(() => {
    if (shares === undefined || shares <= 0n) return 0n;
    const buffered = shares * (BPS_DENOMINATOR - WITHDRAW_BUFFER_BPS) / BPS_DENOMINATOR;
    return buffered > 0n ? buffered : shares;
  }, [shares]);

  // ── Zap quote inputs ───────────────────────────────────────────────────
  // assetsToSwap = parsed * swapPct%, capped at parsed. Recomputed on every
  // amount/slider change; we send this to V4Quoter as the exactInputSingle
  // amount and to depositWithZap as the on-chain swap size.
  const assetsToSwap = useMemo<bigint>(() => {
    if (!useZap || tab !== 'deposit' || parsed <= 0n) return 0n;
    const pct = BigInt(Math.max(0, Math.min(100, swapPct)));
    return (parsed * pct) / 100n;
  }, [parsed, swapPct, useZap, tab]);

  // V4Quoter quoteExactInputSingle: USDC → WETH on the vault's own pool.
  // Used as a price oracle for the off-pool V3 zap (close enough for a
  // slippage guard, and trivially front-runnable noise on Arbitrum L2).
  const quoteParams = useMemo(() => {
    if (!useZap || !poolKey || !asset || assetsToSwap <= 0n) return undefined;
    const pk = poolKey as {
      currency0: Address;
      currency1: Address;
      fee: number;
      tickSpacing: number;
      hooks: Address;
    };
    const zeroForOne = pk.currency0.toLowerCase() === (asset as string).toLowerCase();
    return [
      {
        poolKey: {
          currency0: pk.currency0,
          currency1: pk.currency1,
          fee: pk.fee,
          tickSpacing: pk.tickSpacing,
          hooks: pk.hooks,
        },
        zeroForOne,
        exactAmount: assetsToSwap,
        hookData: '0x' as `0x${string}`,
      },
    ] as const;
  }, [useZap, poolKey, asset, assetsToSwap]);

  const { data: quoteResult, isFetching: isQuoting, error: quoteError } = useReadContract({
    address: swapInfra?.v4Quoter,
    abi: v4QuoterAbi,
    functionName: 'quoteExactInputSingle',
    args: quoteParams,
    chainId,
    query: {
      enabled: Boolean(quoteParams && swapInfra?.v4Quoter),
      refetchInterval: 20_000,
    },
  });

  // viem returns the [amountOut, gasEstimate] tuple as an array.
  const quotedOtherOut = (quoteResult as readonly bigint[] | undefined)?.[0];
  const minOtherOut = useMemo<bigint>(() => {
    if (!quotedOtherOut || quotedOtherOut <= 0n) return 0n;
    return (quotedOtherOut * (BPS_DENOMINATOR - ZAP_SLIPPAGE_BPS)) / BPS_DENOMINATOR;
  }, [quotedOtherOut]);

  // previewDeposit gives shares for a plain deposit of `parsed` assets. The
  // zap mint is from realised NAV delta which should be ~= parsed minus the
  // round-trip swap loss, so `previewDeposit(parsed)` is a safe upper bound;
  // we discount it by ZAP_SLIPPAGE_BPS for the on-chain `minSharesOut` guard.
  const { data: rawPreviewDeposit } = useReadContract({
    address: vault,
    abi: vaultAbi,
    functionName: 'previewDeposit',
    args: tab === 'deposit' && parsed > 0n ? [parsed] : undefined,
    chainId,
    query: { enabled: Boolean(vault && tab === 'deposit' && parsed > 0n), refetchInterval: 20_000 },
  });
  const previewDepositShares = rawPreviewDeposit as bigint | undefined;
  const minSharesOut = useMemo<bigint>(() => {
    if (!useZap || !previewDepositShares || previewDepositShares <= 0n) return 0n;
    return (previewDepositShares * (BPS_DENOMINATOR - ZAP_SLIPPAGE_BPS)) / BPS_DENOMINATOR;
  }, [useZap, previewDepositShares]);

  // Block submit until the zap quote has resolved and produced a non-zero
  // minOtherOut. Without this guard a stale 0 would sail through with the
  // contract's permissive minOtherOut=0 fallback.
  const zapQuoteReady = !useZap || (quotedOtherOut !== undefined && quotedOtherOut > 0n);

  const { data: conservativeRedeemPreview } = useReadContract({
    address: vault,
    abi: vaultAbi,
    functionName: 'previewRedeem',
    args: conservativeMaxShares > 0n ? [conservativeMaxShares] : undefined,
    chainId,
    query: { enabled: Boolean(vault && conservativeMaxShares > 0n), refetchInterval: 15_000 },
  });

  const { data: inputRedeemPreview } = useReadContract({
    address: vault,
    abi: vaultAbi,
    functionName: 'previewRedeem',
    args: tab === 'withdraw' && parsed > 0n ? [parsed] : undefined,
    chainId,
    query: { enabled: Boolean(vault && tab === 'withdraw' && parsed > 0n), refetchInterval: 15_000 },
  });

  const needsApproval =
    tab === 'deposit' && parsed > 0n && (allowance ?? 0n) < parsed;

  const exceedsConservativeWithdraw =
    tab === 'withdraw' && conservativeMaxShares > 0n && parsed > conservativeMaxShares;

  const { writeContract, data: txHash, isPending, reset } = useWriteContract();
  const { isLoading: isMining, isSuccess } = useWaitForTransactionReceipt({ hash: txHash });

  if (isSuccess && !isPending) {
    // one-shot refresh
    queueMicrotask(() => {
      refetchWallet();
      reset();
      setAmount('');
    });
  }

  const onApprove = () => {
    if (!asset || !vault || !onCorrectChain) return;
    writeContract({
      address: asset,
      abi: erc20Abi,
      functionName: 'approve',
      args: [vault, maxUint256],
      chainId,
    });
  };

  const onSubmit = () => {
    if (!vault || !address || parsed <= 0n || !onCorrectChain) return;
    if (tab === 'deposit') {
      if (useZap) {
        if (!zapQuoteReady) return;
        const deadline = BigInt(Math.floor(Date.now() / 1000) + ZAP_DEADLINE_SECONDS);
        // minLiquidity=0: the user-facing slippage budget is already enforced
        // by minOtherOut (zap input side) and minSharesOut (mint output side);
        // gating on a third minLiquidity here would just produce confusing
        // surface-level reverts on benign tick noise.
        writeContract({
          address: vault,
          abi: vaultAbi,
          functionName: 'depositWithZap',
          args: [parsed, address, assetsToSwap, minOtherOut, 0n, minSharesOut, deadline],
          chainId,
        });
      } else {
        writeContract({
          address: vault,
          abi: vaultAbi,
          functionName: 'deposit',
          args: [parsed, address],
          chainId,
        });
      }
    } else {
      writeContract({
        address: vault,
        abi: vaultAbi,
        functionName: 'redeem',
        args: [parsed, address, address],
        chainId,
      });
    }
  };

  const onMax = () => {
    if (tab === 'deposit' && assetBalance !== undefined) {
      setAmount(fmtUnits(assetBalance, dec, dec));
    } else if (tab === 'withdraw' && conservativeMaxShares > 0n && shareDecimals !== undefined) {
      setAmount(fmtUnits(conservativeMaxShares, shareDecimals, shareDecimals));
    }
  };

  const disabled =
    !ready ||
    !address ||
    !onCorrectChain ||
    parsed <= 0n ||
    isPending ||
    isMining ||
    (tab === 'withdraw' && shareDecimals === undefined) ||
    (tab === 'deposit' && assetBalance !== undefined && parsed > assetBalance) ||
    (tab === 'withdraw' && shares !== undefined && parsed > shares) ||
    (tab === 'deposit' && useZap && !zapQuoteReady) ||
    exceedsConservativeWithdraw;

  const expectedChainName =
    chainId === arbitrum.id
      ? 'Arbitrum One'
      : chainId === arbitrumSepolia.id
        ? 'Arbitrum Sepolia'
        : `chain ${chainId}`;

  return (
    <div className="card shadow-glow">
      <div className="flex items-center justify-between border-b border-white/5 p-5">
        <div>
          <div className="stat-label">Vault</div>
          <div className="mt-1 text-lg font-semibold text-white">
            {deployment.pairSymbol} · deposit {deployment.assetSymbol}
          </div>
        </div>
        <div className="flex rounded-xl border border-white/10 bg-ink-800/70 p-1 text-xs">
          {(['deposit', 'withdraw'] as const).map((t) => (
            <button
              key={t}
              onClick={() => {
                setTab(t);
                setAmount('');
              }}
              className={`rounded-lg px-3 py-1.5 capitalize transition ${
                tab === t
                  ? 'bg-accent-500 text-ink-950 font-semibold'
                  : 'text-zinc-400 hover:text-white'
              }`}
            >
              {t}
            </button>
          ))}
        </div>
      </div>

      {!ready ? (
        <div className="p-6 text-sm text-zinc-400">
          Vault address is not configured for this chain. Set{' '}
          <code className="rounded bg-white/5 px-1.5 py-0.5 font-mono">
            NEXT_PUBLIC_VAULT_ARB_ONE
          </code>{' '}
          in Vercel environment variables and redeploy.
        </div>
      ) : (
        <div className="space-y-4 p-5">
          <div className="flex items-center justify-between text-xs text-zinc-500">
            <span>{tab === 'deposit' ? 'Amount' : 'Shares'}</span>
            <span>
              {tab === 'deposit'
                ? `Balance: ${fmtUnits(assetBalance, dec, 4)} ${deployment.assetSymbol}`
                : `Shares: ${shareDecimals === undefined ? '—' : fmtUnits(shares, shareDecimals, 6)}`}
            </span>
          </div>

          <div className="relative">
            <input
              className="input pr-16"
              placeholder="0.0"
              inputMode="decimal"
              value={amount}
              onChange={(e) => setAmount(e.target.value.replace(/[^0-9.]/g, ''))}
            />
            <button
              onClick={onMax}
              className="absolute right-2 top-1/2 -translate-y-1/2 rounded-md border border-white/10 bg-white/5 px-2 py-1 text-[11px] font-semibold text-zinc-300 hover:bg-white/10"
            >
              MAX
            </button>
          </div>

          {tab === 'deposit' && (
            <div className="space-y-2 rounded-lg border border-white/5 bg-ink-800/40 px-3 py-2 text-xs text-zinc-400">
              {/* Mandatory copy: explains why USDC-only deposits need a zap
                  while the LP range is active. */}
              <div className="text-zinc-300">
                The vault accepts {deployment.assetSymbol} only. When the
                selected LP range is active, the vault must hold both{' '}
                {deployment.assetSymbol} and WETH; the zap deposit swaps part
                of your {deployment.assetSymbol} into WETH automatically.
              </div>

              {vaultStatus === undefined ? (
                <div className="text-zinc-500">Checking vault range status…</div>
              ) : isInRange ? (
                <div className="text-emerald-300">
                  Range status:{' '}
                  <span className="font-semibold">eligible to earn (in-range)</span>{' '}
                  — vault liquidity sits within the active tick band, so it is
                  on the donation list for incoming hooked swaps. Using zap
                  deposit by default.
                </div>
              ) : vaultStatus === VAULT_STATUS.OUT_OF_RANGE ? (
                <div className="text-zinc-300">
                  Range status:{' '}
                  <span className="font-semibold">idle (out-of-range)</span> —
                  single-sided {deployment.assetSymbol} deployment is valid but
                  earns no swap fees until price re-enters the band. Using
                  plain deposit.
                </div>
              ) : vaultStatus === VAULT_STATUS.PAUSED ? (
                <div className="text-amber-300">Vault paused.</div>
              ) : (
                <div className="text-amber-300">Vault not yet configured.</div>
              )}

              {isInRange && !swapInfra && (
                <div className="text-amber-300">
                  Swap infrastructure not configured for this chain; falling
                  back to plain deposit.
                </div>
              )}

              {useZap && (
                <div className="space-y-2 border-t border-white/5 pt-2">
                  <label className="flex items-center justify-between text-zinc-300">
                    <span>Swap part of deposit to WETH for active liquidity</span>
                    <span className="font-mono">{swapPct}%</span>
                  </label>
                  <input
                    type="range"
                    min={0}
                    max={100}
                    step={5}
                    value={swapPct}
                    onChange={(e) => setSwapPct(Number(e.target.value))}
                    className="w-full accent-accent-500"
                  />
                  <div className="grid grid-cols-2 gap-x-3 gap-y-1 font-mono text-[11px] text-zinc-500">
                    <div>Swap in:</div>
                    <div className="text-right text-zinc-300">
                      {fmtUnits(assetsToSwap, dec, 4)} {deployment.assetSymbol}
                    </div>
                    <div>Quoted WETH out:</div>
                    <div className="text-right text-zinc-300">
                      {quotedOtherOut === undefined
                        ? isQuoting
                          ? '…'
                          : '—'
                        : fmtUnits(quotedOtherOut, 18, 6)}
                    </div>
                    <div>Min WETH (0.5%):</div>
                    <div className="text-right text-zinc-300">
                      {minOtherOut > 0n ? fmtUnits(minOtherOut, 18, 6) : '—'}
                    </div>
                    <div>Min shares (0.5%):</div>
                    <div className="text-right text-zinc-300">
                      {minSharesOut > 0n && shareDecimals !== undefined
                        ? fmtUnits(minSharesOut, shareDecimals, 6)
                        : '—'}
                    </div>
                  </div>
                  {quoteError && (
                    <div className="text-amber-300">
                      Quote unavailable; submit is disabled until the quoter
                      responds.
                    </div>
                  )}
                </div>
              )}

              {isInRange && (
                <div className="border-t border-white/5 pt-2">
                  <label className="flex cursor-pointer items-center gap-2 text-zinc-400">
                    <input
                      type="checkbox"
                      checked={forcePlain}
                      onChange={(e) => setForcePlain(e.target.checked)}
                      className="accent-accent-500"
                    />
                    <span>Plain {deployment.assetSymbol} deposit (advanced)</span>
                  </label>
                  {forcePlain && (
                    <div className="mt-1 text-amber-300">
                      In-range plain {deployment.assetSymbol} deposits may
                      remain idle unless the vault already has WETH.
                    </div>
                  )}
                </div>
              )}
            </div>
          )}

          {tab === 'withdraw' && shares !== undefined && shares > 0n && (
            <div className="space-y-1 rounded-lg border border-white/5 bg-ink-800/40 px-3 py-2 text-xs text-zinc-400">
              <div>
                Conservative max -&gt; ~{fmtUnits(conservativeRedeemPreview as bigint | undefined, dec, 4)}{' '}
                {deployment.assetSymbol}
              </div>
              {parsed > 0n && (
                <div>
                  This redeem -&gt; ~{fmtUnits(inputRedeemPreview as bigint | undefined, dec, 4)}{' '}
                  {deployment.assetSymbol}
                </div>
              )}
              {exceedsConservativeWithdraw && (
                <div className="text-amber-300">
                  Use MAX to leave a 5% execution buffer.
                </div>
              )}
            </div>
          )}

          {!address ? (
            <div className="rounded-lg border border-white/10 bg-white/5 px-3 py-3 text-center text-sm text-zinc-400">
              Connect a wallet to {tab}.
            </div>
          ) : !onCorrectChain ? (
            <div className="rounded-lg border border-amber-400/30 bg-amber-500/5 px-3 py-3 text-center text-sm text-amber-200">
              Switch to {expectedChainName} to {tab}.
            </div>
          ) : needsApproval ? (
            <button onClick={onApprove} disabled={isPending || isMining || !onCorrectChain} className="btn-primary w-full">
              {isPending || isMining ? 'Approving…' : `Approve ${deployment.assetSymbol}`}
            </button>
          ) : (
            <button onClick={onSubmit} disabled={disabled} className="btn-primary w-full">
              {isPending || isMining
                ? tab === 'deposit'
                  ? useZap
                    ? 'Zap-depositing…'
                    : 'Depositing…'
                  : 'Redeeming…'
                : tab === 'deposit'
                  ? useZap
                    ? isQuoting && !zapQuoteReady
                      ? 'Quoting…'
                      : `Zap-deposit ${deployment.assetSymbol}`
                    : `Deposit ${deployment.assetSymbol}`
                  : 'Redeem shares'}
            </button>
          )}

          {txHash && (
            <a
              href={`${txExplorerBase}/tx/${txHash}`}
              target="_blank"
              rel="noopener noreferrer"
              className="block text-center text-xs text-accent-400 hover:underline"
            >
              View transaction ↗
            </a>
          )}

          <div className="pt-1 text-[11px] text-zinc-600">
            Deposits are not swaps. Deposit mints ERC-4626 vault shares;
            redeem returns the vault asset by default. Share price rises as
            hook fees accrue; anyone can call collectYield(). Deployment into
            active range happens on deposit() and owner rebalance() paths.
          </div>
        </div>
      )}
    </div>
  );
}
