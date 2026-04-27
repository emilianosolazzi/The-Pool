$ErrorActionPreference = "Continue"

$env:POOL_MANAGER       = "0x360e68faccca8ca495c1b759fd9eee466db9fb32"
$env:TOKEN0             = "0x82aF49447D8a07e3bd95BD0d56f35241523fBab1"
$env:TOKEN1             = "0xaf88d065e77c8cC2239327C5EDb3A432268e5831"
$env:POOL_FEE           = "500"
$env:TICK_SPACING       = "60"
$env:HOOK_ADDR          = "0x93d7Fc36535d0b5644E2AC0E930D356BDdd3C0cc"
$env:VAULT_ADDR         = "0x0129d38A12aFd6Fe1d35B17A0691682128874496"

forge script script/TestReserveSwap.s.sol --tc TestReserveSwap `
  --rpc-url http://127.0.0.1:8545 `
  --broadcast `
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 `
  --disable-code-size-limit 2>&1 | Tee-Object -FilePath fork-reserveswap.log
