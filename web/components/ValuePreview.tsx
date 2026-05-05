'use client';

/**
 * ValuePreview — homepage teaser for the full /value calculator.
 *
 * Reads live TVL, lifetime hook fees routed, BootstrapRewards.programStart
 * (used as proxy for "vault live since"), and the epoch-0 bonus pool. Then
 * shows a single-line projection for a $1,000 depositor based ONLY on what is
 * already on-chain (no synthetic volume assumption). Both the lifetime rate
 * and the annualized rate are shown so visitors don't misread "$X over the
 * lifetime fee window" as an annual yield.
 *
 * Math (deliberately conservative; full sensitivity model lives at /value):
 *   - feeYieldLifetime = hookFeesRouted / TVL
 *   - daysLive         = max(1, (now - programStart) / 86400)
 *   - feeYieldAnnual   = feeYieldLifetime * (365 / daysLive)
 *   - LP_SHARE         = 80% (FeeDistributor default LP-side donation)
 *   - userYearOnFees   = 1000 * feeYieldAnnual * LP_SHARE
 *
 * If TVL is zero or hook fees are zero, the projection is suppressed and the
 * card invites the user to model it explicitly at /value.
 */

import Link from 'next/link';
import { useMemo } from 'react';
import { useReadContract } from 'wagmi';
import { lensAbi, hookAbi, bootstrapAbi } from '@/lib/abis';
import type { Deployment } from '@/lib/deployments';
import type { Address } from 'viem';

interface Props {
  deployment: Deployment;
  chainId: number;
}

const DEPOSIT_USD = 1_000;
const LP_SHARE = 0.8;
const SECONDS_PER_DAY = 86_400;

function fmtUsd(n: number, frac = 0): string {
  if (!Number.isFinite(n)) return '—';
  return n.toLocaleString('en-US', {
    style: 'currency',
    currency: 'USD',
    minimumFractionDigits: frac,
    maximumFractionDigits: frac,
  });
}

export function ValuePreview({ deployment, chainId }: Props) {
  const vault = deployment.vault as Address | undefined;
  const lens = deployment.lens as Address | undefined;
  const hook = deployment.hook as Address | undefined;
  const bootstrap = deployment.bootstrap as Address | undefined;

  const { data: stats } = useReadContract({
    address: lens,
    abi: lensAbi,
    functionName: 'getVaultStats',
    args: vault ? [vault] : undefined,
    chainId,
    query: { enabled: Boolean(vault && lens), refetchInterval: 30_000 },
  });

  const { data: feesRouted } = useReadContract({
    address: hook,
    abi: hookAbi,
    functionName: 'totalFeesRouted',
    chainId,
    query: { enabled: Boolean(hook), refetchInterval: 30_000 },
  });

  const { data: epoch0 } = useReadContract({
    address: bootstrap,
    abi: bootstrapAbi,
    functionName: 'epochs',
    args: [0n],
    chainId,
    query: { enabled: Boolean(bootstrap), refetchInterval: 60_000 },
  });

  const { data: programStart } = useReadContract({
    address: bootstrap,
    abi: bootstrapAbi,
    functionName: 'programStart',
    chainId,
    query: { enabled: Boolean(bootstrap), staleTime: 600_000 },
  });

  const projection = useMemo(() => {
    if (!stats || !Array.isArray(stats)) return undefined;
    const tvl = stats[0] as bigint;
    const fees = (feesRouted as bigint | undefined) ?? 0n;
    const dec = BigInt(10) ** BigInt(deployment.assetDecimals);
    const tvlNum = Number(tvl) / Number(dec);
    const feesNum = Number(fees) / Number(dec);
    if (tvlNum <= 0 || feesNum <= 0) return undefined;

    const feeYieldLifetime = feesNum / tvlNum;

    // Days live: use programStart when available, else clamp to 1 day.
    const startSec = programStart ? Number(programStart) : 0;
    const nowSec = Math.floor(Date.now() / 1000);
    const daysLive =
      startSec > 0 && nowSec > startSec
        ? Math.max(1, (nowSec - startSec) / SECONDS_PER_DAY)
        : undefined;
    const feeYieldAnnual =
      daysLive !== undefined ? feeYieldLifetime * (365 / daysLive) : undefined;

    const userYearOnFees =
      feeYieldAnnual !== undefined
        ? DEPOSIT_USD * feeYieldAnnual * LP_SHARE
        : undefined;

    const bonusPool = epoch0 && Array.isArray(epoch0) ? (epoch0[0] as bigint) : 0n;
    const bonusPoolNum = Number(bonusPool) / Number(dec);

    return {
      feeYieldLifetime,
      feeYieldAnnual,
      userYearOnFees,
      tvl: tvlNum,
      bonusPool: bonusPoolNum,
      daysLive,
    };
  }, [stats, feesRouted, epoch0, programStart, deployment.assetDecimals]);

  return (
    <section id="value-preview" className="mx-auto max-w-6xl px-4 py-12">
      <div className="card border-iris-500/30 bg-gradient-to-br from-iris-500/5 to-accent-500/5 p-6 md:p-8">
        <div className="flex flex-col gap-6 md:flex-row md:items-center md:justify-between">
          <div className="max-w-xl">
            <div className="external-badge mb-3">If you deposit $1,000 today</div>
            <h2 className="text-2xl font-semibold tracking-tight md:text-3xl">
              {projection?.userYearOnFees !== undefined ? (
                <>
                  Projected fee yield ≈{' '}
                  <span className="gradient-text">
                    {fmtUsd(projection.userYearOnFees, 2)}
                  </span>{' '}
                  <span className="text-base font-normal text-zinc-400">
                    / year (annualized from on-chain rate)
                  </span>
                </>
              ) : (
                <>
                  Model your real return on{' '}
                  <span className="gradient-text">live pool data</span>.
                </>
              )}
            </h2>
            <p className="mt-3 text-sm text-zinc-400">
              {projection ? (
                <>
                  Lifetime hook-fee yield to date:{' '}
                  <span className="font-mono text-zinc-200">
                    {(projection.feeYieldLifetime * 100).toFixed(3)}%
                  </span>{' '}
                  of{' '}
                  <span className="font-mono text-zinc-200">
                    {fmtUsd(projection.tvl, 0)}
                  </span>{' '}
                  TVL
                  {projection.daysLive !== undefined ? (
                    <>
                      , earned over{' '}
                      <span className="font-mono text-zinc-200">
                        {projection.daysLive < 1
                          ? '<1'
                          : projection.daysLive.toFixed(1)}
                      </span>{' '}
                      days{' '}
                      {projection.feeYieldAnnual !== undefined && (
                        <>
                          (≈
                          <span className="font-mono text-zinc-200">
                            {(projection.feeYieldAnnual * 100).toFixed(2)}%
                          </span>{' '}
                          annualized)
                        </>
                      )}
                    </>
                  ) : null}
                  . After 80% LP donation. Plus a slice of the{' '}
                  <span className="font-mono text-zinc-200">
                    {fmtUsd(projection.bonusPool, 0)}
                  </span>{' '}
                  USDC bonus pool while eligible.{' '}
                  <span className="text-zinc-500">
                    Past activity doesn&apos;t forecast future swap volume.
                  </span>
                </>
              ) : (
                <>
                  Project your share of hook fees and the early-depositor bonus
                  using the live pool numbers — TVL, share price, fee
                  distribution split, and bonus pool. No assumptions baked in.
                </>
              )}
            </p>
          </div>
          <div className="flex flex-shrink-0 flex-col gap-2 md:items-end">
            <Link href="/value" className="btn-primary">
              Open the calculator
            </Link>
            <Link href="#vault" className="btn-ghost">
              Or just deposit
            </Link>
          </div>
        </div>
      </div>
    </section>
  );
}
