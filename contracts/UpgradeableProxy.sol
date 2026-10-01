// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title UpgradeableProxy
/// @notice Generic ERC1967 (UUPS) proxy — the proxy address is PERMANENT, only the
///         implementation (logic) can be swapped via proxy.upgradeTo by the owner.
///         Constructor deploys the proxy already pointing at `implementation` and runs
///         `_data` (the initialize() call) in the same transaction (anti front-run).
///         Used for RewardDistributorUpgradeable / LPRewardUpgradeable /
///         TwoLendUpgradeable / LiquidityManagerUpgradeable.
contract UpgradeableProxy is ERC1967Proxy {
    constructor(address implementation, bytes memory _data) ERC1967Proxy(implementation, _data) {}
}
