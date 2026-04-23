'use client';

import { ConnectButton } from '@rainbow-me/rainbowkit';

export function Nav() {
  return (
    <header className="sticky top-0 z-40 border-b border-white/5 bg-ink-950/60 backdrop-blur-xl">
      <div className="mx-auto flex h-16 max-w-6xl items-center justify-between px-4">
        <a href="/" className="flex items-center gap-2">
          <div className="flex h-8 w-8 items-center justify-center rounded-lg bg-gradient-to-br from-accent-500 to-iris-500 text-white font-black shadow-glow">
            P
          </div>
          <span className="font-semibold tracking-tight">The&nbsp;Pool</span>
          <span className="chip ml-2 hidden sm:inline-flex">Uniswap v4 hook</span>
        </a>
        <nav className="hidden items-center gap-6 text-sm text-zinc-300 md:flex">
          <a href="#how" className="hover:text-white">How it works</a>
          <a href="#vault" className="hover:text-white">Vault</a>
          <a
            href="https://github.com/emilianosolazzi/The-Pool"
            target="_blank"
            rel="noopener noreferrer"
            className="hover:text-white"
          >
            GitHub
          </a>
        </nav>
        <ConnectButton
          chainStatus="icon"
          showBalance={false}
          accountStatus={{ smallScreen: 'avatar', largeScreen: 'full' }}
        />
      </div>
    </header>
  );
}
