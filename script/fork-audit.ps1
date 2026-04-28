param([Parameter(Mandatory=$true)] [string]$Tc)
$ErrorActionPreference = "Continue"

$env:POOL_MANAGER       = "0x360e68faccca8ca495c1b759fd9eee466db9fb32"
$env:TOKEN0             = "0x82aF49447D8a07e3bd95BD0d56f35241523fBab1"
$env:TOKEN1             = "0xaf88d065e77c8cC2239327C5EDb3A432268e5831"
$env:POOL_FEE           = "500"
$env:TICK_SPACING       = "60"
$env:HOOK_ADDR          = "0xd893D3390B58Fc4D94f80235F9eF4959F3aDc0cc"
$env:VAULT_ADDR         = "0x1949A4Ee48E671E50ADC7052Ed398B3528d8E511"
$env:DIST_ADDR          = "0x72BaE0f17E349E1228b2C07E0ED5039Fa6c9d30a"
$env:TREASURY           = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"

forge script script/TestReserveAudit.s.sol --tc $Tc `
  --rpc-url http://127.0.0.1:8545 `
  --broadcast `
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 `
  --disable-code-size-limit 2>&1 | Tee-Object -FilePath ("fork-audit-{0}.log" -f $Tc)
