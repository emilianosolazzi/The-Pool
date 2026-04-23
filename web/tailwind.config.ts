import type { Config } from 'tailwindcss';

const config: Config = {
  content: [
    './app/**/*.{ts,tsx}',
    './components/**/*.{ts,tsx}',
  ],
  theme: {
    extend: {
      fontFamily: {
        sans: ['var(--font-sans)', 'ui-sans-serif', 'system-ui'],
        mono: ['var(--font-mono)', 'ui-monospace', 'SFMono-Regular'],
      },
      colors: {
        ink: {
          950: '#0b0420',
          900: '#130630',
          800: '#1b0a42',
          700: '#241056',
          600: '#2e166a',
        },
        accent: {
          300: '#ff8dd0',
          400: '#ff5cb8',
          500: '#ff2a9e',   // primary magenta (Uniswap-ish)
          600: '#e61a8a',
          700: '#bb1471',
        },
        iris: {
          400: '#a78bfa',
          500: '#8b5cf6',   // purple accent
          600: '#7c3aed',
        },
      },
      backgroundImage: {
        'grid-fade':
          'radial-gradient(ellipse 80% 50% at 50% -20%, rgba(255,42,158,0.28), transparent 60%), radial-gradient(ellipse 60% 50% at 85% 10%, rgba(139,92,246,0.25), transparent 60%)',
        'hero-mesh':
          'radial-gradient(1200px 600px at 15% -10%, rgba(255,42,158,0.35), transparent 55%), radial-gradient(900px 500px at 90% 10%, rgba(139,92,246,0.32), transparent 60%), radial-gradient(700px 400px at 50% 110%, rgba(88,28,135,0.45), transparent 60%)',
      },
      boxShadow: {
        glow: '0 0 80px -20px rgba(255,42,158,0.55)',
        'glow-iris': '0 0 80px -20px rgba(139,92,246,0.5)',
      },
    },
  },
  plugins: [],
};

export default config;
