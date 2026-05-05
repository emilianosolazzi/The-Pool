import type { Metadata } from 'next';
import { Inter, JetBrains_Mono } from 'next/font/google';
import './globals.css';
import '@rainbow-me/rainbowkit/styles.css';
import { Providers } from './providers';

const inter = Inter({
  subsets: ['latin'],
  variable: '--font-sans',
  display: 'swap',
});

const jetbrains = JetBrains_Mono({
  subsets: ['latin'],
  variable: '--font-mono',
  display: 'swap',
});

export const metadata: Metadata = {
  title: 'The Pool — USDC yield from real Uniswap v4 swaps',
  description:
    'Deposit USDC, earn LP fees from real Uniswap v4 trading on Arbitrum One. Each hooked swap routes 80% of the fee into poolManager.donate(); vault depositors capture that pro-rata to vault liquidity within the active in-range LP set. Optional 180-day early-depositor bonus program funded from treasury inflows. No emissions, no lockups.',
  openGraph: {
    title: 'The Pool — USDC yield from real Uniswap v4 swaps',
    description:
      'Deposit USDC. Hooked swaps donate 80% of the fee pro-rata to in-range LPs. Optional 180-day early-depositor bonus program, capped and scheduled.',
    type: 'website',
  },
  twitter: {
    card: 'summary_large_image',
    title: 'The Pool — USDC yield from real Uniswap v4 swaps',
    description:
      'Deposit USDC. Hooked swaps donate 80% of the fee pro-rata to in-range LPs. Optional 180-day early-depositor bonus program.',
  },
  icons: { icon: '/favicon.svg' },
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" className={`${inter.variable} ${jetbrains.variable}`} suppressHydrationWarning>
      <body className="font-sans antialiased overflow-x-hidden">
        <Providers>{children}</Providers>
      </body>
    </html>
  );
}
