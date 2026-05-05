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
    'Deposit USDC, earn LP fees from real Uniswap v4 trading on Arbitrum One. Every hooked swap donates 80% of the fee back to LPs in the same transaction. The first $100K of TVL also captures 50% of the treasury stream for 180 days, paid in USDC. No emissions, no lockups.',
  openGraph: {
    title: 'The Pool — USDC yield from real Uniswap v4 swaps',
    description:
      'Deposit USDC. Every hooked swap donates 80% back to LPs. First $100K TVL captures 50% of the treasury stream for 180 days, paid in USDC.',
    type: 'website',
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
