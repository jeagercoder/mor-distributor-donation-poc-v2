# mor-distributor-donation-poc-v2

Self-contained Foundry PoC for a MOR smart-contract bug-bounty finding.
Forks Ethereum deployed bytecode at a **pinned block (25996939)**; attacker is an unprivileged EOA.

DonationSkew.t.sol = yield-donation redirects period emission (stETH pool 3167->964 MOR, wBTC pool ->2418 MOR). DonationProfit.t.sol = net +$1,332/attack at 0.016 wBTC. DonationE2E.t.sol = stake->donate->distribute->claim cross-chain mint to attacker (1861 vs 2.85 MOR).

## Run

```
forge test -vv
```

forge-std is vendored — no submodule init needed.

## RPC (important)

Each test pins the block via `vm.createSelectFork(vm.envOr("ETH_RPC", <public default>), 25996939)`.
The fork must read **archive state** at block 25996939, which touches hundreds of storage slots.
Free public endpoints rate-limit that cold burst, so for a reliable first-run set an archive RPC:

```
export ETH_RPC=<your Alchemy/Infura/QuickNode archive URL>
forge test -vv
```

With the public default a single re-run usually suffices once Foundry's fork cache warms.
