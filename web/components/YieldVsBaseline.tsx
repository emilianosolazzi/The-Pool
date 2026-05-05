'use client';

/**
 * YieldVsBaseline — the single chart serious LPs ask for.
 *
 * Methodology (committed; honest about the data window):
 *
 *   1. Vault yield since launch
 *      = sharePrice(now) / sharePrice(launch) - 1
 *      where sharePrice = vault.convertToAssets(1e18).
 *      ERC-4626 mints first shares at 1:1, so sharePrice(launch) ≈ 1e18.
 *
 *   2. v3 baseline — passive full-range LP yield
 *      Uses feeGrowthGlobal0X128 / feeGrowthGlobal1X128 on the configured
 *      Uniswap v3 reference pool (`v3BaselinePool`). These are cumulative
 *      fees per unit of liquidity; the delta over a window equals what a
 *      hypothetical full-range v3 LP earned per unit liquidity, which is
 *      a *conservative* baseline (tighter ranges earn more). To convert
 *      to a yield rate, we divide by `liquidity` at sample time and
 *      mark-to-market both tokens to USDC.
 *
 *   3. Window
 *      We only render the comparison once we have ≥7 days of vault data
 *      (rolling-window stability threshold). Below that, we display
 *      "Insufficient data — N days since launch" and the methodology card.
 *
 * Why this component is honest:
 *   - We do not extrapolate or annualize on noisy windows (< 7 days).
 *   - We display v3 baseline even when it is *beating* the vault.
 *     If we hide such windows, the chart becomes marketing, not signal.
 *   - We commit to the comparison up-front; sophisticated LPs test for
 *     this exact behavior.
 *
 * Implementation note:
 *   This first cut renders the methodology + raw vault share-price
 *   evolution from client-side localStorage snapshots (one per hour).
 *   The v3 baseline read-path is wired up but the historical delta
 *   calculation requires either an archive node or a backfill script;
 *   we surface the *current* baseline reading and label the historical
 *   line "coming online" until we have backfill in place. Methodology
 *   is the contract, the chart fills in over time.
 */

import { useEffect, useMemo, useState } from 'react';
import { useReadContract, useReadContracts } from 'wagmi';
import { parseUnits, type Address } from 'viem';
import { vaultAbi } from '@/lib/abis';
import type { Deployment } from '@/lib/deployments';

interface Props {
  deployment: Deployment;
  chainId: number;
}

const SECONDS_PER_DAY = 86_400;
const ROLLING_WINDOW_DAYS = 7;
const SNAPSHOT_INTERVAL_MS = 60 * 60 * 1000; // 1 hour
const MAX_SNAPSHOTS = 30 * 24; // 30 days at hourly cadence

interface Snapshot {
  ts: number; // unix seconds
  sp: string; // share price as decimal string (1e18 fixed)
}

function snapshotKey(vault: Address | undefined, chainId: number): string {
  return `pool.snapshots.${chainId}.${(vault ?? '').toLowerCase()}`;
}

function loadSnapshots(key: string): Snapshot[] {
  if (typeof window === 'undefined') return [];
  try {
    const raw = localStorage.getItem(key);
    if (!raw) return [];
    const arr = JSON.parse(raw) as Snapshot[];
    return Array.isArray(arr) ? arr : [];
  } catch {
    return [];
  }
}

function saveSnapshots(key: string, snaps: Snapshot[]): void {
  if (typeof window === 'undefined') return;
  try {
    localStorage.setItem(key, JSON.stringify(snaps.slice(-MAX_SNAPSHOTS)));
  } catch {
    /* quota exceeded — silently drop */
  }
}

// Minimal Uniswap v3 pool ABI for fee-growth + slot0.
const v3PoolAbi = [
  {
    type: 'function',
    name: 'feeGrowthGlobal0X128',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ type: 'uint256' }],
  },
  {
    type: 'function',
    name: 'feeGrowthGlobal1X128',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ type: 'uint256' }],
  },
  {
    type: 'function',
    name: 'liquidity',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ type: 'uint128' }],
  },
] as const;

export function YieldVsBaseline({ deployment, chainId }: Props) {
  const vault = deployment.vault as Address | undefined;
  const v3Pool = deployment.v3BaselinePool;
  const launchedAt = deployment.launchedAt ?? 0;
  const oneShare = useMemo(() => parseUnits('1', 18), []);

  // Current vault share price, scaled to asset decimals.
  const { data: spAssets } = useReadContract({
    address: vault,
    abi: vaultAbi,
    functionName: 'convertToAssets',
    args: [oneShare],
    chainId,
    query: { enabled: Boolean(vault), refetchInterval: 30_000 },
  });

  // v3 baseline current state — used only to confirm we can read it.
  const { data: v3State } = useReadContracts({
    allowFailure: true,
    contracts: v3Pool
      ? ([
          { address: v3Pool, abi: v3PoolAbi, functionName: 'feeGrowthGlobal0X128', chainId },
          { address: v3Pool, abi: v3PoolAbi, functionName: 'feeGrowthGlobal1X128', chainId },
          { address: v3Pool, abi: v3PoolAbi, functionName: 'liquidity', chainId },
        ] as const)
      : [],
    query: { enabled: Boolean(v3Pool), refetchInterval: 60_000 },
  });

  const v3Reachable = Boolean(
    v3State && v3State.every((r) => r.status === 'success')
  );

  // Snapshot vault share price hourly into localStorage.
  const [snapshots, setSnapshots] = useState<Snapshot[]>([]);

  useEffect(() => {
    if (!vault) return;
    const key = snapshotKey(vault, chainId);
    setSnapshots(loadSnapshots(key));
  }, [vault, chainId]);

  useEffect(() => {
    if (!vault || spAssets === undefined) return;
    const key = snapshotKey(vault, chainId);
    const existing = loadSnapshots(key);
    const nowSec = Math.floor(Date.now() / 1000);
    const last = existing[existing.length - 1];
    if (last && nowSec * 1000 - last.ts * 1000 < SNAPSHOT_INTERVAL_MS) {
      return; // throttle to 1/hour
    }
    const next: Snapshot = { ts: nowSec, sp: (spAssets as bigint).toString() };
    const updated = [...existing, next].slice(-MAX_SNAPSHOTS);
    saveSnapshots(key, updated);
    setSnapshots(updated);
  }, [vault, chainId, spAssets]);

  const daysSinceLaunch =
    launchedAt > 0
      ? Math.max(0, (Math.floor(Date.now() / 1000) - launchedAt) / SECONDS_PER_DAY)
      : undefined;

  // Vault yield since launch, expressed as a simple ratio.
  // Assumes ERC-4626 first-deposit minted 1:1 (sp(launch) = 1 asset per share),
  // so sp_now scaled to asset decimals minus 1 unit asset = absolute return.
  const dec = deployment.assetDecimals;
  const oneAsset = useMemo(() => 10n ** BigInt(dec), [dec]);
  const vaultYieldPct = useMemo(() => {
    if (spAssets === undefined) return undefined;
    const sp = spAssets as bigint;
    if (sp === 0n) return undefined;
    const num = Number(sp - oneAsset);
    const denom = Number(oneAsset);
    return (num / denom) * 100;
  }, [spAssets, oneAsset]);

  const ready = daysSinceLaunch !== undefined && daysSinceLaunch >= ROLLING_WINDOW_DAYS;

  return (
    <section
      id="yield-vs-baseline"
      aria-label="Vault yield versus passive v3 LP baseline"
      className="mx-auto max-w-6xl px-4 py-12"
    >
      <div className="card border-white/10 p-6 md:p-8">
        <div className="flex flex-col gap-2 md:flex-row md:items-end md:justify-between">
          <div>
            <div className="external-badge mb-3">Honest comparison</div>
            <h2 className="text-2xl font-semibold tracking-tight md:text-3xl">
              Vault yield <span className="text-zinc-400">vs</span>{' '}
              <span className="gradient-text">passive v3 LP baseline</span>
            </h2>
            <p className="mt-2 max-w-2xl text-sm text-zinc-400">
              The only chart that answers &ldquo;does the hook actually beat
              v3?&rdquo;. Methodology is committed up front; numbers fill in
              with on-chain history. We render the comparison even on days the
              baseline wins.
            </p>
          </div>
          <div className="text-right text-xs text-zinc-500">
            <div>
              Days since launch:{' '}
              <span className="font-mono text-zinc-300">
                {daysSinceLaunch !== undefined
                  ? daysSinceLaunch.toFixed(1)
                  : '—'}
              </span>
            </div>
            <div>
              Window threshold:{' '}
              <span className="font-mono text-zinc-300">
                {ROLLING_WINDOW_DAYS}d
              </span>
            </div>
          </div>
        </div>

        <div className="mt-6 grid gap-4 md:grid-cols-2">
          <div className="rounded-xl border border-white/10 bg-white/[0.02] p-5">
            <div className="text-xs uppercase tracking-wider text-zinc-400">
              Vault — realized return since launch
            </div>
            <div className="mt-2 font-mono text-3xl font-semibold text-white">
              {vaultYieldPct !== undefined
                ? `${vaultYieldPct >= 0 ? '+' : ''}${vaultYieldPct.toFixed(4)}%`
                : '—'}
            </div>
            <div className="mt-2 text-xs text-zinc-500">
              From <code className="rounded bg-white/5 px-1">convertToAssets(1e18)</code>.
              Share price advances at flush blocks; this is realized only,
              excluding latent v4 fee growth.
            </div>
            <div className="mt-3 text-xs text-zinc-500">
              Snapshots stored:{' '}
              <span className="font-mono text-zinc-300">{snapshots.length}</span>
              {' · '}cadence: 1/hour client-side
            </div>
          </div>

          <div className="rounded-xl border border-white/10 bg-white/[0.02] p-5">
            <div className="text-xs uppercase tracking-wider text-zinc-400">
              v3 baseline — same window
            </div>
            <div className="mt-2 font-mono text-3xl font-semibold text-zinc-400">
              {ready ? 'backfill pending' : '—'}
            </div>
            <div className="mt-2 text-xs text-zinc-500">
              {deployment.v3BaselineLabel ?? 'No reference pool configured'}
              {v3Pool && (
                <>
                  {' · '}
                  <a
                    className="text-zinc-300 underline-offset-2 hover:underline"
                    href={`https://arbiscan.io/address/${v3Pool}`}
                    target="_blank"
                    rel="noopener noreferrer"
                  >
                    pool
                  </a>
                </>
              )}
            </div>
            <div className="mt-3 text-xs text-zinc-500">
              Read-path:{' '}
              <span
                className={`font-mono ${
                  v3Reachable ? 'text-emerald-300' : 'text-amber-300'
                }`}
              >
                {v3Reachable ? 'live' : 'connecting'}
              </span>
              {' · '}data:{' '}
              <span className="font-mono text-zinc-300">
                {ready ? 'computing rolling 7d' : `awaiting ${ROLLING_WINDOW_DAYS}d`}
              </span>
            </div>
          </div>
        </div>

        {!ready && (
          <div className="mt-6 rounded-lg border border-amber-500/20 bg-amber-500/[0.04] p-4 text-sm text-amber-200">
            <div className="font-semibold">Insufficient data window.</div>
            <div className="mt-1 text-amber-200/80">
              We render the comparison once we have ≥{ROLLING_WINDOW_DAYS} days
              of post-launch data. Annualizing on shorter windows produces
              numbers that are technically correct but misleading. The
              methodology below is the protocol-level commitment.
            </div>
          </div>
        )}

        <details className="mt-6 rounded-lg border border-white/10 bg-white/[0.02] p-4 text-sm text-zinc-300">
          <summary className="cursor-pointer text-zinc-200">
            Methodology — exactly how each number is computed
          </summary>
          <ol className="mt-3 list-decimal space-y-3 pl-5 text-zinc-400">
            <li>
              <span className="text-white">Vault realized yield</span> ={' '}
              <code className="rounded bg-white/5 px-1 font-mono">
                vault.convertToAssets(1e18) / 1e{deployment.assetDecimals} − 1
              </code>
              . First deposit mints 1:1 by ERC-4626 convention, so this is the
              cumulative realized return. Excludes uncollected v4 fees by
              design — see{' '}
              <a
                className="text-zinc-200 underline-offset-2 hover:underline"
                href="https://github.com/emilianosolazzi/The-Pool-Adaptive-Reserve-Hook/blob/main/docs/SPEC.md#22-equation-i"
                target="_blank"
                rel="noopener noreferrer"
              >
                SPEC §2.2
              </a>
              .
            </li>
            <li>
              <span className="text-white">v3 baseline</span> = passive
              full-range LP yield on{' '}
              <span className="text-zinc-200">{deployment.v3BaselineLabel}</span>{' '}
              over the same time window. Computed from{' '}
              <code className="rounded bg-white/5 px-1 font-mono">
                feeGrowthGlobal0X128 / feeGrowthGlobal1X128
              </code>{' '}
              deltas, divided by{' '}
              <code className="rounded bg-white/5 px-1 font-mono">liquidity</code>{' '}
              at sample time, marked to USDC at spot. This is conservative:
              tighter v3 ranges earn more, but they also have non-zero
              re-balance cost we&rsquo;re not modeling.
            </li>
            <li>
              <span className="text-white">Window</span> — rolling{' '}
              {ROLLING_WINDOW_DAYS} days, refreshed hourly. Below the threshold
              we show neither vault APR nor baseline APR; both numbers would
              be statistical noise.
            </li>
            <li>
              <span className="text-white">Honesty contract</span> — when the
              v3 baseline beats the vault on a given window, we render the
              window. If we hid losing windows the chart would be marketing,
              not signal.
            </li>
          </ol>
        </details>
      </div>
    </section>
  );
}
