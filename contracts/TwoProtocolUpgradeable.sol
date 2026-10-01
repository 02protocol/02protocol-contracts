// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IPancakeFactory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

interface IUniswapV2Router {
    function factory() external pure returns (address);
    function WETH() external pure returns (address);
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;
    function swapExactTokensForETH(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;
    function swapExactETHForTokens(uint amountOutMin, address[] calldata path, address to, uint deadline)
        external
        payable
        returns (uint[] memory amounts);
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint amountOutMin, address[] calldata path, address to, uint deadline
    ) external payable;
    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity);
}

/// V14: the referral-incentive side of the foundation, which credits 02 income into its own budget.
/// Kept as a minimal interface so this contract does not depend on the whole foundation ABI.
interface ITwoReferralPool {
    function creditReferralPool(uint256 amount) external;
}

/// V15: what identifies a Uniswap/Pancake-V2 shaped pair. Used to RECOGNISE a 02 pool that this protocol
/// did not create — a third party can open a parallel pool permissionlessly, and the one thing that
/// tells a pool apart from a wallet, a router, an aggregator or a multisig is that it answers this.
interface ITwoPairLike {
    function getReserves() external view returns (uint112, uint112, uint32);
}

/// @title TwoProtocolUpgradeable
/// @notice UUPS-upgradeable variant of TwoProtocol. Deployed behind an ERC1967 proxy on mainnet so
///         the address stays fixed while the implementation can be upgraded locally (deploy a new
///         implementation + proxy.upgradeToAndCall — no redeploy of the whole stack, low cost).
///         Constructor logic moved into initialize(); the initializer guard + _disableInitializers()
///         prevent re-initialization and direct calls on the implementation.
contract TwoProtocolUpgradeable is
    Initializable,
    ERC20Upgradeable,
    ERC20BurnableUpgradeable,
    Ownable2StepUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    /* ============ Constants ============ */
    /// Hard issuance ceiling — NOT governable.
    /// The "worst case" total issuance (including discrete overshoot) must be ≤ this value,
    /// enforced on-chain in validateMintParams.
    uint256 public constant MAX_SUPPLY = 21_000_000 * 1e18;

    /// Hard raise ceiling — NOT governable. Absolute upper bound of the raise cap C
    /// (in practice it is hit earlier by the issuance hard ceiling: about 20 BNB under the 10x curve).
    uint256 public constant MAX_MINT_BNB = 500 * 1e18;

    /// Curve identity (C = MINT_BNB_CAP, r = PRICE_MAX/PRICE_MIN = 10):
    ///   S = C · ln(r) / (P0 · (r − 1))  ≤  MAX_SUPPLY
    /// ⚠️ The continuous integral S is only a **lower bound**: mints are priced by "the cumulative
    ///    amount before this transaction" (left-value discrete summation), so actual issuance is
    ///    always ≥ S; overshoot upper bound = PER_ADDRESS_BNB_CAP · (1e18/P0 − 1e18/Pmax).
    ///    Hence the on-chain hard-ceiling check uses worstCaseSupplyFor() = S + that bound
    ///    (see validateMintParams).
    /// Prices P0 / Pmax are a fixed curve (not governable; factory values in _applyMintDefaults);
    /// only the raise cap C and the per-address cap are adjustable, and after minting starts they
    /// can only be lowered — lowering C scales the issuance down proportionally, so the worst case
    /// only gets smaller.

    uint256 public constant FEE_PRECISION = 10_000;
    uint256 public constant FEE_START     = 3000;  // 30% at the start of the mint phase
    uint256 public constant FEE_END       = 500;   // 5% at the end of the mint phase & fixed 5% after V2

    uint256 public constant TAX_RATE    = 300;   // 3% total tax
    // vault/burn shares moved from constants to governable storage (V9): see vaultRateBps / burnRateBps
    uint256 public constant SWAP_THRESHOLD = 1_000 * 1e18;

    uint256 private constant ONE_ETHER = 1e18;

    /* ============ State (storage layout MUST stay fixed across upgrades) ============ */
    uint256 public vaultBNB;
    uint256 public circulatingSupply;
    uint256 public totalMintedBNB;
    uint256 public totalBurned;   // cumulative TWO burned (frontend deflation display)
    mapping(address => uint256) public mintedBNBPerAddress;

    bool public isMintPhase;    // NOTE: default value set explicitly in initialize() — proxies
    bool public mintEnabled;    // start with zeroed storage, so `bool x = true` would be lost
    bool public vaultSellOpen;
    bool public isV2Open;
    bool public liquidityOpen;

    mapping(address => bool) public whitelist;
    mapping(address => bool) public isExcluded;

    address public factoryAddress;
    address public wbnbAddress;
    address public routerAddress;
    address public pairAddress;
    address public rewardDistributor;
    address public lpReward;
    address public lendingContract;

    uint256 public taxTotal;
    bool    public inSwap;

    // ===== V3 additions (appended — UUPS storage layout MUST stay append-only) =====
    // Slots kept for storage-layout compatibility ONLY: the V3 timelocked withdrawal trio
    // (request / cancel / execute) was removed in V14 to free EIP-170 space, so nothing writes these any
    // more. They are deliberately NOT `public`: the trio is gone, so an external getter would be dead ABI
    // surface, and at the EIP-170 edge three unused getters are bytes the contract cannot spare. The
    // slots, names and types are untouched, which is all `check-upgrade-safety` and the proxy care about.
    uint256 pendingVaultWithdraw;        // amount requested (0 = no pending request)
    uint256 pendingVaultWithdrawTime;    // block.timestamp of the request
    address pendingVaultWithdrawTo;      // recipient (fixed at request time = msg.sender)

    // V4: LiquidityManager is exempt from the V2 transfer tax so that adding /
    // removing liquidity through the manager does not pay the 3% fee (swap only).
    address public liquidityManager;

    // V5: per-mint success rate (anti-batch-mint). 0 = disabled (every mint succeeds);
    // otherwise 1..10000 bps (e.g. 8000 = each mint has an 80% chance to succeed).
    // whitelist / isExcluded addresses bypass the draw (always succeed).
    uint256 public mintSuccessBps;
    uint256 private mintNonce; // per-mint randomness seed — only ever incremented

    // V7: Buyback sink (lending interest + swap fees). Two modes:
    //   burn mode (buybackModeBurn == true)  -> BNB accumulates in buybackPool, later buys 02 on V2 and burns
    //   sink mode (false)                    -> BNB forwarded straight to buybackSink (team/DAO wallet)
    // NOTE: `buybackModeBurn = true` default is set via initV7() (proxy storage starts zeroed).
    uint256 public buybackPool;        // BNB accumulated for buyback (burn mode)
    bool    public buybackModeBurn;    // true = burn on-chain, false = forward to sink
    address public buybackSink;        // arbitrary destination wallet (mode 2)

    // V8: DAO governance — V2 tax dividend split (LP vs single-token staking).
    // V9: vault/burn shares are also governable (vaultRateBps / burnRateBps, in bps of trade amount).
    address public dao;                // TwoDAO (onlyDAO setters)
    uint256 public v2LpShareBps;       // LP share of the 1.5% dividend part (default 6667 = LP 1% / single 0.5%)
    // V9 (append-only, appended at the end): vault / burn share of trade amount in bps (default 100 = 1% / 50 = 0.5%)
    uint256 public vaultRateBps;
    uint256 public burnRateBps;

    // V10 (append-only, appended at the end): mint parameters moved from compile-time constants to storage slots.
    // Initial values: see _applyMintDefaults().
    // Hard constraint: worstCaseSupplyFor() ≤ MAX_SUPPLY (21 million), checked on-chain in validateMintParams.
    uint256 public MINT_BNB_CAP;        // raise cap C in BNB (can only be lowered once minting starts)
    uint256 public PER_ADDRESS_BNB_CAP; // per-address cumulative cap (can only be lowered once minting starts)
    // Curve prices: **only _applyMintDefaults() ever writes these two slots**; no path can change them afterwards
    // (setMintParams takes no price arguments) → equivalent to immutable constants; neither the client nor the DAO can set prices.
    // Calibration basis: raise cap 20 BNB / per-address cap 0.1 BNB / issuance 21 million / 10x curve → see _applyMintDefaults.
    uint256 public PRICE_MIN;           // starting price P0 (BNB/02)
    uint256 public PRICE_MAX;           // raise price (BNB/02) = P0 × 10

    // V12 (append-only, appended at the end): emergency freeze list.
    // Purpose: emergency stop-loss after a wallet compromise, before the market dumps. A frozen address has its tokens **fully locked**:
    // it cannot transfer out, receive, sell back to the protocol, or mint.
    // ⚠️ Only "freeze" exists; there is no entry point to "confiscate / move frozen assets" — no confiscation power is introduced.
    mapping(address => bool) public frozen;

    // V13 (appended): one-way seal for the vault-withdrawal paths.
    // While unsealed the owner may pull BNB back out of the backing vault
    // (deployment / testing / emergency). At project launch `sealVaultWithdraw()` is called
    // ONCE and is irreversible: afterwards `ownerWithdrawVault` and the
    // `setLendingContract` detour both revert, so NOBODY — including the permission wallet — can
    // ever take BNB out of the backing vault again. The flag is public and verifiable on-chain.
    bool public vaultWithdrawSealed;

    // V14 (append-only): the community/foundation leg. Two slots are appended here (60 total): the
    // uint256 takes a slot of its own, so the address behind it cannot share the sealed flag's slot.
    // The foundation's referral rewards are paid in **02** (TwoFoundation.claimIncentive) and that pool is
    // funded only by donations today, so the community fund has no revenue that scales with usage. This
    // leg routes a slice of the V2 tax to the foundation **in 02** — it is never swapped into BNB.
    // The slice is carved out of the DIVIDEND leg (the 1.5% that goes to stakers): `divBps` below divides
    // by `TAX_RATE - burnRateBps - foundationTaxBps`, which keeps the backing vault at its full 1% and the
    // burn at its full 0.5%, and leaves stakers with 1.5% - foundationTaxBps. The foundation's own BNB and
    // USDT keep coming from community donations for operating costs, so the 02 it receives is never sold.
    // `foundationTaxBps` is in bps OF THE TRADE AMOUNT, and the DAO is meant to own this ratio later.
    // Zero (the default) means the leg is off and every number is exactly what it was before.
    uint256 public foundationTaxBps;
    address public foundationSink;   // the foundation contract (already whitelisted, so holding 02 is safe)

    // V15: the tax scope covers EVERY 02 pool, not only the one this protocol created. A third party can
    // open a parallel 02 pool permissionlessly and trade there; without this, that trade pays no tax at
    // all, which both starves the vault/burn/dividend legs and hands out a tax-free venue. Pools are
    // recognised by `_isTaxedPoolSide` (see it for how), so the official pool and every other one are
    // taxed alike. Deliberate exceptions use the pre-existing `setIsExcluded(pair, true)` — the same
    // switch that already means "this address pays no V2 tax" — so no new registry was introduced.
    //
    // V15b (appended): the two switches over that scope, as one owner-only state variable.
    //   `poolTaxScope` 0 = every 02 pool is taxed (the default, and what a zero-initialised proxy gives,
    //                      so no initializer call is needed)
    //                  1 = only the pool this protocol created is taxed (pre-V15 behaviour; the official
    //                      pool is taxed in EVERY mode, so this can never switch off the core 3%)
    //                  2 = 0, frozen for good      3 = 1, frozen for good
    // Modes 0/1 are the REVERSIBLE gate; 2/3 are the ONE-WAY latch — passing one of them seals the gate
    // in the state chosen, irreversibly (the same idea as the vault-withdrawal seal). The low bit is the
    // gate itself, which is why `_isTaxedPoolSide` tests `poolTaxScope & 1`.
    uint8 public poolTaxScope;

    /* ============ Events ============ */
    event Minted(address indexed user, uint256 bnbAmount, uint256 tokenAmount, uint256 price);
    event MintFailed(address indexed user, uint256 bnbAmount, uint256 nonce);
    event Sold(address indexed user, uint256 tokenAmount, uint256 bnbReturned, uint256 fee, uint256 price);
    event MintPhaseEnded(uint256 finalVault, uint256 finalSupply, uint256 finalPrice);
    event OperationalPhaseOpened();
    event V2TaxSwapped(uint256 tokensSold, uint256 bnbReceived, uint256 toVault, uint256 toLP, uint256 toReward, uint256 burned);
    event BuybackPooled(uint256 amount);                 // BNB accumulated into the buyback pool
    event BuybackSinked(uint256 amount, address to);     // mode-2 forward to the sink wallet
    event BuybackExecuted(uint256 bnbSpent, uint256 twoBurned); // buy 02 on V2 and burn it
    event MintParamsUpdated(uint256 mintBnbCap, uint256 perAddressCap, uint256 theoreticalSupply);
    event Frozen(address indexed account, bool flag);    // V12 emergency freeze / unfreeze
    event VaultWithdrawSealed();                          // V13 vault withdrawal authority permanently sealed
    event FoundationTaxLegSet(uint256 bps, address sink); // V14 the foundation slice of the dividend leg
    event PoolTaxScopeSet(uint8 scope);                   // V15b 0/1 = reversible, 2/3 = sealed in place

    modifier onlyMintPhase() {
        require(isMintPhase, "Mint phase ended");
        _;
    }
    modifier swappingGuard() {
        inSwap = true;
        _;
        inSwap = false;
    }
    modifier lockSwap() {
        require(!inSwap, "Swap in progress");
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        // The implementation contract must never be initialized directly — only via the proxy
        _disableInitializers();
    }

    /// One-time initialization, called by the proxy right after deployment (delegatecall).
    /// owner = msg.sender (the deployer).
    function initialize() external initializer {
        __ERC20_init("02Protocol", "02");
        __ERC20Burnable_init();
        __Ownable2Step_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        isMintPhase = true; // default `true` in the source is meaningless under a proxy — set here
        // Exempt the contract itself, owner and the future router/pair (enabled individually via setters)
        isExcluded[address(this)] = true;
        isExcluded[owner()]       = true;

        // Governable mint curve defaults (same reason as isMintPhase: proxy storage starts zeroed)
        _applyMintDefaults();
    }

    /// Only the owner may upgrade the implementation (UUPS).
    function _authorizeUpgrade(address /*newImplementation*/) internal override onlyOwner {}

    /// V7 upgrade hook (called once via upgradeToAndCall): sets the buyback default to burn mode.
    /// ownerOnly for the same reason as initV9 below: an unguarded reinitializer is callable by anyone
    /// until it is consumed (check-launch-state.js flags a proxy at reinit version <= 2 for exactly this).
    function initV7() external onlyOwner reinitializer(2) {
        buybackModeBurn = true;
    }

    /// V8+V9 upgrade hook: sets the DAO defaults for the V2 tax split
    /// (vault 1% / burn 0.5% / of the 1.5% dividend: LP 1% · single-token 0.5%).
    /// ownerOnly: see initV7 — an unguarded reinitializer lets a stranger rewrite the V2 tax split.
    function initV8() external onlyOwner reinitializer(3) {
        v2LpShareBps = 6667;
        vaultRateBps = 100;
        burnRateBps = 50;
    }

    /// V9 upgrade hook (reinitializer 4): initializes the vault/burn defaults after upgrading an existing proxy (new storage slots read 0)
    /// ownerOnly: an unguarded reinitializer is callable by anyone until it is consumed, which would
    /// let a stranger overwrite DAO-set parameters.
    function initV9() external onlyOwner reinitializer(4) {
        vaultRateBps = 100;
        burnRateBps = 50;
    }

    /// V10 upgrade hook (reinitializer 5): writes the mint parameters into storage slots (for upgrading existing proxies; fresh deployments go through initialize).
    /// ⚠️ Only applies to a proxy that has "not started minting yet": after minting starts both the raise cap and the per-address cap can only be lowered,
    ///    so if the on-chain current value is below the value written here, later setMintParams calls are rejected by the downward-only rule.
    function initV10() external onlyOwner reinitializer(5) {
        _applyMintDefaults();
    }

    /// V11 upgrade hook (reinitializer 6): re-calibrated the mint parameters to the factory curve of the time (200 BNB / 0.2 BNB / 10x).
    /// The old values in existing V10 proxies (50 BNB / 0.000008 / 0.0000536 / ×6.7) cannot be rewritten via setMintParams
    /// (there is simply no price setter, and caps are downward-only), so a new init hook is the only way to rewrite them.
    function initV11() external onlyOwner reinitializer(6) {
        _applyMintDefaults();
    }

    /// V16 upgrade hook (reinitializer 7): re-calibrates the mint parameters to the factory curve in use now
    /// (raise cap 20 BNB / per-address 0.1 BNB / 10x curve — see _applyMintDefaults).
    /// Same reason as initV11: the curve prices have no setter and the caps are downward-only under setMintParams,
    /// so on an existing proxy a new init hook is the only way to rewrite them.
    function initV12() external onlyOwner reinitializer(7) {
        _applyMintDefaults();
    }

    /// Factory values for the mint parameters (shared by initialize on fresh deployments and by initV10 / initV11 / initV12 on existing proxies).
    ///
    /// Prices are back-solved from "raise cap 20 BNB + per-address cap 0.1 BNB + target issuance 21 million + 10x curve":
    ///   P0 = [ C·ln(r)/(r−1) + per·(1 − 1/r) ] / T
    ///      = [ 20×ln(10)/9 + 0.1×0.9 ] / 21,000,000
    ///      = 0.0000002479455…  → rounded up to 1e6 wei = 0.000000247946
    ///   Pmax = P0 × 10 = 0.000002479460
    /// Rounding is deliberately "upward": it brings the worst-case issuance back within 21 million (measured 20,999,959 tokens, never more).
    /// At launch the raise cap sits at the natural limit of the 10x curve under that same 21 million ceiling (about 20 BNB), so **it can only be lowered after minting starts**
    /// — lowering = hitting the cap earlier on the same curve, issuance scales down proportionally, multiple stays 10x.
    function _applyMintDefaults() internal {
        MINT_BNB_CAP        = 20 * 1e18;              // raise cap 20 BNB
        PER_ADDRESS_BNB_CAP = 0.1 * 1e18;             // per-address cumulative 0.1 BNB (200 addresses fill the cap)
        PRICE_MIN           = 247_946_000_000;        // 0.000000247946 BNB/02
        PRICE_MAX           = 2_479_460_000_000;      // 0.000002479460 = PRICE_MIN × 10
    }

    // ===== OZ v4 hooks: centrally maintain circulatingSupply (avoids manual add/sub omissions) =====
    function _mint(address account, uint256 amount) internal override {
        super._mint(account, amount);
        circulatingSupply += amount;
    }
    function _burn(address account, uint256 amount) internal override {
        super._burn(account, amount);
        circulatingSupply -= amount;
        totalBurned += amount;
    }

    /* ============ Phase management ============ */
    function _endMintInternal() internal {
        if (isMintPhase) {
            isMintPhase = false;
            emit MintPhaseEnded(vaultBNB, circulatingSupply, getCurrentPrice());
        }
    }

    /// Auto SUSPENDED when the mint cap is reached -> owner manually opens the operational phase
    function openOperationalPhase() external onlyOwner {
        require(!isMintPhase, "Still in mint phase");
        require(!vaultSellOpen,     "Already open");
        require(pairAddress != address(0), "No pair");
        vaultSellOpen = true;
        isV2Open      = true;
        liquidityOpen = false;
        emit OperationalPhaseOpened();
    }

    /// Intermediate state before the operational phase.
    /// Allowed: LP injection into the pair — but ONLY through the LiquidityManager
    /// (`from == liquidityManager`), see the gate in _transfer.
    /// Blocked: buying from the pool (the pair->user leg) and vault sell-back.
    /// Because the pair->user leg is blocked, liquidity added in this state cannot be
    /// removed until the operational phase opens.
    function setLiquidityOpen(bool _flag) external onlyOwner {
        require(!isMintPhase, "Still in mint phase");
        require(!isV2Open, "Already open");
        liquidityOpen = _flag;
        if (pairAddress != address(0)) {
            whitelist[pairAddress] = _flag;
        }
        // The LiquidityManager must be able to receive 02 from users while the pause is
        // active (users hand 02 to the manager, which then injects it into the pair),
        // otherwise "Suspended: transfers paused" would block the add-liquidity flow.
        // Cleared again when the state is switched off, so the pause freeze is restored.
        if (liquidityManager != address(0)) {
            whitelist[liquidityManager] = _flag;
        }
    }

    /* ============ Router & address setters ============ */
    function setFactoryAddress(address _factory) external onlyOwner { factoryAddress = _factory; }
    function setWbnbAddress(address _wbnb)       external onlyOwner { wbnbAddress = _wbnb; }
    function setRouterAddress(address _router)   external onlyOwner {
        routerAddress = _router;
        isExcluded[_router] = true;
    }
    function setRewardDistributor(address _addr) external onlyOwner { rewardDistributor = _addr; }
    function setLpReward(address _addr)          external onlyOwner { lpReward = _addr; }
    function setLiquidityManager(address _addr) external onlyOwner { liquidityManager = _addr; }
    function setLendingContract(address _addr) external onlyOwner {
        // The lending contract can pull BNB out of the vault (withdrawForLend), so this pointer
        // is frozen by sealVaultWithdraw() — otherwise it would be a back door around the seal.
        require(!vaultWithdrawSealed, "Vault sealed");
        lendingContract = _addr;
        isExcluded[_addr] = true;
        // Whitelist it too: the mint-phase transfer rule burns a transfer between two
        // non-whitelisted addresses, so borrowing (collateral 02 -> the lending contract) would
        // destroy the borrower's collateral while the loan ledger still records it. isExcluded
        // alone does NOT exempt a transfer in the mint phase (that branch only reads whitelist).
        whitelist[_addr] = true;
    }

    function setWhitelist(address _addr, bool _flag)   external onlyOwner { whitelist[_addr] = _flag; }
    function setIsExcluded(address _addr, bool _flag)  external onlyOwner { isExcluded[_addr] = _flag; }

    function activateV2() external onlyOwner {
        require(factoryAddress != address(0) && wbnbAddress != address(0) && routerAddress != address(0), "DePS unset");
        pairAddress = IPancakeFactory(factoryAddress).createPair(address(this), wbnbAddress);
        // Note: the pair must NOT be isExcluded — otherwise V2 buys/sells are exempt and bypass
        // _transferWithV2Tax, making the 3% tax completely ineffective (Round 1 BugA fix)
        isV2Open = false; // the real opening is controlled by openOperationalPhase
    }

    /* ============ Price & fee queries ============ */
    function getCurrentPrice() public view returns (uint256) {
        if (circulatingSupply == 0 || vaultBNB == 0) return PRICE_MIN;
        return (vaultBNB * ONE_ETHER) / circulatingSupply;
    }

    /// Mint-phase fee decreases 30% -> 5% over 0-100% progress; fixed 5% for vault sells after V2
    function getCurrentFee() public view returns (uint256) {
        if (isMintPhase) {
            uint256 pct = (totalMintedBNB * ONE_ETHER) / MINT_BNB_CAP; // 0-1e18
            uint256 range = FEE_START - FEE_END;
            uint256 delta = (range * pct) / ONE_ETHER;
            if (delta > range) delta = range;
            return FEE_START - delta;
        }
        return FEE_END; // fixed 5% in the operational phase
    }

    /* ============ mint ============ */
    /// Owner opens minting at a time agreed with the community. One-way: once enabled it can
    /// never be disabled (prevents manipulation); the phase only ends at the mint cap
    /// (governable downward-only after minting starts, default 200 BNB, hard ceiling 500 BNB).
    function enableMint() external onlyOwner {
        require(!mintEnabled, "Already enabled");
        mintEnabled = true;
    }

    receive() external payable nonReentrant {
        if (isMintPhase) {
            require(mintEnabled, "Mint not enabled"); // refund the sender instead of swallowing BNB
            // V13: minting through a plain BNB transfer is **whitelist-only** (the operations /
            // market-making wallets). Everyone else must mint through mint() — the entry point the
            // dApp uses — so there is exactly ONE public mint door. Keeping two doors with identical
            // semantics means every future rule (limits, rationing, per-wallet treatment) would have
            // to be enforced in two places, and the second one is easy to forget.
            // A whitelisted address still bypasses the per-mint draw inside _attemptMint, so its
            // direct transfer always succeeds (no dice roll).
            require(whitelist[msg.sender], "Mint only via mint()");
            require(!frozen[msg.sender], "Frozen"); // V12: a frozen address must not mint via a direct transfer
            if (_attemptMint(msg.sender, msg.value)) {
                _doMint(msg.sender, msg.value);
            }
        }
        // Silently accept BNB outside the mint phase (V2 tax reflux, owner donations, etc.)
        // Because of that, this restriction is inert once isV2Open is true — the tax swap is the only
        // other path that sends this contract BNB (it arrives from the router after the swap), and it
        // cannot run during the mint phase.
    }

    /// Per-mint success draw (anti batch-mint): returns true on success (minting may proceed);
    /// on failure it refunds in full and returns false (no mint, no quota consumed). whitelist / isExcluded addresses always succeed.
    function _attemptMint(address user, uint256 bnbAmount) internal returns (bool) {
        if (mintSuccessBps > 0 && mintSuccessBps < 10000 && !whitelist[user] && !isExcluded[user]) {
            // Deliberately NOT seeded with a per-call counter: a failed draw refunds in full and consumes
            // no quota, so with a counter a contract could simply retry inside one transaction until it
            // won and the draw would stop constraining batch minting at all.
            //
            // The seed MUST vary per block, and on this chain it has to come from blockhash():
            // BSC runs Parlia and never merged, so EIP-4399 does not apply and `block.prevrandao` is
            // still the old DIFFICULTY value — measured on mainnet it is the constant 2. Seeding with it
            // would give every address ONE fixed outcome forever: at mintSuccessBps = 8000 about 20% of
            // addresses could never mint at all, and the rest would pass every time, so the draw would
            // stop existing. blockhash(block.number - 1) changes every block, so an address gets one
            // fixed outcome per block: no retry inside a transaction, and a miss is simply retried in the
            // next block, which is the documented behaviour ("refunded in full, try again").
            uint256 r = uint256(keccak256(abi.encodePacked(blockhash(block.number - 1), user)));
            mintNonce += 1; // diagnostics only (the MintFailed event); no longer part of the draw
            if (r % 10000 >= mintSuccessBps) {
                // Failure: refund the BNB in full, mint nothing and consume no quota
                (bool ok, ) = payable(user).call{value: bnbAmount}("");
                require(ok, "Refund failed");
                emit MintFailed(user, bnbAmount, mintNonce);
                return false;
            }
        }
        return true;
    }

    function mint() external payable nonReentrant onlyMintPhase {
        require(mintEnabled, "Mint not enabled");
        require(!frozen[msg.sender], "Frozen"); // V12: a frozen address must not mint
        require(msg.value > 0, "Zero amount"); // blocks zero-amount calls from spamming MintFailed events / wasting gas
        if (_attemptMint(msg.sender, msg.value)) {
            _doMint(msg.sender, msg.value);
        }
    }

    /// Sets the per-mint success rate (0 = disabled, all succeed; 1..10000 bps, e.g. 8000 = 80%). Owner only.
    function setMintSuccessBps(uint256 _bps) external onlyOwner {
        require(_bps <= 10000, "Invalid bps");
        mintSuccessBps = _bps;
    }

    function _doMint(address user, uint256 bnbAmount) internal lockSwap {
        require(bnbAmount > 0, "Zero amount");
        require(totalMintedBNB + bnbAmount <= MINT_BNB_CAP, "Mint cap reached");
        mintedBNBPerAddress[user] += bnbAmount;
        require(mintedBNBPerAddress[user] <= PER_ADDRESS_BNB_CAP, "Per-address cap");

        uint256 price = _getMintPrice();
        uint256 tokenAmount = (bnbAmount * ONE_ETHER) / price;

        // Mint-phase fund split: 90% backing vault / 7% LP staking dividends / 3% single-token
        // staking dividends. The dividend parts pre-fund the staking pools before staking opens.
        uint256 vaultPart  = (bnbAmount * 90) / 100;
        uint256 lpPart     = (bnbAmount * 7) / 100;
        uint256 rewardPart = bnbAmount - vaultPart - lpPart; // = 3%

        vaultBNB       += vaultPart;
        totalMintedBNB += bnbAmount;
        _mint(user, tokenAmount);  // circulatingSupply is maintained by the _mint hook

        // 7% -> LP staking dividends (LPReward.receive); on failure keep it in the vault
        if (lpPart > 0 && lpReward != address(0)) {
            (bool sL, ) = payable(lpReward).call{value: lpPart}("");
            if (!sL) vaultBNB += lpPart;
        } else if (lpPart > 0) {
            vaultBNB += lpPart;
        }
        // 3% -> single-token staking dividends (RewardDistributor.addFeeReward); on failure keep in vault
        if (rewardPart > 0 && rewardDistributor != address(0)) {
            (bool sR, ) = payable(rewardDistributor).call{value: rewardPart}(
                abi.encodeWithSignature("addFeeReward()")
            );
            if (!sR) vaultBNB += rewardPart;
        } else if (rewardPart > 0) {
            vaultBNB += rewardPart;
        }

        emit Minted(user, bnbAmount, tokenAmount, price);

        if (totalMintedBNB >= MINT_BNB_CAP) {
            _endMintInternal();
        }
    }

    function _getMintPrice() internal view returns (uint256) {
        if (totalMintedBNB >= MINT_BNB_CAP) return PRICE_MAX;
        uint256 price = PRICE_MIN + ((PRICE_MAX - PRICE_MIN) * totalMintedBNB) / MINT_BNB_CAP;
        uint256 backing = getCurrentPrice();
        return price > backing ? price : backing;
    }

    /* ============ sell (explicit + auto 314) ============ */
    function sell(uint256 tokenAmount) external nonReentrant {
        require(tokenAmount > 0, "Zero amount");
        _executeSell(msg.sender, tokenAmount);
    }

    function _executeSell(address user, uint256 tokenAmount) internal {
        // V12 emergency freeze: a frozen address must not sell back to the protocol for BNB (this path calls _burn directly, bypassing _transfer, so it must be gated separately)
        require(!frozen[user], "Frozen");
        // Allowed phases: mint phase or vaultSellOpen (operational phase)
        require(isMintPhase || vaultSellOpen, "Sell closed");
        require(balanceOf(user) >= tokenAmount, "Insufficient balance");

        uint256 price = getCurrentPrice();
        uint256 bnbValue = (tokenAmount * price) / ONE_ETHER;
        require(bnbValue > 0, "Dust");

        uint256 feeBps = getCurrentFee(); // decreasing during mint, otherwise fixed 5%
        uint256 fee         = (bnbValue * feeBps) / FEE_PRECISION;
        uint256 userReturn  = bnbValue - fee;
        // Sell-back fee split: 50% vault / 20% single-token staking / 30% LP staking
        uint256 feeToVault  = (fee * 50) / 100;
        uint256 feeToSingle = (fee * 20) / 100;
        uint256 feeToLp     = fee - feeToVault - feeToSingle;

        require(vaultBNB >= userReturn + feeToSingle + feeToLp, "Vault empty");
        vaultBNB -= (userReturn + feeToSingle + feeToLp); // feeToVault stays in the vault

        // Burn (circulatingSupply auto-decremented by the _burn hook)
        _burn(user, tokenAmount);

        // User's actual BNB
        if (userReturn > 0) {
            (bool s1, ) = payable(user).call{value: userReturn}("");
            require(s1, "BNB to user failed");
        }
        // 20% of the sell-back fee -> single-token staking pool (RewardDistributor);
        // 30% -> LP staking pool (LPReward); on failure return to the vault so no funds are lost
        if (feeToSingle > 0 && rewardDistributor != address(0)) {
            (bool s2, ) = payable(rewardDistributor).call{value: feeToSingle}(
                abi.encodeWithSignature("addFeeReward()")
            );
            if (!s2) {
                vaultBNB += feeToSingle;
            }
        } else if (feeToSingle > 0) {
            vaultBNB += feeToSingle; // rewardDistributor not set, return to the vault
        }
        if (feeToLp > 0 && lpReward != address(0)) {
            (bool s3, ) = payable(lpReward).call{value: feeToLp}("");
            if (!s3) {
                vaultBNB += feeToLp;
            }
        } else if (feeToLp > 0) {
            vaultBNB += feeToLp; // lpReward not set, return to the vault
        }

        emit Sold(user, tokenAmount, userReturn, fee, price);
    }

    /* ============ _transfer main logic (auto-sell / burn-on-transfer / V2 tax / normal) ============ */
    /// V15: is `a` a pool? Every Uniswap/Pancake-V2 shaped pair answers `getReserves()`, while a wallet
    /// does not, and neither does a router, an aggregator, a multisig or the staking / lending contracts
    /// — so none of those can be mistaken for a pool. Only contracts are probed, and only after the
    /// cheap guards in `_transfer` have been ruled out, so an ordinary transfer pays nothing for this.
    /// A real pool cannot dodge the probe: this is the same call its own router makes. A contract that
    /// answers it without being a pool is simply taxed like one, and can be exempted.
    function _isPool(address a) private view returns (bool) {
        if (a.code.length == 0) return false;
        (bool ok, bytes memory d) = a.staticcall(abi.encodeWithSelector(ITwoPairLike.getReserves.selector));
        return ok && d.length >= 96;
    }

    /// V15: must this side of a transfer pay the V2 tax? The pool this protocol created is always taxed,
    /// and so is any OTHER pool a third party opened — that is what stops a parallel 02 pool from being a
    /// tax-free venue. The reversible gate `poolTaxDisabled` narrows that back to the protocol's own pool
    /// without ever switching off the official pool's tax. A deliberate exception is made with the
    /// pre-existing `setIsExcluded(pair, true)`, which `_transfer` already honours before reaching here.
    function _isTaxedPoolSide(address a) private view returns (bool) {
        if (a == pairAddress) return true;
        return (poolTaxScope & 1) == 0 && _isPool(a);
    }

    function _transfer(address from, address to, uint256 amount) internal virtual override {
        require(from != address(0) && to != address(0), "ERC20: zero address");
        // V12 emergency freeze: a frozen address has its tokens fully locked (both outgoing and incoming are blocked).
        // The gate is placed first so it covers sell-back (to == address(this)), V2 buys/sells, plain transfers and the mint-phase burn branch.
        require(!frozen[from] && !frozen[to], "Frozen");
        if (amount == 0) { super._transfer(from, to, amount); return; }

        if (inSwap) {
            super._transfer(from, to, amount);
            return;
        }

        if (to == address(this)) {
            require(isMintPhase || vaultSellOpen, "Sell closed");
            inSwap = true;
            // The backing price divides by circulatingSupply, so it MUST be read BEFORE the burn.
            // Pricing after the burn (as this path used to) pays at q*V/(Y-q) instead of q*V/Y,
            // i.e. it over-pays any holder who redeems this way and drains the vault.
            uint256 sellPrice = getCurrentPrice();
            super._transfer(from, address(this), amount);
            _burn(address(this), amount);
            _executeSellAfterBurn(from, amount, sellPrice);
            inSwap = false;
            return;
        }

        // LP-injection window: 02 may only ENTER the pair through the LiquidityManager.
        // Both "add liquidity" and "sell into the pool" look identical at the token level
        // (user -> pair), so gating on the caller is the only way to keep trading locked:
        // a plain router swap or a hand-rolled contract calling pair.swap() now reverts too.
        // The pair->user leg stays blocked, which locks buying AND makes LP added in this
        // state non-removable until the operational phase opens.
        if (liquidityOpen && (to == pairAddress || from == pairAddress)) {
            require(from != pairAddress, "Buying locked until trading open");
            require(from == liquidityManager, "Only via liquidity manager");
            super._transfer(from, to, amount);
            return;
        }

        bool suspended = !isMintPhase && !vaultSellOpen;
        if (suspended && !whitelist[from] && !whitelist[to]) {
            revert("Suspended");
        }

        if (isMintPhase && !whitelist[from] && !whitelist[to]) {
            bool lmTx = (from == liquidityManager) || (to == liquidityManager);
            if (!lmTx) {
                _burn(from, amount);
                return;
            }
        }

        // LiquidityManager add/remove routes are tax-exempt (swap-only tax)
        bool lpTx = (from == liquidityManager) || (to == liquidityManager);
        // V15: ANY 02 pool counts, not only the one this protocol created. The cheap guards come first,
        // so the pool probe (one staticcall) only runs for a transfer that could actually be a pool
        // trade — staking / lending / rescue flows and tax-exempt addresses never pay for it, and an
        // ordinary wallet-to-wallet transfer exits on the `code.length == 0` check.
        if (isV2Open && !lpTx && !(isExcluded[from] || isExcluded[to])) {
            bool isV2Sell = _isTaxedPoolSide(to);
            bool isV2Buy  = !isV2Sell && _isTaxedPoolSide(from);
            if (isV2Sell || isV2Buy) {
                _transferWithV2Tax(from, to, amount, isV2Sell);
                return;
            }
        }

        super._transfer(from, to, amount);
    }

    /// @param price the backing price captured BEFORE the caller burned, so this path prices
    ///        identically to sell() (which also reads the price before burning).
    function _executeSellAfterBurn(address user, uint256 tokenAmount, uint256 price) internal {
        // Tokens are already burned; only BNB accounting & distribution remain (no double burn)
        require(isMintPhase || vaultSellOpen, "Sell closed");

        uint256 bnbValue = (tokenAmount * price) / ONE_ETHER;
        require(bnbValue > 0, "Dust");

        uint256 feeBps = getCurrentFee();
        uint256 fee         = (bnbValue * feeBps) / FEE_PRECISION;
        uint256 userReturn  = bnbValue - fee;
        // Sell-back fee split: 50% vault / 20% single-token staking / 30% LP staking
        uint256 feeToVault  = (fee * 50) / 100;
        uint256 feeToSingle = (fee * 20) / 100;
        uint256 feeToLp     = fee - feeToVault - feeToSingle;

        require(vaultBNB >= userReturn + feeToSingle + feeToLp, "Vault empty");
        vaultBNB -= (userReturn + feeToSingle + feeToLp);
        // circulatingSupply was already decremented by the outer TwoProtocol._burn(address(this), amount)

        if (userReturn > 0) {
            // The recipient is in control during this callback, so the swap flag is cleared for its
            // duration: a holder could otherwise use its own sell-back callback to move tokens into
            // the pool untaxed, or to transfer during the mint phase without the burn. Restored
            // before anything else runs.
            inSwap = false;
            (bool s1, ) = payable(user).call{value: userReturn}("");
            inSwap = true;
            require(s1, "BNB failed");
        }
        // 20% of the sell-back fee -> single-token staking pool (RewardDistributor);
        // 30% -> LP staking pool (LPReward); on failure, return it to the vault so no funds are lost
        if (feeToSingle > 0 && rewardDistributor != address(0)) {
            (bool s2, ) = payable(rewardDistributor).call{value: feeToSingle}(
                abi.encodeWithSignature("addFeeReward()")
            );
            if (!s2) vaultBNB += feeToSingle;
        } else if (feeToSingle > 0) {
            vaultBNB += feeToSingle;
        }
        if (feeToLp > 0 && lpReward != address(0)) {
            (bool s3, ) = payable(lpReward).call{value: feeToLp}("");
            if (!s3) vaultBNB += feeToLp;
        } else if (feeToLp > 0) {
            vaultBNB += feeToLp;
        }
        emit Sold(user, tokenAmount, userReturn, fee, price);
    }

    /* ============ V2 tax ============ */
    /// Applies the 3% V2 tax and, on a SELL only, swaps the accumulated tax into BNB.
    ///
    /// ORDER MATTERS — do not move the swap after the net transfer. The router prices a
    /// supporting-fee swap as `balanceOf(pair) - reserve`. If the net amount reaches the pair first,
    /// the pair briefly holds tokens its reserves do not account for; the nested tax swap would then
    /// treat that net as its own input, consume it and re-sync the reserves, after which the OUTER
    /// router call computes a ZERO input, calls `pair.swap(0, 0, ..)` and reverts — so every sell
    /// reverted as soon as the threshold was crossed. Tax first, swap second (while the pair's
    /// balance still equals its reserves), net last.
    ///
    /// The swap runs on the SELL leg only: a buy executes inside `pair.swap`, which holds the pair's
    /// `lock`, so a nested `pair.swap` reverts there and nothing but a burn would happen.
    function _transferWithV2Tax(address from, address to, uint256 amount, bool isSell) internal {
        uint256 tax = (amount * TAX_RATE) / FEE_PRECISION;
        uint256 net = amount - tax;

        taxTotal += tax;

        super._transfer(from, address(this), tax);
        if (isSell && taxTotal >= SWAP_THRESHOLD && isV2Open) {
            _swapTaxToBNB();
        }
        super._transfer(from, to, net);
    }

    /// V14: hand the foundation its slice of the tax, in 02. Pull-based — the foundation credits what it
    /// actually receives, so the amount is verified on its side rather than trusted from here.
    /// ⚠️ This runs INSIDE the swap's try block, and a Solidity `catch` only covers the router call in the
    /// `try` expression — a revert in the try BODY is NOT caught and would fail the whole sell. So the
    /// call is made low-level and any failure degrades to the BURN, exactly as if the leg did not exist:
    /// nothing is ever stranded at the protocol and the supply accounting stays exact. The balance delta
    /// is checked for the same reason a plain `try` would not be enough: a sink that answers the call
    /// without taking the 02 (a contract with a permissive fallback) would otherwise let us clear
    /// `taxTotal` while the tax stayed here uncounted.
    function _payFoundationTaxLeg(uint256 amount) private {
        uint256 before = balanceOf(address(this));
        _approve(address(this), foundationSink, amount);
        (bool ok, ) = foundationSink.call(
            abi.encodeWithSelector(ITwoReferralPool.creditReferralPool.selector, amount)
        );
        if (!ok || balanceOf(address(this)) != before - amount) {
            _burn(address(this), amount);
        }
    }

    function _swapTaxToBNB() internal swappingGuard {
        uint256 tokens = taxTotal;
        if (tokens == 0) return;
        if (routerAddress == address(0) || pairAddress == address(0)) return;

        // The burn share of the accumulated tax (burnRateBps out of TAX_RATE = the 0.5% leg of the
        // 3% tax). Burned ONLY once the swap has actually gone through: burning it up front, as this
        // used to, destroyed 1/6 of the tax on every failed retry instead of carrying it forward.
        // V14: the foundation slice comes out of the DIVIDEND leg and is paid in 02, never swapped. It is
        // paid only once the swap has gone through (see the success branch), so a failed swap keeps
        // `taxTotal` equal to the contract's real 02 balance and nothing is paid twice on the retry.
        uint256 toBurn = (tokens * burnRateBps) / TAX_RATE;
        uint256 toFoundation = (tokens * foundationTaxBps) / TAX_RATE;
        uint256 swapTokens = tokens - toBurn - toFoundation;
        if (swapTokens == 0) {
            if (toBurn > 0) _burn(address(this), toBurn);
            if (toFoundation > 0) _payFoundationTaxLeg(toFoundation);
            taxTotal = 0;
            return;
        }

        uint256 price = getCurrentPrice();
        uint256 minOut = (swapTokens * price * 90) / (ONE_ETHER * 100);
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = wbnbAddress;

        _approve(address(this), routerAddress, swapTokens);
        uint256 balBefore = address(this).balance;

        bool swapped;
        try IUniswapV2Router(routerAddress).swapExactTokensForETHSupportingFeeOnTransferTokens(
            swapTokens, minOut, path, address(this), block.timestamp
        ) {
            uint256 received = address(this).balance - balBefore;
            if (received > 0) {
                if (toBurn > 0) _burn(address(this), toBurn);
                if (toFoundation > 0) _payFoundationTaxLeg(toFoundation);
                // The vault/burn shares are DAO-governed (vaultRateBps/burnRateBps, in bps of trade amount);
                // the remaining dividend part (LP + single-token) is split by the DAO-governed v2LpShareBps.
                // V14: dividing by `TAX_RATE - burnRateBps - foundationTaxBps` is what makes the foundation
                // slice come out of the DIVIDEND leg only — the vault still receives its full
                // vaultRateBps share of the trade amount and the remaining dividend shrinks by exactly
                // foundationTaxBps.
                uint256 divBps     = TAX_RATE - burnRateBps - foundationTaxBps; // > 0 enforced by the setters
                uint256 toVault    = (received * vaultRateBps) / divBps;
                uint256 lpAndReward = received - toVault;
                uint256 toLp       = (lpAndReward * v2LpShareBps) / 10000;
                uint256 toReward   = lpAndReward - toLp;

                vaultBNB += toVault;

                if (lpReward != address(0)) {
                    (bool ok1, ) = payable(lpReward).call{value: toLp}("");
                    if (!ok1) vaultBNB += toLp;
                } else {
                    vaultBNB += toLp;
                }
                if (rewardDistributor != address(0)) {
                    (bool ok2, ) = payable(rewardDistributor).call{value: toReward}(
                        abi.encodeWithSignature("addV2Reward()")
                    );
                    if (!ok2) vaultBNB += toReward;
                } else {
                    vaultBNB += toReward;
                }

                swapped = true;
                emit V2TaxSwapped(swapTokens, received, toVault, toLp, toReward, toBurn);
                _updateAllRewards();
            }
        } catch {
            // Swap failed: keep the WHOLE tax (nothing burned) for the next retry
        }
        taxTotal = swapped ? 0 : tokens;
    }

    function _updateAllRewards() internal {
        if (rewardDistributor != address(0)) {
            (bool s1, ) = rewardDistributor.call(abi.encodeWithSignature("updateReward()"));
            s1;
        }
        if (lpReward != address(0)) {
            (bool s2, ) = lpReward.call(abi.encodeWithSignature("updateReward()"));
            s2;
        }
    }

    /* ============ Buyback (interest + swap fee sink) ============ */
    /// Two configurable options for the buyback sink (owner-switchable; DAO governance later):
    ///   true  = buy 02 on V2 and BURN it (deflation + floor boost)
    ///   false = forward the accumulated BNB to buybackSink (team / DAO wallet)
    function setBuybackMode(bool _burnMode, address _sink) external onlyOwner {
        if (!_burnMode) require(_sink != address(0), "Sink required");
        buybackModeBurn = _burnMode;
        buybackSink = _sink;
        // Switching to sink mode forwards whatever is already pooled to the sink. In sink mode
        // addBuyback() sends BNB straight there, so those BNB follow the same rule rather than being
        // stranded: emergencyWithdrawBNB treats buybackPool as spoken for (balance − vaultBNB −
        // buybackPool is the only withdrawable "surplus"), and buybackAndBurn refuses to run at all
        // outside burn mode — leaving them means neither sink can reach them.
        if (!_burnMode && buybackPool > 0) {
            uint256 amount = buybackPool;
            buybackPool = 0;
            (bool s, ) = payable(_sink).call{value: amount}("");
            require(s, "Sink transfer failed");
        }
    }

    /// Accumulation entry for lending interest / swap fees. The mode decides the destination:
    /// burn mode -> buybackPool; sink mode -> forwarded straight to buybackSink.
    function addBuyback() external payable {
        if (msg.value == 0) return;
        if (buybackModeBurn) {
            buybackPool += msg.value;
            emit BuybackPooled(msg.value);
        } else {
            (bool s, ) = payable(buybackSink).call{value: msg.value}("");
            require(s, "Sink transfer failed");
            emit BuybackSinked(msg.value, buybackSink);
        }
    }

    /// Execute a buyback: spend pool BNB on V2 to buy 02, then BURN it.
    /// swappingGuard sets inSwap=true so the pair->this leg uses the parent transfer (no auto-sell).
    function buybackAndBurn(uint256 amountIn, uint256 minOut) external onlyOwner swappingGuard {
        require(buybackModeBurn, "Mode: sink");
        require(amountIn > 0 && amountIn <= buybackPool, "Buyback pool");
        // The BNB spent here comes out of the contract balance, so it must not eat into vaultBNB.
        require(address(this).balance >= vaultBNB + amountIn, "Vault locked");
        require(routerAddress != address(0) && wbnbAddress != address(0), "V2 not ready");

        address[] memory path = new address[](2);
        path[0] = wbnbAddress;
        path[1] = address(this);

        uint256 balBefore = balanceOf(address(this));
        IUniswapV2Router(routerAddress).swapExactETHForTokensSupportingFeeOnTransferTokens{value: amountIn}(
            minOut, path, address(this), block.timestamp + 1200
        );
        uint256 twoGot = balanceOf(address(this)) - balBefore;

        buybackPool -= amountIn;
        if (twoGot > 0) {
            _burn(address(this), twoGot);
        }
        emit BuybackExecuted(amountIn, twoGot);
    }

    /* ============ Lending system callbacks ============ */
    function withdrawForLend(uint256 amount) external {
        require(msg.sender == lendingContract, "Only lending");
        require(vaultBNB >= amount, "Vault empty");
        vaultBNB -= amount;
        (bool success, ) = payable(lendingContract).call{value: amount}("");
        require(success, "Transfer failed");
    }

    function addLendingRepayment(uint256 principal, uint256 interest) external payable {
        require(msg.sender == lendingContract, "Only lending");
        require(principal + interest > 0, "Zero amount");
        require(msg.value == principal + interest, "BNB mismatch");
        vaultBNB += principal + interest;
    }

    function addLendingVaultShare() external payable {
        require(msg.sender == lendingContract, "Only lending");
        vaultBNB += msg.value;
    }

    /* ============ Owner emergency ============ */
    function emergencyWithdrawBNB(uint256 amount) external onlyOwner {
        // "Surplus" is balance − vaultBNB − buybackPool. The buyback BNB is already spoken for
        // (buybackAndBurn spends it out of this same balance), so treating it as surplus would let it
        // be taken here and then bought back with the vault's BNB instead.
        uint256 reserved = vaultBNB + buybackPool;
        uint256 surplus = address(this).balance > reserved ? address(this).balance - reserved : 0;
        require(amount <= surplus, "Only surplus");
        (bool success, ) = payable(msg.sender).call{value: amount}("");
        require(success, "Transfer failed");
    }

    /// One-way, IRREVERSIBLE seal of every owner vault-withdrawal path.
    /// Call this once at project launch: afterwards nobody — including this owner — can ever
    /// pull BNB out of the backing vault, and the guarantee is verifiable on-chain
    /// (`vaultWithdrawSealed == true`). It also:
    ///   · clears any pending timelock request,
    ///   · permanently freezes `setLendingContract`, because the lending contract may draw
    ///     from the vault via withdrawForLend() — re-pointing it would re-open a drain path.
    /// Requires the lending contract to be configured first (it is locked by this call).
    function sealVaultWithdraw() external onlyOwner {
        require(!vaultWithdrawSealed, "Already sealed");
        require(lendingContract != address(0), "Set lending contract first");
        vaultWithdrawSealed = true;
        // a request made before sealing must not survive it
        delete pendingVaultWithdraw;
        delete pendingVaultWithdrawTime;
        delete pendingVaultWithdrawTo;
        emit VaultWithdrawSealed();
    }

    /// Owner DIRECT vault withdrawal (no timelock) — deployment / testing / emergency only.
    /// Permanently disabled by sealVaultWithdraw().
    function ownerWithdrawVault(uint256 amount) external onlyOwner {
        require(!vaultWithdrawSealed, "Vault withdraw sealed");
        require(amount > 0, "Zero amount");
        require(vaultBNB >= amount, "Vault low");
        vaultBNB -= amount;
        (bool success, ) = payable(msg.sender).call{value: amount}("");
        require(success, "Transfer failed");
    }

    /// Owner rescue of ERC20 tokens accidentally sent to the contract.
    /// The protocol token itself is excluded: the contract's own 02 balance is the accumulated V2
    /// tax that forceSwapTax() has to burn. Letting the owner move it would desync `taxTotal` from
    /// the real balance and permanently break the tax swap.
    function ownerRescueToken(address token, uint256 amount) external onlyOwner {
        require(token != address(0), "Zero address");
        require(token != address(this), "Protocol token");
        require(IERC20(token).balanceOf(address(this)) >= amount, "Insufficient balance");
        require(IERC20(token).transfer(msg.sender, amount), "Transfer failed");
    }

    function forceSwapTax() external onlyOwner {
        _swapTaxToBNB();
    }

    /* ============ V8 DAO governance ============ */
    function setDao(address _dao) external onlyOwner {
        require(_dao != address(0), "Zero address");
        dao = _dao;
    }

    /// The DAO adjusts the LP dividend share of the V2 tax (vault 1% / burn 0.5% are fixed; of the remaining 1.5% the LP takes lpBps)
    function setV2DividendSplit(uint256 _lpBps) external {
        require(msg.sender == dao, "Only dao");
        require(_lpBps <= 10000, "Bad bps");
        v2LpShareBps = _lpBps;
    }

    /// V12 emergency freeze / unfreeze (DAO only; on the DAO side the Foundation multisig triggers it directly, with no notice period).
    /// A frozen address has its tokens fully locked: it cannot transfer out, receive, sell back to the protocol, or mint.
    /// ⚠️ There is no entry point to "confiscate / move frozen assets" — freezing is not confiscation.
    function setFrozen(address _account, bool _flag) external {
        require(msg.sender == dao, "Only dao");
        require(_account != address(0), "Zero address");
        frozen[_account] = _flag;
        emit Frozen(_account, _flag);
    }

    /// The DAO adjusts the vault / burn shares (in bps of trade amount; constraint: vault > 0 and vault+burn < total tax 3%)
    function setVaultBurnSplit(uint256 _vaultBps, uint256 _burnBps) external {
        require(msg.sender == dao, "Only dao");
        // The foundation slice is carved out of the dividend leg, so it counts against the same ceiling:
        // without it here the DAO could squeeze the dividend legs to zero (divBps would reach 0).
        require(_vaultBps > 0 && _vaultBps + _burnBps + foundationTaxBps < TAX_RATE, "Bad split");
        vaultRateBps = _vaultBps;
        burnRateBps = _burnBps;
    }

    /// V14: the community/foundation slice of the V2 tax, paid in **02** out of the dividend leg.
    /// `_bps` is in bps OF THE TRADE AMOUNT; it leaves the backing vault (1%) and the burn (0.5%) exactly
    /// as they are, and reduces the staking dividend leg from 1.5% to `1.5% - _bps`.
    /// `_bps == 0` (the default) switches the leg off and needs no sink, so an unconfigured deployment
    /// behaves precisely as before. Intended to become a DAO-owned ratio.
    function setFoundationTaxLeg(uint256 _bps, address _sink) external onlyOwner {
        require(_bps == 0 || _sink != address(0), "Sink required");
        require(vaultRateBps + burnRateBps + _bps < TAX_RATE, "Bad split");
        foundationTaxBps = _bps;
        foundationSink = _sink;
        emit FoundationTaxLegSet(_bps, _sink);
    }

    /// V15b: set the pool-tax scope, or seal it. `_scope` 0/1 = reversible (0 = tax every 02 pool, 1 =
    /// only the pool this protocol created); 2/3 = the same two, SEALED — once one of those is passed the
    /// scope can never change again. Owner-only like the other tax switches. The official pool is taxed
    /// in every mode, so this function can never switch off the protocol's own 3%.
    function setPoolTaxScope(uint8 _scope) external onlyOwner {
        // One message for both refusals on purpose ("already sealed" and "not a mode" are the only two ways
        // in), and it reuses a string the contract already carries: at the EIP-170 edge neither a second
        // check nor a fresh string is worth its bytes.
        require(poolTaxScope < 2 && _scope < 4, "Bad bps");
        poolTaxScope = _scope;
        emit PoolTaxScopeSet(_scope);
    }

    /* ============ V10 mint parameter governance (DAO) ============ */
    /// The DAO adjusts the mint parameters: **only two** — the BNB raise cap C and the per-address cumulative cap.
    ///
    /// The starting price / raise price are curve constants (see _applyMintDefaults): once initialized, no path can ever change them,
    /// neither the client nor the DAO can set prices; the multiple (= Pmax/P0 = 10x) is locked as well.
    /// After minting starts, C and the per-address cap **can only be lowered**: lowering C = hitting the cap earlier on the same curve,
    /// prices and multiple unchanged, issuance scales down proportionally, so the 21 million hard ceiling can never be breached.
    /// Hard constraint: worst-case total issuance worstCaseSupplyFor(...) ≤ MAX_SUPPLY (21 million 02)
    /// — note the check uses the "upper bound including discrete overshoot", not the continuous integral S (S is only a lower bound).
    /// All other mechanics are unchanged (fee 30%→5% with progress, 90/7/3 split, auto SUSPENDED at the cap, sell-back priced at the backing price).
    function setMintParams(uint256 _cap, uint256 _perAddressCap) external {
        require(msg.sender == dao, "Only dao");
        uint256 supply = validateMintParams(_cap, _perAddressCap);

        MINT_BNB_CAP        = _cap;
        PER_ADDRESS_BNB_CAP = _perAddressCap;

        // When the raise cap is lowered to (or below) the amount already minted, end the mint phase immediately so we never sit in the "cannot mint but not ended" intermediate state
        if (isMintPhase && totalMintedBNB >= _cap) {
            _endMintInternal();
        }

        emit MintParamsUpdated(_cap, _perAddressCap, supply);
    }

    /// Mint parameter validation (setMintParams and the DAO proposal preflight share **one entry point**, so the conditions never drift).
    /// Invalid input always reverts; on success it returns the theoretical total issuance S (1e18).
    ///
    /// Prices take no part in the check — they are not passable parameters at all (fixed in the contract, nobody can set them).
    /// Once minting has started (mintEnabled is true, or a mint has already happened):
    ///   - raise cap C: can only be lowered (lowering = hitting the cap sooner, issuance scales down);
    ///   - per-address cap: can only be lowered.
    /// Before minting starts both may be adjusted freely (still bounded by the 21 million ceiling and ≤ MAX_MINT_BNB).
    /// The tightening direction always keeps the brake of "lower C to the already-minted amount → end the mint phase early" (see setMintParams).
    function validateMintParams(uint256 _cap, uint256 _perAddressCap)
        public view returns (uint256 supply)
    {
        require(_cap >= totalMintedBNB, "Cap below minted");
        require(_cap >= 1e18 && _cap <= MAX_MINT_BNB, "Bad cap");
        require(_perAddressCap > 0 && _perAddressCap <= _cap / 10, "Bad per-address cap");

        // ---- after minting starts: both can only be lowered (prices are not parameters, so there is nothing to change) ----
        if (mintEnabled || totalMintedBNB > 0) {
            require(_cap <= MINT_BNB_CAP, "cap can only be lowered");
            require(_perAddressCap <= PER_ADDRESS_BNB_CAP, "per-address cap can only be lowered");
        }

        supply = theoreticalSupplyFor(_cap, PRICE_MIN, PRICE_MAX);
        // The 21 million ceiling is judged on the "worst case": the continuous integral S is only a lower bound, the discrete overshoot bound must be added
        require(worstCaseSupplyFor(_cap, PRICE_MIN, PRICE_MAX, _perAddressCap) <= MAX_SUPPLY, "Over max supply");
    }

    /// Theoretical total issuance under the current parameters (sell-back burns not counted), denominated in 02 (1e18 precision)
    function theoreticalSupply() external view returns (uint256) {
        return theoreticalSupplyFor(MINT_BNB_CAP, PRICE_MIN, PRICE_MAX);
    }

    /// Theoretical total issuance for the given curve parameters: S = C·ln(r)/(P0·(r−1)) (for DAO proposals / frontend preview)
    function theoreticalSupplyFor(uint256 _cap, uint256 _priceMin, uint256 _priceMax)
        public pure returns (uint256)
    {
        if (_cap == 0 || _priceMin == 0 || _priceMax <= _priceMin) return 0;
        uint256 r = (_priceMax * 1e18) / _priceMin;        // r (wad)
        uint256 denom = (_priceMin * (r - 1e18)) / 1e18;   // P0·(r−1)
        if (denom == 0) return type(uint256).max;
        return _mulDivUp(_cap, _lnWad(r), denom);
    }

    uint256 private constant LN2_WAD = 693147180559945309; // ln(2) × 1e18

    /// Worst-case total issuance upper bound (1e18) = continuous integral S + discrete mint overshoot bound.
    ///
    /// Mints are priced by "totalMintedBNB before this transaction" (left-value discrete summation), so actual issuance is always ≥ S.
    /// Let f(m) = 1e18 / price(m) (a convex function decreasing as m grows); the error of a single mint b_i over the interval is
    ///   b_i·f(m_i) − ∫ f ≤ b_i·[f(m_i) − f(m_i + b_i)]
    /// Telescope-summed this is ≤ PER_ADDRESS_BNB_CAP · [f(0) − f(C)], which is the overshoot bound below.
    /// (the `max(curve, backing)` markup only raises the execution price and reduces the minted amount; it does not change this bound.)
    /// On-chain this value ≤ MAX_SUPPLY is the condition for the 21 million hard ceiling — S alone meeting it is not enough.
    function worstCaseSupplyFor(
        uint256 _cap,
        uint256 _priceMin,
        uint256 _priceMax,
        uint256 _perAddressCap
    ) public pure returns (uint256) {
        uint256 s = theoreticalSupplyFor(_cap, _priceMin, _priceMax);
        if (s == type(uint256).max) return s; // degenerate curve (denom = 0) → keep the "guaranteed over limit" semantics
        if (_priceMin == 0 || _priceMax <= _priceMin || _perAddressCap == 0) return s;
        uint256 invMinWad = 1e36 / _priceMin; // (1e18 / P0)  × 1e18
        uint256 invMaxWad = 1e36 / _priceMax; // (1e18 / Pmax) × 1e18
        uint256 overshoot = (_perAddressCap * (invMinWad - invMaxWad)) / 1e18;
        return s + overshoot;
    }

    /// Fixed-point natural logarithm (input/output both 1e18 wad, domain x ≥ 1e18).
    /// Decompose x = 2^k·m (m ∈ [1e18, 2e18)) → ln x = k·ln2 + ln m;
    /// ln m = 2(z + z³/3 + z⁵/5 + …), z = (m−1)/(m+1) ≤ 1/3, taken out to the z²¹/21 term,
    /// relative error < 1e-13 (the 21 million ceiling check needs ~1e-8 precision, so there is ample margin).
    function _lnWad(uint256 x) internal pure returns (uint256) {
        require(x >= 1e18, "ln domain");
        uint256 k = 0;
        while (x >= 2e18) {
            x /= 2;
            k += 1;
        }
        uint256 z = ((x - 1e18) * 1e18) / (x + 1e18);
        uint256 z2 = (z * z) / 1e18;
        uint256 term = z;
        uint256 sum = z;
        for (uint256 i = 3; i <= 21; i += 2) {
            term = (term * z2) / 1e18;
            sum += term / i;
        }
        return 2 * sum + k * LN2_WAD;
    }

    /// mulDiv with round-up (the issuance check takes the conservative upper bound)
    function _mulDivUp(uint256 a, uint256 b, uint256 d) internal pure returns (uint256) {
        uint256 p = a * b;
        return p == 0 ? 0 : (p - 1) / d + 1;
    }
}
