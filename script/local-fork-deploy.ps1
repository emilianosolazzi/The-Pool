$ErrorActionPreference = "Stop"

$env:POOL_MANAGER       = "0x360e68faccca8ca495c1b759fd9eee466db9fb32"
$env:POS_MANAGER        = "0xd88f38f930b7952f2db2432cb002e7abbf3dd869"
$env:TOKEN0             = "0x82aF49447D8a07e3bd95BD0d56f35241523fBab1"
$env:TOKEN1             = "0xaf88d065e77c8cC2239327C5EDb3A432268e5831"
$env:ASSET_TOKEN        = "0xaf88d065e77c8cC2239327C5EDb3A432268e5831"
$env:PERMIT2            = "0x000000000022D473030F116dDEE9F6B43aC78BA3"
$env:TREASURY           = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
$env:SWAP_ROUTER_02     = "0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45"
$env:POOL_FEE           = "500"
$env:TICK_SPACING       = "60"
$env:INIT_SQRT_PRICE_X96 = "3790485104022133000000000"
$env:V2_TICK_LOWER      = "-199020"
$env:V2_TICK_UPPER      = "-198840"
$env:PERFORMANCE_FEE_BPS = "400"
$env:MAX_TVL            = "0"
$env:MAX_FEE_BPS        = "50"
$env:ZAP_POOL_FEE       = "500"

forge script script/DeployHookV2AndVault.s.sol `
  --rpc-url http://127.0.0.1:8545 `
  --broadcast `
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 `
  --disable-code-size-limit 2>&1 | Tee-Object -FilePath fork-deploy.log
