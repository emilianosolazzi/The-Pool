'use client';

/**
 * ValuePreview — homepage teaser for the full /value calculator.
 *
 * Honest-by-construction:
 *   - We deliberately do NOT compute a "$X / year" projection from
 *     `totalFeesRouted` on the homepage. That counter is denominated in
 *     whichever currency was the *output* of each swap, so on a WETH/USDC
 *     pool it sums 6-dec USDC and 18-dec WETH into a single uint256. Any
 *     attempt to treat that mixed sum as USDC overstates the yield by ~1e12.
 *   - We also do not extrapolate annualized rates while TVL is in the
 *     bootstrap window. Dividing real fees by a $12 TVL produces numbers
 *     that are technically correct but misleading.
 *
 * What we DO show: live TVL, bonus pool, program age, and a CTA into /value
 * where the full per-currency model lives.
 */

import Link from 'next/link';
import { useMemo } from 'react';
import { useReadContract } from 'wagmi';
import { lensAbi, bootstrapAbi } from '@/lib/abis';
import type { Deployment } from '@/lib/deployments';
import type { Address } from 'viem';

interface Props {
  deployment: Deployment;
  chainId: number;
}

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
  const bootstrap = deployment.bootstrap as Address | undefined;

  const { data: stats } = useReadContract({
    address: lens,
    abi: lensAbi,
    functionName: 'getVaultStats',
    args: vault ? [vault] : undefined,
    chainId,
    query: { enabled: Boolean(vault && lens), refetchInterval: 30_000 },
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

  const facts = useMemo(() => {
    if (!stats || !Array.isArray(stats)) return undefined;
    const tvl = stats[0] as bigint;
    const dec = BigInt(10) ** BigInt(deployment.assetDecimals);
    const tvlNum = Number(tvl) / Number(dec);

    const bonusPool =
      epoch0 && Array.isArray(epoch0) ? (epoch0[0] as bigint) : 0n;
    const bonusPoolNum = Number(bonusPool) / Number(dec);

    const startSec = programStart ? Number(programStart) : 0;
    const nowSec = Math.floor(Date.now() / 1000);
    const daysLive =
      startSec > 0 && nowSec > startSec
        ? (nowSec - startSec) / SECONDS_PER_DAY
        : undefined;

    return { tvl: tvlNum, bonusPool: bonusPoolNum, daysLive };
  }, [stats, epoch0, programStart, deployment.assetDecimals]);

  return (
    <section id="value-preview" className="mx-auto max-w-6xl px-4 py-12">
      <div className="card border-iris-500/30 bg-gradient-to-br from-iris-500/5 to-accent-500/5 p-6 md:p-8">
        <div className="flex flex-col gap-6 md:flex-row md:items-center md:justify-between">
          <div className="max-w-xl">
            <div className="external-badge mb-3">Model your real return</div>
            <h2 className="text-2xl font-semibold tracking-tight md:text-3xl">
              See exactly what a deposit earns on{' '}
              <span className="gradient-text">live pool data</span>.
            </h2>
            <p className="mt-3 text-sm text-zinc-400">
              {facts ? (
                <>
                  Live TVL:{' '}
                  <span className="font-mono text-zinc-200">
                    {fmtUsd(facts.tvl, 2)}
                  </span>
                  . Bonus pool:{' '}
                  <span className="font-mono text-zinc-200">
                    {fmtUsd(facts.bonusPool, 0)} USDC
                  </span>
                  {facts.daysLive !== undefined && (
                    <>
                      . Program age:{' '}
                      <span className="font-mono text-zinc-200">
                        {facts.daysLive < 1
                          ? '<1'
                          : facts.daysLive.toFixed(1)}{' '}
                        days
                      </span>
                    </>
                  )}
                  .{' '}
                  <span className="text-zinc-500">
                    Pool is in bootstrap. Open the calculator to project fees
                    per swap currency from your own assumptions instead of
                    inferring from a sub-$1k TVL window.
                  </span>
                </>
              ) : (
                <>
                  Project your share of hook fees and the early-depositor bonus
                  using live pool numbers — TVL, share price, fee distribution
                  split, bonus pool. Every input is on-chain and editable.
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
