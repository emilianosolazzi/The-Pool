# ============================================================================
# Fork E2E driver — Arbitrum One @ latest block.
# Assumes anvil is already running on http://127.0.0.1:8545 with a fork:
#
#   anvil --fork-url $env:ARBITRUM_RPC_URL --auto-impersonate --chain-id 42161
#
# Steps:
#   - fund test wallet with 1000 USDC via whale impersonation
#   - impersonate vault Ledger owner
#   - run ForkE2E.s.sol (deposit -> lens asserts -> UR USDC->WETH ->
#     hook asserts -> VAULT_SPREAD offer -> WETH->USDC reserve fill)
# ============================================================================
$ErrorActionPreference = "Stop"
$RPC = "http://127.0.0.1:8545"

# --- canonical addresses ------------------------------------------------------
$VAULT     = "0xf79c2dc829cd3a2d8ceec353bdb1b2414ba1eee0"
$LENS      = "0x12e86890b75fdee22a35be66550373936d883551"
$HOOK      = "0x486579DE6391053Df88a073CeBd673dd545200cC"
$POOL_MGR  = "0x360e68faccca8ca495c1b759fd9eee466db9fb32"
$QUOTER    = "0x3972c00f7ed4885e145823eb7c655375d275a1c5"
$UR        = "0xa51afafe0263b40edaef0df8781ea9aa03e381a3"
$PERMIT2   = "0x000000000022D473030F116dDEE9F6B43aC78BA3"
$USDC      = "0xaf88d065e77c8cC2239327C5EDb3A432268e5831"
$WETH      = "0x82aF49447D8a07e3bd95BD0d56f35241523fBab1"
$LEDGER    = "0xe5f5Ef79b3DFF47EcDf7842645222e43AD0ed080"   # vault.owner()

# anvil PK #0
$DEPOSITOR    = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
$DEPOSITOR_PK = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"

# --- 0. sanity: anvil reachable ----------------------------------------------
"== anvil sanity =="
$block = (& cast block-number --rpc-url $RPC) 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Error "Cannot reach anvil at $RPC. Start it with: anvil --fork-url `$env:ARBITRUM_RPC_URL --auto-impersonate"
}
"forked block: $block"

# --- 1. fund test wallet with 1000 USDC via whale impersonation --------------
"`n== STEP 1: fund depositor with 1000 USDC =="
$balRaw = (& cast call $USDC "balanceOf(address)(uint256)" $DEPOSITOR --rpc-url $RPC) -join " "
$bal0 = [bigint]::Parse(($balRaw -split " ")[0])
"depositor USDC pre: $bal0"

if ($bal0 -lt 1000000000) {
    # 1000 USDC = 1000 * 1e6 = 1_000_000_000
    $candidates = @(
        "0x489ee077994b6658eafa855c308275ead8097c4a",  # GMX V1 vault
        "0x47c031236e19d024b42f8AE6780E44A573170703",  # GMX V2 market
        "0x724dc807b04555b71ed48a6896b6F41593b8C637",  # Aave aArbUSDCn
        "0xB38e8c17e38363aF6EbdCb3dAE12e0243582891D"
    )
    $whale = $null
    foreach ($w in $candidates) {
        $r = (& cast call $USDC "balanceOf(address)(uint256)" $w --rpc-url $RPC) -join " "
        $b = [bigint]::Parse(($r -split " ")[0])
        "  candidate $w bal=$b"
        if ($b -ge 1000000000) { $whale = $w; break }
    }
    if (-not $whale) { Write-Error "no whale with >=1000 USDC found" }
    "  using whale: $whale"

    & cast rpc --rpc-url $RPC anvil_setBalance $whale "0xDE0B6B3A7640000" | Out-Null
    & cast rpc --rpc-url $RPC anvil_impersonateAccount $whale | Out-Null
    & cast send $USDC "transfer(address,uint256)" $DEPOSITOR "1000000000" `
        --from $whale --rpc-url $RPC --unlocked | Out-Null
    & cast rpc --rpc-url $RPC anvil_stopImpersonatingAccount $whale | Out-Null
}

$balRaw = (& cast call $USDC "balanceOf(address)(uint256)" $DEPOSITOR --rpc-url $RPC) -join " "
$bal1 = [bigint]::Parse(($balRaw -split " ")[0])
"depositor USDC post: $bal1"
if ($bal1 -lt 1000000000) { Write-Error "funding failed" }

# --- 2. impersonate Ledger so vm.startBroadcast(LEDGER) works in the script --
"`n== STEP 2: impersonate Ledger vault owner =="
& cast rpc --rpc-url $RPC anvil_setBalance $LEDGER "0xDE0B6B3A7640000" | Out-Null
& cast rpc --rpc-url $RPC anvil_impersonateAccount $LEDGER | Out-Null
"impersonated $LEDGER"

# --- 3. export env for forge script ------------------------------------------
$env:FORK_DEPOSITOR    = $DEPOSITOR
$env:FORK_DEPOSITOR_PK = $DEPOSITOR_PK
$env:VAULT_OWNER       = $LEDGER
$env:VAULT             = $VAULT
$env:LENS              = $LENS
$env:HOOK              = $HOOK
$env:POOL_MANAGER      = $POOL_MGR
$env:V4_QUOTER         = $QUOTER
$env:UNIVERSAL_ROUTER  = $UR
$env:PERMIT2           = $PERMIT2
$env:USDC              = $USDC
$env:WETH              = $WETH
$env:POOL_FEE          = "500"
$env:TICK_SPACING      = "60"

# --- 4. run forge script ------------------------------------------------------
"`n== STEP 3: forge script ForkE2E =="
Push-Location (Split-Path -Parent $PSScriptRoot)
try {
    & forge script script/ForkE2E.s.sol:ForkE2E `
        --rpc-url $RPC `
        --broadcast `
        --unlocked `
        --sender $DEPOSITOR `
        --slow `
        --disable-code-size-limit 2>&1 | Tee-Object -FilePath fork-e2e.log
    if ($LASTEXITCODE -ne 0) { Write-Error "forge script failed (exit $LASTEXITCODE)" }
}
finally {
    Pop-Location
}

"`nDONE — see fork-e2e.log"
