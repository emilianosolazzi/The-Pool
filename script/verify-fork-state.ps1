$ErrorActionPreference = "Continue"
$RPC = "http://127.0.0.1:8545"
$DIST = "0x4a65085c4839fc060762bD0ea43FD65DEb64Bf65"
$HOOK = "0x93d7Fc36535d0b5644E2AC0E930D356BDdd3C0cc"
$VAULT = "0x0129d38A12aFd6Fe1d35B17A0691682128874496"

function C([string]$addr, [string]$sig) {
    return (& cast call $addr $sig --rpc-url $RPC 2>&1) -join " "
}

"== Hook address flag bits =="
"hook last byte = 0x" + $HOOK.Substring($HOOK.Length - 4)
"expected       = 0x_cc (BEFORE_SWAP|AFTER_SWAP|BEFORE_SWAP_RETURNS_DELTA|AFTER_SWAP_RETURNS_DELTA = 0xCC)"

"`n== FeeDistributor =="
"hook       : " + (C $DIST "hook()(address)")
"treasury   : " + (C $DIST "treasury()(address)")

"`n== Hook =="
"distributor: " + (C $HOOK "distributor()(address)")
"owner      : " + (C $HOOK "owner()(address)")
"maxFeeBps  : " + (C $HOOK "maxFeeBps()(uint256)")

"`n== Vault =="
"asset      : " + (C $VAULT "asset()(address)")
"name       : " + (C $VAULT "name()(string)")
"symbol     : " + (C $VAULT "symbol()(string)")
"owner      : " + (C $VAULT "owner()(address)")
"treasury   : " + (C $VAULT "treasury()(address)")
"reserveHook: " + (C $VAULT "reserveHook()(address)")
"zapRouter  : " + (C $VAULT "zapRouter()(address)")
"perfFeeBps : " + (C $VAULT "performanceFeeBps()(uint256)")
"tickLower  : " + (C $VAULT "tickLower()(int24)")
"tickUpper  : " + (C $VAULT "tickUpper()(int24)")
"totalSupply: " + (C $VAULT "totalSupply()(uint256)")
"totalAssets: " + (C $VAULT "totalAssets()(uint256)")
