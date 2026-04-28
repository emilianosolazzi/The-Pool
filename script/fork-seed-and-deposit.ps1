$ErrorActionPreference = "Stop"
$RPC   = "http://127.0.0.1:8545"
$WETH  = "0x82aF49447D8a07e3bd95BD0d56f35241523fBab1"
$USDC  = "0xaf88d065e77c8cC2239327C5EDb3A432268e5831"
$PMGR  = "0xd88f38f930b7952f2db2432cb002e7abbf3dd869"  # pos mgr
$PERM2 = "0x000000000022D473030F116dDEE9F6B43aC78BA3"
$VAULT = "0x1949A4Ee48E671E50ADC7052Ed398B3528d8E511"
$DEP   = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
$PK    = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
$WHALE = "0x489ee077994b6658eafa855c308275ead8097c4a"

# 1. Whale → deployer 2000 USDC
& cast rpc --rpc-url $RPC anvil_setBalance $WHALE "0xDE0B6B3A7640000" | Out-Null
& cast rpc --rpc-url $RPC anvil_impersonateAccount $WHALE | Out-Null
& cast send $USDC "transfer(address,uint256)" $DEP "2000000000" --from $WHALE --rpc-url $RPC --unlocked | Out-Null

# 2. Wrap 1 ETH -> WETH (deployer needs WETH for seed + swap)
& cast send $WETH "deposit()" --value "1ether" --rpc-url $RPC --private-key $PK | Out-Null

"USDC dep: " + (& cast call $USDC "balanceOf(address)(uint256)" $DEP --rpc-url $RPC)
"WETH dep: " + (& cast call $WETH "balanceOf(address)(uint256)" $DEP --rpc-url $RPC)

# 3. Run SeedActiveLiquidity (0.4 WETH + 900 USDC into the V2 hooked pool, range -199020/-198840)
$env:POOL_MANAGER       = "0x360e68faccca8ca495c1b759fd9eee466db9fb32"
$env:POS_MANAGER        = $PMGR
$env:PERMIT2            = $PERM2
$env:TOKEN0             = $WETH
$env:TOKEN1             = $USDC
$env:HOOK               = "0xd893D3390B58Fc4D94f80235F9eF4959F3aDc0cc"
$env:POOL_FEE           = "500"
$env:TICK_SPACING       = "60"
$env:SEED_TICK_LOWER    = "-199020"
$env:SEED_TICK_UPPER    = "-198840"
$env:SEED_AMOUNT0_MAX   = "400000000000000000"   # 0.4 WETH
$env:SEED_AMOUNT1_MAX   = "900000000"            # 900 USDC

forge script script/SeedActiveLiquidity.s.sol --tc SeedActiveLiquidity `
  --rpc-url $RPC --broadcast --private-key $PK `
  --disable-code-size-limit 2>&1 | Tee-Object -FilePath fork-seed.log | Out-Null
"--- seed result ---"
Get-Content fork-seed.log | Select-String "minted tokenId|liquidity        |currentSqrtPrice|expected token0|expected token1"

# 4. Deposit 100 USDC into vault
& cast send $USDC "approve(address,uint256)" $VAULT "100000000" --rpc-url $RPC --private-key $PK | Out-Null
& cast send $VAULT "deposit(uint256,address)" "100000000" $DEP --rpc-url $RPC --private-key $PK | Out-Null

"vault USDC: " + (& cast call $USDC "balanceOf(address)(uint256)" $VAULT --rpc-url $RPC)
"dep shares: " + (& cast call $VAULT "balanceOf(address)(uint256)" $DEP --rpc-url $RPC)
