# Vendored dependency provenance

The contracts in `src/` build against six upstream Solidity libraries that
are vendored directly into this repository under `lib/` (no git submodules
— see the absence of a `.gitmodules` at the repo root). This file records
the upstream identity of each vendored copy so an auditor or downstream
integrator can diff against the canonical upstream tag.

## Top-level vendored libraries

| Path | Upstream | Vendored version (`package.json`) | Upstream tag / SHA |
|------|----------|-----------------------------------|--------------------|
| `lib/forge-std` | https://github.com/foundry-rs/forge-std | `1.15.0` | `v1.15.0` → `0844d7e1fc5e60d77b68e469bff60265f236c398` |
| `lib/openzeppelin-contracts` | https://github.com/OpenZeppelin/openzeppelin-contracts | `5.6.1` | `v5.6.1` → `5fd1781b1454fd1ef8e722282f86f9293cacf256` |
| `lib/v4-core` | https://github.com/Uniswap/v4-core | `1.0.2` | TO-PIN — see *Resolution failures* below |
| `lib/v4-periphery` | https://github.com/Uniswap/v4-periphery | `1.0.4` | TO-PIN — see *Resolution failures* below |

## Transitive vendored libraries

These are nested under `v4-core/lib` or `v4-periphery/lib` and are
referenced by [`remappings.txt`](../remappings.txt):

| Path | Upstream | Vendored version (`package.json`) | Upstream tag / SHA |
|------|----------|-----------------------------------|--------------------|
| `lib/v4-core/lib/solmate` | https://github.com/transmissions11/solmate | `6.2.0` | TO-PIN — see *Resolution failures* below |
| `lib/v4-periphery/lib/permit2` | https://github.com/Uniswap/permit2 | `1.0.0` | TO-PIN — see *Resolution failures* below |

## Active remappings

From [`remappings.txt`](../remappings.txt):

```
@openzeppelin/=lib/openzeppelin-contracts/
@uniswap/v4-core/=lib/v4-core/
@uniswap/v4-periphery/=lib/v4-periphery/
forge-std/=lib/forge-std/src/
permit2/=lib/v4-periphery/lib/permit2/
solmate/=lib/v4-core/lib/solmate/
v4-core-test/=lib/v4-core/test/
```

## Methodology + caveats

- Versions in the table are read from each library's own `package.json`
  at the time of this re-test (`06dfe92`, 2026-04-27).
- SHA pinning was done by `git ls-remote --tags <upstream>` against the
  canonical GitHub remote and matching against the npm version recorded
  in the vendored `package.json`. SHAs in the tables above are the
  lightweight-tag commits (no annotated-tag indirection was needed).
- The vendored copies were imported without their `.git` directories,
  so a strict byte-for-byte equality with the upstream tag commit is
  asserted by this manifest but not verified locally. An operator can
  finalize verification by `git diff <tag> -- <vendored-path>`.
- This repository is not a Foundry submodule consumer, so updates to
  vendored libraries are intentionally manual: bumping a version
  requires re-vendoring the tree and updating this file in the same
  commit.

## Resolution failures

The following four libraries did **not** resolve cleanly to a single
upstream tag matching the vendored `package.json` version, and are
left `TO-PIN` rather than guessed:

- **`Uniswap/v4-core` @ npm `1.0.2`.** The remote exposes exactly one
  release tag, `v4.0.0`
  (`e50237c43811bd9b526eff40f26772152a42daba`), and many topic branches
  (`0.8.27`, `6909`, `audit/spearbit`, etc.). No `v1.0.2`, `1.0.2`, or
  equivalent tag exists. Pinning requires a side-channel attestation
  from Uniswap (npm provenance metadata, release notes, or
  point-in-time HEAD of the publication branch).
- **`Uniswap/v4-periphery` @ npm `1.0.4`.** `git ls-remote --tags`
  returns no tags at all; only branches. Same remediation as v4-core.
- **`transmissions11/solmate` @ npm `6.2.0`.** Only a single coarse
  tag `v6`
  (`a9e3ea26a2dc73bfa87f0cb189687d029028e0c5`) exists. No `v6.2.0` tag.
  Pinning requires the npm registry's published `gitHead` field for
  `solmate@6.2.0` (`npm view solmate@6.2.0 gitHead`).
- **`Uniswap/permit2` @ npm `1.0.0`.** The only tag in the remote is
  the deployment-address marker
  `0x000000000022D473030F116dDEE9F6B43aC78BA3`
  (`cc306b601f172c51bc04334a109e98340456620b`). No `v1.0.0` tag.
  Pinning requires the npm registry's published `gitHead` for
  `@uniswap/permit2@1.0.0`.

When finalising any of the four, replace the corresponding `TO-PIN`
row with the resolved commit SHA and source of attestation, and update
this section to remove the entry.

## Local modifications

A full byte-for-byte diff against upstream tags has not been performed
in this re-test (it requires the SHAs in the table above to be pinned
first). The project-owned helpers under
[`src/libraries/`](../src/libraries/) — `LiquidityAmounts.sol` and
`CurrencySettler.sol` — are intentionally maintained at the application
layer rather than under `lib/`, so contract storage and ABI are not
coupled to upstream library reorganisations.

If a local patch is ever applied to a vendored file, record it in this
section with the file path, upstream commit, and a short rationale.
