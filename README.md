# AURUM

Revenue-sharing NFT protocol on **BNB Chain**, built on the TapeOut ecosystem. Every staked desk (a TapeOut circuit of the AURUM processor) gets an equal share of the protocol's cash flow, paid in **BEM** and **BNB**.

> ⚠️ In development, not audited. Contract rules and design notes: `CLAUDE.md`.

## Run it locally (BSC mainnet fork)
1. Double-click **`start-fork.bat`**. It starts a fork of BSC (real PancakeSwap, BNB, BEM), deploys the contracts and opens the website.
2. Open http://localhost:3000 → Connect wallet → **Dev wallet** (or MetaMask through `<site>/rpc`) → **Get test funds**.
3. Mint → Stake on My Desk → trade DESK to build up tax → a round runs → Claim.

Share the fork with a few testers: `share-tunnel.bat` (after `start-fork.bat`). TapeCode payout list on the forks: `tapecode-payout.bat`.

## Contracts
| Contract | Role |
|---|---|
| `AurumToken` | 1B AURUM, 0% buy / 5% sell tax on taxed pools, fixed in code |
| `ChipSwap` | 100,000 DESK (burned) + 1 BEM for one set of 4 NAND + 2 LATCH of the AURUM processor |
| `DeskMinter` | Tapes the set out into a desk circuit; max 5,000 |
| `DeskPot` | Staking, one vault per desk, rounds, BEM buyback on PancakeSwap V3, claims (UUPS proxy, upgrades through a timelock) |
| `TapeCodeRewards` | BSC: BNB for TapeCode stakers, paid from published Merkle lists |
| `TapeCodeStaking` | X Layer: staking for TapeCode NFTs, no owner |

## Tests
- `.\.tools\foundry\forge.exe test`: unit and fuzz tests.
- Fork tests: `$env:FORK_URL="http://127.0.0.1:8545"; .\.tools\foundry\forge.exe test --match-contract ForkAurum -j 1`
- Simulation with realistic users: `cd sim; .venv\Scripts\python.exe simulate.py --wallets 100`
