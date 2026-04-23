import type { Deployment } from '@/lib/deployments';

/**
 * Plain-English explainer. Facts verified against src/LiquidityVault.sol,
 * src/DynamicFeeHook.sol, src/FeeDistributor.sol:
 *  - 25 BPS base hook fee, 1.5x in volatile blocks, capped at maxFeeBps=50
 *  - 20% of hook fee -> treasury, 80% -> poolManager.donate() to in-range LPs
 *  - Vault is ERC-4626 single-sided out-of-range (asset only, earns as price
 *    crosses into range)
 *  - Share price auto-compounds; no claim flow
 */
export function PlainEnglish({ deployment }: { deployment: Deployment }) {
  const a = deployment.assetSymbol;
  const pair = deployment.pairSymbol;

  const lines: { label: string; body: React.ReactNode }[] = [
    {
      label: '01',
      body: (
        <>
          You deposit{' '}
          <span className="text-white font-semibold">{a}</span> into this vault.
        </>
      ),
    },
    {
      label: '02',
      body: (
        <>
          The vault deploys it as a single-sided concentrated-liquidity position
          on Uniswap&nbsp;v4 on the{' '}
          <span className="text-white font-semibold">{pair}</span> pool.
        </>
      ),
    },
    {
      label: '03',
      body: (
        <>
          Every swap in that pool pays a{' '}
          <span className="text-white font-semibold">25&nbsp;bps fee</span>{' '}
          (1.5× in volatile blocks, hard-capped at 50&nbsp;bps).
        </>
      ),
    },
    {
      label: '04',
      body: (
        <>
          <span className="text-white font-semibold">80%</span> of that fee is
          donated back to LPs in the pool — including your vault position — in
          the same transaction.{' '}
          <span className="text-zinc-400">(The other 20% funds the treasury.)</span>
        </>
      ),
    },
    {
      label: '05',
      body: (
        <>
          The vault{' '}
          <span className="text-white font-semibold">auto-compounds</span>. Your
          share price rises as fees accrue — no harvest, no reinvest, no claim.
        </>
      ),
    },
  ];

  return (
    <section className="mx-auto max-w-6xl px-4 py-14 md:py-20">
      <div className="relative overflow-hidden rounded-3xl border border-white/10 bg-gradient-to-br from-accent-500/10 via-iris-500/5 to-transparent p-6 md:p-10">
        <div className="pointer-events-none absolute -top-24 -right-24 h-64 w-64 rounded-full bg-accent-500/30 blur-3xl" />
        <div className="pointer-events-none absolute -bottom-24 -left-24 h-64 w-64 rounded-full bg-iris-500/30 blur-3xl" />

        <div className="relative">
          <div className="mb-6 flex items-center gap-2">
            <span className="chip">In plain English</span>
          </div>
          <h2 className="mb-8 max-w-2xl text-2xl font-semibold tracking-tight text-white md:text-3xl">
            What happens when you <span className="gradient-text">deposit {a}</span>.
          </h2>

          <ol className="space-y-4">
            {lines.map((l) => (
              <li key={l.label} className="flex items-start gap-4">
                <span className="mt-0.5 flex h-8 w-8 shrink-0 items-center justify-center rounded-lg border border-white/10 bg-white/5 font-mono text-xs font-semibold text-accent-300">
                  {l.label}
                </span>
                <p className="text-base leading-relaxed text-zinc-200 md:text-lg">
                  {l.body}
                </p>
              </li>
            ))}
          </ol>

          <div className="mt-8 rounded-2xl border border-white/10 bg-black/20 p-4 text-sm text-zinc-300">
            <span className="text-white font-semibold">Honest caveat.</span> The
            vault is single-sided: it holds {a} and earns fees while waiting to
            convert across the owner-configured tick range. During periods when
            the market price sits inside or above the range, the position is
            idle until the owner calls <code className="rounded bg-white/5 px-1 font-mono">rebalance()</code>.
          </div>
        </div>
      </div>
    </section>
  );
}
