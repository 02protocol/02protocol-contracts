# 02Protocol — Contracts

Source code of the **02Protocol** contracts deployed on **BNB Smart Chain** (chain id `56`).

This repository contains the contracts only. Deployment scripts, the dApp and the test suite are not
published here; the contract source is complete and self-contained (imports are the standard
OpenZeppelin 4.9.x packages).

## Reproducing the deployed bytecode

The contracts on chain were compiled with exactly the settings below. All of them are part of the
Solidity metadata hash, so changing any one of them produces different bytecode — and a different
metadata hash — than what is deployed.

| Setting | Value |
| --- | --- |
| Compiler | `solc 0.8.19+commit.7dd6d404` |
| Optimizer | enabled, `runs = 1` |
| viaIR | `true` |
| EVM target | `paris` |
| License | MIT |

Dependencies:

- `@openzeppelin/contracts@4.9.x`
- `@openzeppelin/contracts-upgradeable@4.9.x`

## Deployed addresses (BSC mainnet)

Every module sits behind a UUPS (ERC-1967) proxy. **The proxy address is the permanent one** — the
implementation address only changes when the module is upgraded.

| Module | Proxy (permanent) | Implementation |
| --- | --- | --- |
| TwoProtocol (the 02 token) | `0x9e5dD55481AcCC93E4a781E65D3795E9E7B2a7c6` | `0x9628d61E665121c30ccd45A4b64B61438B72EA8E` |
| RewardDistributor | `0xea00fB5Bab3092956E1a13f0e7748c83a9618Acc` | `0x1F0cEc193238b7663690C1694334747927048458` |
| LPReward | `0xB3dA5a206ecA1eBdB8fb90a54A1c12bc719D5DdD` | `0x9720E64d0FdA53caFDB1e4DcA029872F245fe93E` |
| TwoLend | `0xFF1128634d42146D68b988d40908bF97d4694925` | `0x6EC4087D8Fcc479f0cD715688957BaC90D580C97` |
| LiquidityManager | `0x7C8cef567b86327B7fdBb3e218B1bC933682Dfe4` | `0x8fEff6C35a8e6c0513DAc670389303A3a644caEF` |
| TwoSwap | `0x6631f1b82Ef0Ccb2a6ff26b0C2f9650B29466Fde` | `0xC8A3D4367747750F96A012FF4eC74C148fEE65Ec` |
| TwoFoundation | `0x1F2018117c4acA2cB2B5EFCd2355A7015bC47F22` | `0xEaFe5fA63BBF59aF4290Db6C5C6c154Bc1751470` |
| TwoDAO | `0x1E9D0bCB55b65808F0972A3D9fE30275DDE6c26E` | `0xBF56C61A1771F6EaD7509492F85d3c2982ddD149` |
| 02/WBNB pair (PancakeSwap V2) | `0xA5faffc96Df312456Fde83765DCb35C7B4673733` | — |

## Source verification

Both explorer records were produced from this source:

- **BscScan** — every address above shows verified source code
  (e.g. the token: <https://bscscan.com/address/0x9e5dD55481AcCC93E4a781E65D3795E9E7B2a7c6#code>)
- **Sourcify** — full match, creation + runtime, including constructor arguments:
  <https://repo.sourcify.dev/56/0x9e5dD55481AcCC93E4a781E65D3795E9E7B2a7c6>

## Layout

```
contracts/
├── TwoProtocolUpgradeable.sol       # the ERC-20 / bonding-curve token + backing vault
├── RewardDistributorUpgradeable.sol # single-token staking dividends
├── LPRewardUpgradeable.sol          # LP staking dividends
├── TwoLendUpgradeable.sol           # collateralised lending
├── LiquidityManagerUpgradeable.sol  # one-way V2 liquidity seeding
├── TwoSwapUpgradeable.sol           # swap wrapper
├── TwoFoundationUpgradeable.sol     # multisig treasury / referral rewards
├── TwoDAOUpgradeable.sol            # staker governance
├── TwoProtocolProxy.sol             # ERC-1967 proxies used for the modules above
├── TwoSwapProxy.sol
└── UpgradeableProxy.sol
```

## Notes

- Ownership uses the two-step handover pattern (`Ownable2Step`); upgrades are authorised by the
  proxy owner.
- Token supply is hard-capped at 21,000,000 in code and is not governable. There is no premine, no
  team allocation and no private sale.
- Token page and documentation: <https://02protocol.app>

Nothing in this repository is financial advice.
