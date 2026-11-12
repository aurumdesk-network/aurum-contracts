# AURUM

## Contracts
| Contract | Role |
|---|---|
| `AurumToken` | 1B AURUM, 0% buy / 5% sell tax on taxed pools, fixed in code |
| `ChipSwap` | 100,000 DESK (burned) + 1 BEM for one set of 4 NAND + 2 LATCH of the AURUM processor |
| `DeskMinter` | Tapes the set out into a desk circuit; max 5,000 |
| `DeskPot` | Staking, one vault per desk, rounds, BEM buyback on PancakeSwap V3, claims (UUPS proxy, upgrades through a timelock) |
| `TapeCodeRewards` | BSC: BNB for TapeCode stakers, paid from published Merkle lists |
| `TapeCodeStaking` | X Layer: staking for TapeCode NFTs, no owner |

