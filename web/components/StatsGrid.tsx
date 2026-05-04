'use client';

import { useMemo } from 'react';
import { useReadContract, useReadContracts } from 'wagmi';
import { vaultAbi, lensAbi } from '@/lib/abis';
import { fmtCompact, fmtUnits } from '@/lib/format';
import { type Deployment } from '@/lib/deployments';
import type { Address } from 'viem';

interface Props {
  deployment: Deployment;
  chainId: number;
}

const NAV_PRICE_DEVIATION_SELECTOR = '0xb2ebe9c8';

const isNavPriceDeviation = (error: unknown): boolean => {
  if (!error) return false;
  const message = error instanceof Error ? error.message : String(error);
  return (
    message.includes(NAV_PRICE_DEVIATION_SELECTOR) ||
    message.includes('NAV_PRICE_DEVIATION')
  );
};

export function StatsGrid({ deployment, chainId }: Props) {
  const vault = deployment.vault as Address | undefined;
  const lens = deployment.lens as Address | undefined;
  const enabled = Boolean(vault);
  const statsEnabled = Boolean(vault && lens);

  const {
    data: rawStats,
    isLoading: isStatsLoading,
    isError: isStatsError,
    error: statsError,
  } = useReadContract({
    address: lens,
    abi: lensAbi,
    functionName: 'getVaultStats',
    args: vault ? [vault] : undefined,
    chainId,
    query: { enabled: statsEnabled, refetchInterval: 15_000 },
  });

  const { data: directStats, isLoading: isDirectStatsLoading } = useReadContracts({
    allowFailure: true,
    contracts: vault
      ? ([
          { address: vault, abi: vaultAbi, functionName: 'totalDepositors', chainId },
          { address: vault, abi: vaultAbi, functionName: 'assetsDeployed', chainId },
          { address: vault, abi: vaultAbi, functionName: 'totalYieldCollected', chainId },
          { address: vault, abi: vaultAbi, functionName: 'maxNavDeviationBps', chainId },
        ] as const)
      : [],
    query: { enabled, refetchInterval: 15_000 },
  });

  const { data: tickLower, isLoading: isTickLowerLoading } = useReadContract({
    address: vault,
    abi: vaultAbi,
    functionName: 'tickLower',
    chainId,
    query: { enabled, refetchInterval: 15_000 },
  });

  const { data: tickUpper, isLoading: isTickUpperLoading } = useReadContract({
    address: vault,
    abi: vaultAbi,
    functionName: 'tickUpper',
    chainId,
    query: { enabled, refetchInterval: 15_000 },
  });

  const { data: perfBps, isLoading: isPerfLoading } = useReadContract({
    address: vault,
    abi: vaultAbi,
    functionName: 'performanceFeeBps',
    chainId,
    query: { enabled, refetchInterval: 15_000 },
  });

  const stats = useMemo(() => {
    if (!rawStats) return undefined;

    if (Array.isArray(rawStats) && rawStats.length >= 6) {
      return rawStats as readonly [bigint, bigint, bigint, bigint, bigint, string];
    }

    const obj = rawStats as unknown as Partial<Record<string, unknown>>;
    if (
      typeof obj.tvl === 'bigint' &&
      typeof obj.sharePrice === 'bigint' &&
      typeof obj.depositors === 'bigint' &&
      typeof obj.liqDeployed === 'bigint' &&
      typeof obj.yieldColl === 'bigint' &&
      typeof obj.feeDesc === 'string'
    ) {
      return [
        obj.tvl,
        obj.sharePrice,
        obj.depositors,
        obj.liqDeployed,
        obj.yieldColl,
        obj.feeDesc,
      ] as const;
    }

    return undefined;
  }, [rawStats]);

  const navGuardActive = isStatsError && isNavPriceDeviation(statsError);
  const directDepositors = directStats?.[0]?.status === 'success'
    ? directStats[0].result as bigint
    : undefined;
  const directYieldCollected = directStats?.[2]?.status === 'success'
    ? directStats[2].result as bigint
    : undefined;
  const directMaxNavDeviationBps = directStats?.[3]?.status === 'success'
    ? directStats[3].result as bigint
    : undefined;

  const isLoading =
    isStatsLoading ||
    isDirectStatsLoading ||
    isTickLowerLoading ||
    isTickUpperLoading ||
    isPerfLoading;

  const cards = [
    {
      label: 'TVL',
      value: vault
        ? stats
          ? `${fmtCompact(stats[0], deployment.assetDecimals)} ${deployment.assetSymbol}`
          : navGuardActive
            ? 'Guarded'
            : `${fmtCompact(undefined, deployment.assetDecimals)} ${deployment.assetSymbol}`
        : 'Not deployed',
      sub: vault ? 'Total assets under management' : 'Vault address not set',
    },
    {
      label: 'Share price',
      value: stats ? `${fmtUnits(stats[1], 18, 6)}` : navGuardActive ? 'Guarded' : '—',
      sub: '1 share → asset units (×10¹⁸)',
    },
    {
      label: 'Depositors',
      value: stats ? stats[2].toString() : directDepositors !== undefined ? directDepositors.toString() : '—',
      sub: 'Unique LPs',
    },
    {
      label: 'Yield collected',
      value: stats
        ? `${fmtCompact(stats[4], deployment.assetDecimals)} ${deployment.assetSymbol}`
        : directYieldCollected !== undefined
          ? `${fmtCompact(directYieldCollected, deployment.assetDecimals)} ${deployment.assetSymbol}`
          : '—',
      sub: 'Lifetime harvested into share price',
    },
    {
      label: 'Performance fee',
      value: perfBps !== undefined ? `${(Number(perfBps) / 100).toFixed(2)}%` : '—',
      sub: 'Treasury cut on yield',
    },
    {
      label: 'Tick range',
      value:
        tickLower !== undefined && tickUpper !== undefined
          ? `${tickLower} → ${tickUpper}`
          : '—',
      sub: 'Live on-chain · owner-rebalanceable',
    },
  ];

  return (
    <div>
      <div className="grid grid-cols-2 gap-3 md:grid-cols-3">
        {cards.map((c) => (
          <div key={c.label} className="card card-hover p-4">
            <div className="stat-label">{c.label}</div>
            <div className="stat-value mt-1">{isLoading && enabled ? '…' : c.value}</div>
            <div className="mt-1 text-xs text-zinc-500">{c.sub}</div>
          </div>
        ))}
      </div>
      {stats?.[5] && (
        <p className="mt-4 text-center text-xs text-zinc-500 font-mono">
          {stats[5]}
        </p>
      )}
      {isStatsError && (
        <p className="mt-2 text-center text-xs text-amber-400">
          {navGuardActive
            ? `NAV guard is active; TVL and share price are paused until the vault reference is refreshed${
                directMaxNavDeviationBps !== undefined
                  ? ` (${Number(directMaxNavDeviationBps) / 100}% tolerance).`
                  : '.'
              }`
            : 'Could not read live vault stats from RPC.'}
        </p>
      )}
    </div>
  );
}
