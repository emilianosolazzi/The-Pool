$ErrorActionPreference = "Continue"
$RPC   = "http://127.0.0.1:8545"
$USDC  = "0xaf88d065e77c8cC2239327C5EDb3A432268e5831"
$VAULT = "0x0129d38A12aFd6Fe1d35B17A0691682128874496"
$DEP   = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
$PK    = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"

# Impersonate a known Arbitrum USDC whale — Aave V3 aArbUSDCn pool
$WHALE = "0x47c031236e19d024b42f8AE6780E44A573170703"  # GMX V2 market token (large USDC)
# Fallback whale list - we'll pick one with >=10 USDC

function BalUsdc([string]$who) {
    $r = (& cast call $USDC "balanceOf(address)(uint256)" $who --rpc-url $RPC) -join " "
    return ($r -split " ")[0]
}

"== Pre-state =="
"deployer USDC: " + (BalUsdc $DEP)

# Try multiple whales until we find one with enough USDC
$candidates = @(
  "0x489ee077994b6658eafa855c308275ead8097c4a",   # GMX
  "0x47c031236e19d024b42f8AE6780E44A573170703",   # GMX V2 market
  "0xB38e8c17e38363aF6EbdCb3dAE12e0243582891D",   # Random whale
  "0x724dc807b04555b71ed48a6896b6F41593b8C637"    # Aave aArbUSDCn
)
$picked = $null
foreach ($w in $candidates) {
    $b = BalUsdc $w
    "candidate $w bal=$b"
    if ([bigint]::Parse($b) -ge 10000000) { $picked = $w; break }  # 10 USDC
}
if (-not $picked) { Write-Error "no whale found"; exit 1 }
"using whale: $picked"

# Give whale some ETH and impersonate
& cast rpc --rpc-url $RPC anvil_setBalance $picked "0xDE0B6B3A7640000" | Out-Null
& cast rpc --rpc-url $RPC anvil_impersonateAccount $picked | Out-Null

# Transfer 100 USDC to deployer
& cast send $USDC "transfer(address,uint256)" $DEP "100000000" --from $picked --rpc-url $RPC --unlocked | Out-Null

"deployer USDC after transfer: " + (BalUsdc $DEP)

# Approve and deposit
& cast send $USDC "approve(address,uint256)" $VAULT "100000000" --rpc-url $RPC --private-key $PK | Out-Null
$tx = & cast send $VAULT "deposit(uint256,address)" "100000000" $DEP --rpc-url $RPC --private-key $PK --json | ConvertFrom-Json
"deposit txhash: $($tx.transactionHash)"
"deposit status: $($tx.status)"
"deposit gasUsed: $($tx.gasUsed)"

"`n== Post-state =="
"deployer shares  : " + ((& cast call $VAULT "balanceOf(address)(uint256)" $DEP --rpc-url $RPC) -join " ")
"vault totalSupply: " + ((& cast call $VAULT "totalSupply()(uint256)" --rpc-url $RPC) -join " ")
"vault totalAssets: " + ((& cast call $VAULT "totalAssets()(uint256)" --rpc-url $RPC) -join " ")
"deployer USDC    : " + (BalUsdc $DEP)
"vault USDC       : " + (BalUsdc $VAULT)
