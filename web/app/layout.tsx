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
  title: 'The Pool — Auto-compounding Uniswap v4 LP yield',
  description:
    'Fee-only, auto-compounding LP yield on Uniswap v4. 25 bps dynamic hook fee, 80% donated back to the pool on every swap. No token, no emissions, no lockups.',
  openGraph: {
    title: 'The Pool',
    description:
      'Fee-only, auto-compounding LP yield on Uniswap v4. 25 bps dynamic hook fee, 80% donated back to the pool on every swap.',
    type: 'website',
  },
  icons: { icon: '/favicon.svg' },
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" className={`${inter.variable} ${jetbrains.variable}`} suppressHydrationWarning>
      <body className="font-sans antialiased">
        <Providers>{children}</Providers>
      </body>
    </html>
  );
}
