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
          USDC yield from real{' '}
          <span className="gradient-text">Uniswap v4 trading activity</span>.
        </h1>

        <p className="mt-5 max-w-2xl text-balance text-lg text-zinc-300/90">
          Two distinct streams, kept separate on purpose:
        </p>

        <ul className="mt-4 max-w-2xl space-y-2 text-base text-zinc-300/90">
          <li>
            <span className="text-white font-semibold">Market yield</span>{' '}
            <span className="text-zinc-400">— variable, uncapped.</span>{' '}
            Each hooked swap routes 80% of its fee into{' '}
            <code className="rounded bg-white/5 px-1 font-mono text-sm">poolManager.donate()</code>.
            That fee is split <em>liquidity-time-weighted at the donation
            block</em> across every in-range LP, so vault depositors capture{' '}
            <span className="font-mono text-white">L_vault / Σ L_j</span>{' '}
            of each donation.{' '}
            <span className="text-zinc-400">
              Vault liquidity is presently dominant in the active range. That is
              today’s market state, not a protocol invariant; any third party can
              mint an overlapping range and dilute future donations
              proportional to their L<sub>j</sub>.
            </span>
          </li>
          <li>
            <span className="text-white font-semibold">Incentive yield</span>{' '}
            <span className="text-zinc-400">— capped, scheduled, conditional.</span>{' '}
            A 180-day early-depositor program funded from treasury inflows. Today
            the epoch pool reads live below; caps and windows are on-chain.
          </li>
        </ul>

        <p className="mt-3 max-w-2xl text-sm text-zinc-400">
          Pair: <span className="font-mono text-zinc-200">{pairSymbol}</span>.
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
          <a href="https://github.com/emilianosolazzi/The-Pool/blob/main/docs/SPEC.md" target="_blank" rel="noopener noreferrer" className="btn-ghost">
            Protocol spec ↗
          </a>
        </div>

        {/* Compact risk row — replaces the long disclaimer paragraph */}
        <div className="mt-8 flex flex-wrap gap-2 text-xs">
          <span className="rounded-full border border-amber-500/30 bg-amber-500/10 px-3 py-1 text-amber-200">
            Fees only accrue on hooked swap flow that crosses the active range
          </span>
          <span className="rounded-full border border-amber-500/30 bg-amber-500/10 px-3 py-1 text-amber-200">
            Concentrated-LP exposure includes IL vs USDC
          </span>
          <span className="rounded-full border border-amber-500/30 bg-amber-500/10 px-3 py-1 text-amber-200">
            Range is owner-controlled · Safe-rebalanced
          </span>
          <span className="rounded-full border border-amber-500/30 bg-amber-500/10 px-3 py-1 text-amber-200">
            Bonus capped: $25K/wallet · $10K/epoch
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
