import { shortAddress } from '@/lib/format';
import type { Deployment } from '@/lib/deployments';
import { arbitrumSepolia } from 'wagmi/chains';

const steps = [
  {
    n: '01',
    title: 'Swap triggers the hook',
    body: 'Swaps routed through the pool hook call DynamicFeeHookV2 — a 25 bps fee is computed from swap deltas and can scale 1.5× during volatile blocks.',
  },
  {
    n: '02',
    title: 'Fee is split and donated',
    body: 'FeeDistributor routes 20% to the treasury and 80% straight into poolManager.donate() — same tx, no escrow. Treasury share is owner-adjustable, hard-capped at 50%.',
  },
  {
    n: '03',
    title: 'Share price accrues',
    body: 'Per donation event, v4 credits each LP L_i / L(t_d), where L(t_d) is the active liquidity scalar on this exact PoolId (a snapshot, not a TWAP, not a global v4 sum). Yield is time-integrated exposure to those events, not a count of them. Share price = totalAssets()/totalSupply(); this vault uses discrete harvest — an implementation choice that excludes uncollected v4 fees from totalAssets() and imports them step-wise via collectYield() (permissionless) or any deposit/withdraw flush.',
  },
  {
    n: '04',
    title: 'Owner rebalances the range',
    body: 'Ticks are owner-adjustable without touching depositor accounting. Range shifts leave share price untouched.',
  },
];

export function HowItWorks({ deployment, chainId }: { deployment: Deployment; chainId: number }) {
  const isSepolia = chainId === arbitrumSepolia.id;
  const explorerBase = isSepolia ? 'https://sepolia.arbiscan.io' : 'https://arbiscan.io';

  const addrRow = (label: string, a?: string) => (
    <div className="flex items-center justify-between border-b border-white/5 px-4 py-3 text-sm last:border-0">
      <span className="text-zinc-400">{label}</span>
      {a ? (
        <a
          href={`${explorerBase}/address/${a}`}
          target="_blank"
          rel="noopener noreferrer"
          className="font-mono text-accent-400 hover:underline"
        >
          {shortAddress(a)}
        </a>
      ) : (
        <span className="font-mono text-zinc-600">not set</span>
      )}
    </div>
  );

  return (
    <section id="how" className="mx-auto max-w-6xl px-4 py-16">
      <div className="mb-10 flex items-end justify-between">
        <div>
          <h2 className="text-2xl font-semibold tracking-tight md:text-3xl">How it works</h2>
          <p className="mt-2 max-w-xl text-zinc-400">
            Four contracts, one transaction per swap. No off-chain keepers, no token.
          </p>
        </div>
      </div>
      <div className="grid gap-4 md:grid-cols-2 lg:grid-cols-4">
        {steps.map((s) => (
          <div key={s.n} className="card card-hover p-5">
            <div className="font-mono text-xs text-accent-400">{s.n}</div>
            <div className="mt-2 font-semibold text-white">{s.title}</div>
            <div className="mt-2 text-sm leading-relaxed text-zinc-400">{s.body}</div>
          </div>
        ))}
      </div>

      <div className="mt-10 grid gap-6 md:grid-cols-2">
        <div className="card">
          <div className="border-b border-white/5 px-4 py-3 text-xs uppercase tracking-widest text-zinc-500">
            Contracts · {isSepolia ? 'Arbitrum Sepolia' : 'Arbitrum One'}
          </div>
          {addrRow('LiquidityVaultV2', deployment.vault)}
          {addrRow('DynamicFeeHookV2', deployment.hook)}
          {addrRow('FeeDistributor', deployment.distributor)}
          {addrRow('BootstrapRewards', deployment.bootstrap)}
          {addrRow(`Asset (${deployment.assetSymbol})`, deployment.asset)}
        </div>
        <div className="card p-5 text-sm leading-relaxed text-zinc-400">
          <div className="text-white font-semibold">Single-sided by design</div>
          <p className="mt-2">
              You deposit {deployment.assetSymbol}. The vault works best when{' '}
              {deployment.pairSymbol} trades inside its selected range. If price is
              outside that range, some funds may wait in {deployment.assetSymbol}{' '}
              instead of being forced into a bad trade.
            </p>
            <p className="mt-3">
              A reserve keeper can help reduce idle time by offering unused reserves
              to swaps. Reserve quotes are{' '}
              <span className="text-zinc-200">posted by an allowlisted keeper</span>{' '}
              (Safe-managed) and gated on-chain by an AMM-spot price-improvement
              check before any fill — discretionary input, deterministic gate.
          </p>
          <p className="mt-3">
            <span className="text-white">Security</span> — anti-sandwich reference-price
            gating, two-step ownership handoff, ERC-4626 virtual-shares inflation
            mitigation, <code className="rounded bg-white/5 px-1 font-mono">SafeERC20</code>{' '}
            on every transfer.
          </p>
        </div>
      </div>

      <div className="mt-6 card p-5 text-sm leading-relaxed text-zinc-400">
        <div className="text-white font-semibold">Risks &amp; custody model</div>
        <ul className="mt-3 grid gap-2 md:grid-cols-2">
          <li>
            <span className="text-zinc-200">Impermanent loss.</span> Concentrated-LP
            exposure is not USDC-flat: when WETH price moves inside the range,
            the position rebalances against you relative to a USDC-only basis.
          </li>
          <li>
            <span className="text-zinc-200">Range-shift risk.</span>{' '}
            <code className="rounded bg-white/5 px-1 font-mono">rebalance()</code>{' '}
            is owner-only via the Safe. Frequency and tick choice can change
            fee capture timing; depositor accounting is unaffected.
          </li>
          <li>
            <span className="text-zinc-200">Pro-rata dilution.</span> The 80%
            donation is shared across <em>every</em> in-range LP. If third-party
            LPs join the same range, the vault&apos;s share of each donation
            falls accordingly.
          </li>
          <li>
            <span className="text-zinc-200">Bonus is conditional.</span> Epoch
            pool is funded only when treasury inflows arrive and{' '}
            <code className="rounded bg-white/5 px-1 font-mono">pullInflow()</code>{' '}
            is called. Caps and windows are on-chain; <em>funded</em> balance is
            shown live below.
          </li>
          <li>
            <span className="text-zinc-200">Reserve quote is discretionary.</span>{' '}
            Posted by an allowlisted keeper. Fills are still gated by an
            on-chain AMM-spot price-improvement check.
          </li>
          <li>
            <span className="text-zinc-200">Custody &amp; admin.</span>{' '}
            Vault is <code className="rounded bg-white/5 px-1 font-mono">Pausable</code>{' '}
            and owned by{' '}
            <code className="rounded bg-white/5 px-1 font-mono">VaultOwnerController</code>,
            which is owned by a Safe multisig. Hot keeper can only call typed
            reserve operations — no withdraw, no rebalance. Hook, vault, and
            distributor contracts are non-upgradeable; migration would require
            redeployment.
          </li>
        </ul>
      </div>
    </section>
  );
}
