# deploy-resume-ledger.ps1
# ─────────────────────────────────────────────────────────────────────────────
#  RESUME deploy on Arbitrum One via Ledger.
#
#  Phase C (already on mainnet — NOT touched by this script):
#    FeeDistributor          0x5757DA9014EE91055b244322a207EE6F066378B0
#    DynamicFeeHookV2        0x486579DE6391053Df88a073CeBd673dd545200cC
#    SwapRouter02ZapAdapter  0xdF9Ba20e7995A539Db9fB6DBCcbA3b54D026e393
#    distributor.setHook         (DONE)
#    distributor.setPoolKey      (DONE)
#    poolManager.initialize      (DONE)
#
#  This wrapper broadcasts ONLY the remaining deploy steps:
#    1. VaultMath  + VaultLP  (auto-deployed by forge as linked libraries)
#    2. LiquidityVaultV2 (linked)
#    3. vault.setPoolKey
#    4. vault.setInitialTicks
#    5. vault.setReserveHook
#    6. vault.refreshNavReference
#    7. hook.registerVault
#    8. VaultLens
#
#  After broadcast it parses broadcast-latest.json and runs
#  script/VerifyResumeDeploy.s.sol against the live RPC to assert all
#  post-deploy state.
# ─────────────────────────────────────────────────────────────────────────────

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── 0. Locate repo root ──────────────────────────────────────────────────────
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

# ── 1. Load .env ─────────────────────────────────────────────────────────────
$envFile = Join-Path $repoRoot ".env"
if (-not (Test-Path $envFile)) {
    Write-Error ".env not found at $envFile"
}

Get-Content $envFile |
    Where-Object { $_ -match "^\s*[^#\s]" -and $_ -match "=" } |
    ForEach-Object {
        $parts = $_ -split "=", 2
        $key   = $parts[0].Trim()
        $val   = $parts[1].Split("#")[0].Trim()
        [System.Environment]::SetEnvironmentVariable($key, $val, "Process")
    }

# ── 2. Hard-pin the already-deployed mainnet addresses ──────────────────────
#       These MUST match Phase C state on Arbitrum. Hard-coded here so a
#       fat-fingered .env override cannot redeploy by accident.
$EXPECTED_FEE_DISTRIBUTOR = "0x5757DA9014EE91055b244322a207EE6F066378B0"
$EXPECTED_HOOK_V2         = "0x486579DE6391053Df88a073CeBd673dd545200cC"
$EXPECTED_ZAP_ROUTER      = "0xdF9Ba20e7995A539Db9fB6DBCcbA3b54D026e393"

# Push them into the env DeployVaultResume.s.sol reads.
$env:FEE_DISTRIBUTOR = $EXPECTED_FEE_DISTRIBUTOR
$env:HOOK_V2         = $EXPECTED_HOOK_V2
$env:ZAP_ROUTER      = $EXPECTED_ZAP_ROUTER

# ── 3. Validate required env ────────────────────────────────────────────────
$required = @(
    "SENDER", "ARBITRUM_RPC_URL",
    "POOL_MANAGER", "POS_MANAGER",
    "TOKEN0", "TOKEN1", "ASSET_TOKEN", "PERMIT2",
    "POOL_FEE", "TICK_SPACING",
    "V2_TICK_LOWER", "V2_TICK_UPPER",
    "ETHERSCAN_API_KEY", "ETHERSCAN_VERIFIER_URL"
)
foreach ($var in $required) {
    $val = [System.Environment]::GetEnvironmentVariable($var, "Process")
    if (-not $val -or $val -match "YOUR_") {
        Write-Error "Missing or placeholder value for $var in .env"
    }
}

$sender = $env:SENDER
$rpc    = $env:ARBITRUM_RPC_URL
$esKey  = $env:ETHERSCAN_API_KEY
$esUrl  = $env:ETHERSCAN_VERIFIER_URL
$ledgerPath = "m/44'/60'/2'/0/0"

# ── 4. On-chain sanity: confirm the 3 addresses have code on the live RPC ───
Write-Host ""
Write-Host "Checking already-deployed contracts on-chain..." -ForegroundColor DarkGray
$preflightOk = $true
foreach ($pair in @(
    @{ Name = "FeeDistributor";         Addr = $EXPECTED_FEE_DISTRIBUTOR },
    @{ Name = "DynamicFeeHookV2";       Addr = $EXPECTED_HOOK_V2 },
    @{ Name = "SwapRouter02ZapAdapter"; Addr = $EXPECTED_ZAP_ROUTER }
)) {
    $code = & cast code $pair.Addr --rpc-url $rpc 2>$null
    if (-not $code -or $code -eq "0x") {
        Write-Host "  $($pair.Name) @ $($pair.Addr): NO CODE — wrong network or missing!" -ForegroundColor Red
        $preflightOk = $false
    } else {
        $bytes = ([Math]::Floor(($code.Length - 2) / 2))
        Write-Host ("  {0,-25} @ {1}  ({2} bytes runtime)" -f $pair.Name, $pair.Addr, $bytes) -ForegroundColor Green
    }
}
if (-not $preflightOk) {
    Write-Error "Pre-flight: at least one expected contract is missing on $rpc. Aborting."
}

# ── 5. Banner ───────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "==============================================================" -ForegroundColor Cyan
Write-Host "  The-Pool V2.1 — RESUME DEPLOY (Ledger)" -ForegroundColor Cyan
Write-Host "==============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "This resume deploy will NOT redeploy any of:" -ForegroundColor Yellow
Write-Host "  - FeeDistributor" -ForegroundColor Yellow
Write-Host "  - DynamicFeeHookV2" -ForegroundColor Yellow
Write-Host "  - SwapRouter02ZapAdapter" -ForegroundColor Yellow
Write-Host "  - distributor.setHook / distributor.setPoolKey" -ForegroundColor Yellow
Write-Host "  - poolManager.initialize" -ForegroundColor Yellow
Write-Host ""
Write-Host "Already-deployed (verified on-chain above):"
Write-Host "  FEE_DISTRIBUTOR : $EXPECTED_FEE_DISTRIBUTOR"
Write-Host "  HOOK_V2         : $EXPECTED_HOOK_V2"
Write-Host "  ZAP_ROUTER      : $EXPECTED_ZAP_ROUTER"
Write-Host ""
Write-Host "Pool config (read from .env):"
Write-Host "  POOL_MANAGER   : $($env:POOL_MANAGER)"
Write-Host "  POS_MANAGER    : $($env:POS_MANAGER)"
Write-Host "  PERMIT2        : $($env:PERMIT2)"
Write-Host "  TOKEN0 (WETH)  : $($env:TOKEN0)"
Write-Host "  TOKEN1 (USDC)  : $($env:TOKEN1)"
Write-Host "  ASSET_TOKEN    : $($env:ASSET_TOKEN)"
Write-Host "  POOL_FEE       : $($env:POOL_FEE)"
Write-Host "  TICK_SPACING   : $($env:TICK_SPACING)"
Write-Host "  V2_TICK_LOWER  : $($env:V2_TICK_LOWER)"
Write-Host "  V2_TICK_UPPER  : $($env:V2_TICK_UPPER)"
Write-Host ""
Write-Host "Ledger:"
Write-Host "  Sender         : $sender"
Write-Host "  Derivation path: $ledgerPath"
Write-Host ""
Write-Host "Ledger will prompt you to sign these txs in order:" -ForegroundColor Yellow
Write-Host "  1. VaultMath (library, auto)"
Write-Host "  2. VaultLP   (library, auto)"
Write-Host "  3. LiquidityVaultV2 (linked)"
Write-Host "  4. vault.setPoolKey"
Write-Host "  5. vault.setInitialTicks"
Write-Host "  6. vault.setReserveHook"
Write-Host "  7. vault.refreshNavReference"
Write-Host "  8. hook.registerVault"
Write-Host "  9. VaultLens"
Write-Host ""

# ── 6. Explicit YES gate ────────────────────────────────────────────────────
$confirm = Read-Host "Type YES (uppercase) to broadcast"
if ($confirm -ne "YES") {
    Write-Host "Aborted." -ForegroundColor Red
    exit 1
}

# ── 7. Broadcast ────────────────────────────────────────────────────────────
$forgeArgs = @(
    "script", "script/DeployVaultResume.s.sol",
    "--rpc-url", $rpc,
    "--ledger",
    "--mnemonic-derivation-paths", $ledgerPath,
    "--sender", $sender,
    "--broadcast",
    "--verify",
    "--etherscan-api-key", $esKey,
    "--verifier-url", $esUrl,
    "--slow"
)

Write-Host ""
Write-Host "Running: forge $($forgeArgs -join ' ')" -ForegroundColor DarkGray
Write-Host ""

& forge @forgeArgs
if ($LASTEXITCODE -ne 0) {
    Write-Error "forge script failed (exit $LASTEXITCODE). Check output above."
}

# ── 8. Parse broadcast log ──────────────────────────────────────────────────
# Arbitrum One chainid = 42161
$bcastJson = Join-Path $repoRoot "broadcast/DeployVaultResume.s.sol/42161/run-latest.json"
if (-not (Test-Path $bcastJson)) {
    Write-Error "Broadcast JSON not found at $bcastJson. Cannot extract addresses."
}

$bcast = Get-Content $bcastJson -Raw | ConvertFrom-Json

$created = @{}
foreach ($tx in $bcast.transactions) {
    if ($tx.contractName -and $tx.contractAddress) {
        if (-not $created.ContainsKey($tx.contractName)) {
            $created[$tx.contractName] = @()
        }
        $created[$tx.contractName] += $tx.contractAddress
    }
}

# Library deployments by forge appear under separate libraries[] section.
$libraries = @{}
if ($bcast.PSObject.Properties.Name -contains "libraries") {
    foreach ($lib in $bcast.libraries) {
        # Format: "src/libraries/VaultMath.sol:VaultMath:0x...."
        $parts = $lib -split ":"
        if ($parts.Count -ge 3) {
            $libraries[$parts[1]] = $parts[2]
        }
    }
}

# Fall back: look at receipts for CREATE-only txs (libraries) when libraries[] empty.
$vaultAddr = $null
if ($created.ContainsKey("LiquidityVaultV2")) { $vaultAddr = $created["LiquidityVaultV2"][0] }
$lensAddr  = $null
if ($created.ContainsKey("VaultLens"))        { $lensAddr  = $created["VaultLens"][0] }
$mathAddr  = $libraries["VaultMath"]
$lpAddr    = $libraries["VaultLP"]

# If libraries[] was empty, walk transactions: contractName==null && to==null are
# library creates ordered before LiquidityVaultV2.
if (-not $mathAddr -or -not $lpAddr) {
    $libCreates = @()
    foreach ($tx in $bcast.transactions) {
        if (-not $tx.to -and -not $tx.contractName -and $tx.contractAddress) {
            $libCreates += $tx.contractAddress
        }
        if ($tx.contractName -eq "LiquidityVaultV2") { break }
    }
    if ($libCreates.Count -ge 2) {
        if (-not $mathAddr) { $mathAddr = $libCreates[0] }
        if (-not $lpAddr)   { $lpAddr   = $libCreates[1] }
    }
}

Write-Host ""
Write-Host "==============================================================" -ForegroundColor Green
Write-Host "  Broadcast complete" -ForegroundColor Green
Write-Host "==============================================================" -ForegroundColor Green
Write-Host ""
Write-Host "Deployed addresses:"
Write-Host "  VaultMath        : $mathAddr"
Write-Host "  VaultLP          : $lpAddr"
Write-Host "  LiquidityVaultV2 : $vaultAddr"
Write-Host "  VaultLens        : $lensAddr"
Write-Host ""
Write-Host "Tx hashes:"
foreach ($tx in $bcast.transactions) {
    $name = if ($tx.contractName) { $tx.contractName } else { "call" }
    $hash = if ($tx.hash) { $tx.hash } else { "(unknown)" }
    Write-Host ("  {0,-22} {1}" -f $name, $hash)
}
Write-Host ""
Write-Host "Broadcast JSON: $bcastJson"
Write-Host ""

if (-not $vaultAddr -or -not $lensAddr) {
    Write-Error "Could not parse vault/lens address from broadcast JSON. Skipping post-deploy verify."
}

# ── 9. Post-deploy on-chain verification ────────────────────────────────────
Write-Host ""
Write-Host "==============================================================" -ForegroundColor Cyan
Write-Host "  Post-deploy verification" -ForegroundColor Cyan
Write-Host "==============================================================" -ForegroundColor Cyan
Write-Host ""

$env:VAULT_ADDRESS = $vaultAddr
$env:LENS_ADDRESS  = $lensAddr

$verifyArgs = @(
    "script", "script/VerifyResumeDeploy.s.sol",
    "--rpc-url", $rpc
)
& forge @verifyArgs
if ($LASTEXITCODE -ne 0) {
    Write-Error "Post-deploy verify FAILED. State on-chain is suspect — investigate immediately."
}

Write-Host ""
Write-Host "==============================================================" -ForegroundColor Green
Write-Host "  RESUME DEPLOY COMPLETE — all post-deploy checks passed" -ForegroundColor Green
Write-Host "==============================================================" -ForegroundColor Green
Write-Host ""
Write-Host "Next steps:"
Write-Host "  1. Update web/.env.local: NEXT_PUBLIC_VAULT_ARB_ONE=$vaultAddr"
Write-Host "  2. Update Vercel Production env, redeploy site."
Write-Host "  3. Save addresses for record:"
Write-Host "       VaultMath        = $mathAddr"
Write-Host "       VaultLP          = $lpAddr"
Write-Host "       LiquidityVaultV2 = $vaultAddr"
Write-Host "       VaultLens        = $lensAddr"
Write-Host ""
