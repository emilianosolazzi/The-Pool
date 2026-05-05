export function Hero({ pairSymbol }: { pairSymbol: string; swapUrl?: string }) {
  return (
    <section className="relative overflow-hidden border-b border-white/5">
      <div className="absolute inset-0 bg-hero-mesh pointer-events-none" />
      <div className="relative mx-auto max-w-6xl px-4 py-20 md:py-28">
        <div className="mb-6 flex flex-wrap gap-2">
          <span className="chip">
            <span className="h-1.5 w-1.5 rounded-full bg-emerald-400 shadow-[0_0_10px_rgba(52,211,153,0.8)]" />
            Live on Arbitrum One
          </span>
          <span className="chip">Uniswap v4 hook</span>
          <span className="chip">ERC-4626 vault</span>
          <span className="chip">No emissions · no lockups</span>
        </div>

        <h1 className="max-w-4xl text-4xl font-semibold tracking-tight text-white md:text-6xl">
          Earn USDC yield from real{' '}
          <span className="gradient-text">Uniswap v4 trading activity</span>{' '}
          — plus a 180-day early-depositor bonus.
        </h1>

        <p className="mt-5 max-w-2xl text-balance text-lg text-zinc-300/90">
          Every swap through our hook donates{' '}
          <strong className="text-white">80% of the fee back to LPs</strong> in
          the same transaction. The first{' '}
          <strong className="text-white">$100K of TVL</strong> also captures{' '}
          <strong className="text-white">50% of the treasury stream</strong>{' '}
          for 180 days, paid in USDC.{' '}
          <span className="text-zinc-400">
            Pair: <span className="font-mono text-zinc-200">{pairSymbol}</span>.
          </span>
        </p>

        <div className="mt-8 flex flex-wrap items-center gap-3">
          <a href="#vault" className="btn-primary">
            Deposit USDC
          </a>
          <a href="#proof" className="btn-ghost">
            See live proof
          </a>
          <a href="/value" className="btn-ghost">
            Calculate my yield
          </a>
        </div>

        {/* Compact risk row — replaces the long disclaimer paragraph */}
        <div className="mt-8 flex flex-wrap gap-2 text-xs">
          <span className="rounded-full border border-amber-500/30 bg-amber-500/10 px-3 py-1 text-amber-200">
            Fee capture only while range is in-range
          </span>
          <span className="rounded-full border border-amber-500/30 bg-amber-500/10 px-3 py-1 text-amber-200">
            Bonus capped: $25K/wallet · $10K/epoch
          </span>
          <span className="rounded-full border border-amber-500/30 bg-amber-500/10 px-3 py-1 text-amber-200">
            7-day eligibility dwell · transfers may forfeit accrual
          </span>
          <a
            href="https://github.com/emilianosolazzi/The-Pool/blob/main/docs/HOOK-RISK-RUNBOOK.md"
            target="_blank"
            rel="noopener noreferrer"
            className="rounded-full border border-white/10 bg-white/5 px-3 py-1 text-zinc-300 hover:border-white/20 hover:text-white"
          >
            Risk runbook ↗
          </a>
        </div>
      </div>
    </section>
  );
}
