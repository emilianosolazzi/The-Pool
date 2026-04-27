# Vendored dependency provenance

The contracts in `src/` build against six upstream Solidity libraries that
are vendored directly into this repository under `lib/` (no git submodules
— see the absence of a `.gitmodules` at the repo root). This file records
the upstream identity of each vendored copy so an auditor or downstream
integrator can diff against the canonical upstream tag.

## Top-level vendored libraries

| Path | Upstream | Vendored version (`package.json`) | Upstream SHA |
|------|----------|-----------------------------------|--------------|
| `lib/forge-std` | https://github.com/foundry-rs/forge-std | `1.15.0` | TO-PIN |
| `lib/openzeppelin-contracts` | https://github.com/OpenZeppelin/openzeppelin-contracts | `5.6.1` | TO-PIN |
| `lib/v4-core` | https://github.com/Uniswap/v4-core | `1.0.2` | TO-PIN |
| `lib/v4-periphery` | https://github.com/Uniswap/v4-periphery | `1.0.4` | TO-PIN |

## Transitive vendored libraries

These are nested under `v4-core/lib` or `v4-periphery/lib` and are
referenced by [`remappings.txt`](../remappings.txt):

| Path | Upstream | Vendored version (`package.json`) | Upstream SHA |
|------|----------|-----------------------------------|--------------|
| `lib/v4-core/lib/solmate` | https://github.com/transmissions11/solmate | `6.2.0` | TO-PIN |
| `lib/v4-periphery/lib/permit2` | https://github.com/Uniswap/permit2 | `1.0.0` | TO-PIN |

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
  at the time of this re-test (`8c962fa`, 2026-04-27).
- SHA columns are marked `TO-PIN` because the vendored copies were
  imported without their `.git` directories, so the in-tree commit
  cannot be derived locally. To finalize provenance an operator with
  network access must:
  1. `git ls-remote --tags <upstream>` to locate the tag matching the
     vendored version (e.g. `v1.0.2` for v4-core).
  2. `git rev-parse <tag>^{}` to dereference the tag to its commit SHA.
  3. Spot-check by `git diff <tag> -- <vendored-path>` to confirm no
     local edits beyond the documented ones.
- This repository is not a Foundry submodule consumer, so updates to
  vendored libraries are intentionally manual: bumping a version
  requires re-vendoring the tree and updating this file in the same
  commit.

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
