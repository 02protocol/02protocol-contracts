// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title TwoSwapProxy
/// @notice UUPS ERC1967 proxy in front of TwoSwapUpgradeable. The proxy address is PERMANENT —
///         logic upgrades only replace the implementation slot (deploy a new TwoSwapUpgradeable
///         + proxy.upgradeToAndCall), never the proxy itself.
///         Constructor deploys the proxy AND runs initialize(...) in one transaction (delegatecall).
contract TwoSwapProxy is ERC1967Proxy {
    constructor(address implementation, bytes memory _data) ERC1967Proxy(implementation, _data) {}
}
