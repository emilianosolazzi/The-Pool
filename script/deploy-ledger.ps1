# deploy-ledger.ps1
# ─────────────────────────────────────────────────────────────────────────────
#  Full V2.1 fresh deploy on Arbitrum One via Ledger.
#  Deploys: FeeDistributor + DynamicFeeHookV2 + SwapRouter02ZapAdapter +
#           LiquidityVaultV2  (and initialises the V2 pool).
#  Old V1 hook + old vault are abandoned in place; nothing is migrated.
#
#  Prerequisites:
#    1. Ledger plugged in, Ethereum app open, blind signing enabled.
#    2. .env populated (already filled). INIT_SQRT_PRICE_X96 must reflect
#       a recent on-chain price (refresh from V3 0.05% pool slot0 if stale).
#    3. ~0.005 ETH on Arbitrum One for gas.
#    4. Run from the repo root:  .\script\deploy-ledger.ps1
#
#  After a successful run, copy the printed addresses into:
#    web/.env.local  (NEXT_PUBLIC_VAULT_ARB_ONE, _HOOK_, _DISTRIBUTOR_)
#    Vercel Production env vars + redeploy.
#  Then run DeployBootstrap.s.sol in a separate Ledger session.
# ─────────────────────────────────────────────────────────────────────────────

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── 0. Locate repo root ──────────────────────────────────────────────────────
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

# ── 1. Load .env ─────────────────────────────────────────────────────────────
$envFile = Join-Path $repoRoot ".env"
if (-not (Test-Path $envFile)) {
    Write-Error ".env not found. Run:  cp .env.example .env  then fill in SENDER and TREASURY."
}

Get-Content $envFile |
    Where-Object { $_ -match "^\s*[^#\s]" -and $_ -match "=" } |
    ForEach-Object {
        $parts = $_ -split "=", 2
        $key   = $parts[0].Trim()
        $val   = $parts[1].Split("#")[0].Trim()
        [System.Environment]::SetEnvironmentVariable($key, $val, "Process")
    }

# ── 2. Validate required variables ───────────────────────────────────────────
$required = @("SENDER", "TREASURY", "POOL_MANAGER", "POS_MANAGER",
              "TOKEN0", "TOKEN1", "ASSET_TOKEN", "PERMIT2",
              "POOL_FEE", "TICK_SPACING", "INIT_SQRT_PRICE_X96",
              "V2_TICK_LOWER", "V2_TICK_UPPER", "SWAP_ROUTER_02",
              "ARBITRUM_RPC_URL",
              "ETHERSCAN_API_KEY", "ETHERSCAN_VERIFIER_URL")

foreach ($var in $required) {
    $val = [System.Environment]::GetEnvironmentVariable($var, "Process")
    if (-not $val -or $val -match "YOUR_") {
        Write-Error "Missing or placeholder value for $var in .env — please fill it in."
    }
}

$sender   = $env:SENDER
$rpc      = $env:ARBITRUM_RPC_URL
$esKey    = $env:ETHERSCAN_API_KEY
$esUrl    = $env:ETHERSCAN_VERIFIER_URL

Write-Host ""
Write-Host "=== The-Pool V2.1 — FULL FRESH DEPLOY to Arbitrum One (Ledger) ===" -ForegroundColor Cyan
Write-Host "Sender (Ledger) : $sender"
Write-Host "Treasury        : $($env:TREASURY)"
Write-Host "PoolManager     : $($env:POOL_MANAGER)"
Write-Host "PositionManager : $($env:POS_MANAGER)"
Write-Host "TOKEN0 (WETH)   : $($env:TOKEN0)"
Write-Host "TOKEN1 (USDC)   : $($env:TOKEN1)"
Write-Host "ASSET_TOKEN     : $($env:ASSET_TOKEN)"
Write-Host "INIT sqrtPx96   : $($env:INIT_SQRT_PRICE_X96)"
Write-Host "V2 tick range   : $($env:V2_TICK_LOWER) .. $($env:V2_TICK_UPPER)"
Write-Host ""
Write-Host "Ledger will prompt you to sign these transactions in order:" -ForegroundColor Yellow
Write-Host "  1. FeeDistributor             (new)"
Write-Host "  2. DynamicFeeHookV2 (CREATE2)  (new, salt-mined)"
Write-Host "  3. distributor.setHook         (wire)"
Write-Host "  4. poolManager.initialize      (open V2 pool)"
Write-Host "  5. distributor.setPoolKey      (wire)"
Write-Host "  6. SwapRouter02ZapAdapter      (zap helper)"
Write-Host "  7. LiquidityVaultV2            (new)"
Write-Host "  8. vault.setPoolKey + rebalance + setReserveHook + setTreasury (+ optional perf/maxTVL)"
Write-Host "  9. hook.registerVault          (one-shot bind)"
Write-Host ""
Write-Host "Old contracts (V1 hook, old vault) are abandoned in place. NOT touched." -ForegroundColor DarkGray
Write-Host "Bootstrap is deployed separately AFTER this completes (DeployBootstrap.s.sol)." -ForegroundColor DarkGray
Write-Host ""
Write-Host "Press Enter to continue or Ctrl+C to abort."
Read-Host | Out-Null

# ── 3. Run forge script ───────────────────────────────────────────────────────
#    --ledger            : use Ledger hardware wallet (no private key)
#    --sender            : tell forge which address the Ledger holds
#    --broadcast         : submit signed txs to the network
#    --verify            : verify contracts on Arbiscan after deploy
#    --slow              : wait for each tx to confirm before the next
#                          (important for Ledger — avoids nonce collisions)

$forgeArgs = @(
    "script", "script/DeployHookV2AndVault.s.sol",
    "--rpc-url", $rpc,
    "--ledger",
    # Derivation path for SENDER (0xe5f5Ef79...). Foundry's default
    # m/44'/60'/0'/0/0 maps to a different account on this device.
    "--mnemonic-derivation-paths", "m/44'/60'/2'/0/0",
    "--sender", $sender,
    "--broadcast",
    "--verify",
    "--etherscan-api-key", $esKey,
    "--verifier-url", $esUrl,
    "--slow",
    # DynamicFeeHookV2 runtime bytecode is ~29 KB. Forge defaults to EIP-170
    # (24 KB) and will abort the broadcast otherwise. Arbitrum One accepts
    # the larger size (verified on V1 deploy).
    "--disable-code-size-limit"
)

Write-Host ""
Write-Host "Running: forge $($forgeArgs -join ' ')" -ForegroundColor DarkGray
Write-Host ""

& forge @forgeArgs

if ($LASTEXITCODE -ne 0) {
    Write-Error "forge script failed (exit $LASTEXITCODE). Check output above."
}

# ── 4. Print next steps ───────────────────────────────────────────────────────
Write-Host ""
Write-Host "=== Deployment complete! ===" -ForegroundColor Green
Write-Host ""
Write-Host "Next steps:"
Write-Host "  1. Copy the LiquidityVaultV2 address from the 'Deployment Summary' above."
Write-Host ""
Write-Host "  2. Update web/.env.local:"
Write-Host "       NEXT_PUBLIC_VAULT_ARB_ONE=<LiquidityVaultV2 address>"
Write-Host "     (HOOK and DISTRIBUTOR addresses are unchanged — vault-only redeploy.)"
Write-Host ""
Write-Host "  3. Update the same var on Vercel (Production) and redeploy the site."
Write-Host ""
Write-Host "  4. (Later) Transfer ownership to your Safe via Ownable2Step:"
Write-Host "       vault.transferOwnership(safe)  -> safe.acceptOwnership()"
Write-Host ""