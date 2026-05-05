import { ImageResponse } from 'next/og';

export const runtime = 'edge';
export const alt = 'The Pool — USDC yield from real Uniswap v4 swaps';
export const size = { width: 1200, height: 630 };
export const contentType = 'image/png';

export default function Image() {
  return new ImageResponse(
    (
      <div
        style={{
          width: '100%',
          height: '100%',
          display: 'flex',
          flexDirection: 'column',
          justifyContent: 'space-between',
          padding: '72px 80px',
          background:
            'radial-gradient(circle at 20% 20%, #2a103f 0%, #0a0a0f 55%), linear-gradient(135deg, #0a0a0f 0%, #110720 100%)',
          color: 'white',
          fontFamily: 'sans-serif',
        }}
      >
        <div style={{ display: 'flex', alignItems: 'center', gap: 16 }}>
          <div
            style={{
              width: 14,
              height: 14,
              borderRadius: 999,
              background: '#34d399',
              boxShadow: '0 0 24px #34d399',
            }}
          />
          <div
            style={{
              fontSize: 22,
              letterSpacing: 6,
              textTransform: 'uppercase',
              color: '#a1a1aa',
            }}
          >
            Live on Arbitrum One · Uniswap v4 hook
          </div>
        </div>

        <div style={{ display: 'flex', flexDirection: 'column', gap: 24 }}>
          <div
            style={{
              fontSize: 84,
              lineHeight: 1.05,
              fontWeight: 600,
              letterSpacing: -1.5,
              maxWidth: 1040,
            }}
          >
            Earn USDC yield from real{' '}
            <span
              style={{
                background:
                  'linear-gradient(90deg, #ff5cb8 0%, #a855f7 50%, #6366f1 100%)',
                backgroundClip: 'text',
                color: 'transparent',
              }}
            >
              Uniswap v4 trading activity
            </span>
            .
          </div>
          <div style={{ fontSize: 30, color: '#d4d4d8', maxWidth: 980 }}>
            Every hooked swap donates 80% back to LPs. First $100K TVL captures 50%
            of the treasury stream for 180 days, paid in USDC.
          </div>
        </div>

        <div
          style={{
            display: 'flex',
            justifyContent: 'space-between',
            alignItems: 'center',
            fontSize: 22,
            color: '#a1a1aa',
          }}
        >
          <div style={{ display: 'flex', gap: 28 }}>
            <span>ERC-4626 vault</span>
            <span>·</span>
            <span>No emissions</span>
            <span>·</span>
            <span>No lockups</span>
          </div>
          <div style={{ fontWeight: 600, color: '#fafafa' }}>thepool.fi</div>
        </div>
      </div>
    ),
    { ...size },
  );
}
