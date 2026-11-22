// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

interface IUniswapV2Router02 {
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable;

    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountToken, uint256 amountETH, uint256 liquidity);
}

interface IPancakeFactory {
    function getPair(address tokenA, address tokenB) external view returns (address);
}

interface IPancakePair {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function token0() external view returns (address);
}

interface ITwoBurnable {
    function burn(uint256 amount) external;
}

interface IVaultDeposit {
    function addVaultBNB() external payable;
}

interface ILpPrincipalSink {
    function creditLpPrincipal(uint256 amount) external;
}

/// @title TwoBurnMineUpgradeable
/// @notice Burn-mine leg of the inflow plan. A deposit is split as the allocation table says:
///           · burn 0%–30%       → market-buy 02 and burn it (residual, capped)
///           · backing vault 5%  → TwoProtocol.addVaultBNB() (the floor rises for real)
///           · foundation 5%     → forwarded as BNB for community incentives (fixed)
///           · LP 0%–17.5%       → half buys 02, then paired into LP credited to LPReward stakers
///           · referral 3%–10%   → paid in BNB to the direct referrer, tier by direct volume
///           · the remainder     → this order's release (1% per day, paid in 02)
///
///         DYNAMIC ALLOCATION (V4). Payouts come first, burn is the residual. Each deposit buys a
///         floor slice for its own order, then tops the shared release pool up to `coverageDays` of
///         payouts at the price snapshot; only what is left goes to burn and LP, each capped. A
///         BNB buffer absorbs the gap when the price is high and pays it back when the price drops:
///           02 price up   → fewer tokens needed → less buying → more burn
///           02 price down → more tokens needed  → more buying → less burn
///         The reference behind this is a 24h average (hourly samples, each moving it by at most
///         1/24), so a single-block price push cannot move the split. Referral is fixed.
///
///         The release is GOLD-standard (USD-denominated): each day the order earns a rate of its USD
///         principal and converts those dollars into 02 at that moment's market price, so the token
///         amount moves with the price while the dollar amount does not. The rate is dynamic (V20):
///         it is 1%/day when the shared pool covers 40 days of payouts, 2%/day at 80 days, linear in
///         between and clamped to [1%, 2%]. A lifetime cap of 1× the USD principal means the rate only
///         changes how many days an order runs, never how much it pays in total; `exitMultipleBps`
///         (2×) still ends an order early if the 02 released so far is worth that much at market.
///
///         Buying is split on the BURN leg: half is bought and burned at deposit, the other half is
///         queued in a protocol-wide dip reserve and bought when the daily reference price drops by
///         `dipThresholdBps` (5% default). If the price never drops, the queue simply keeps
///         accumulating: there is no forced buy (the old `dipMaxWait` window is retired). The
///         operator executes those buys in several randomized tranches.
///
///         The RELEASE leg is bought in full at deposit and the order locks the 02 actually received.
///         There is no quote and no deferred half, so every order is fully backed by tokens already in
///         the pool: a price spike cannot create a shortfall and no foundation backstop is required.
///
///         Per-deposit size is capped (0.3–1 BNB) so a single buy can never move the pair on its own.
contract TwoBurnMineUpgradeable is
    Initializable,
    Ownable2StepUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
    uint256 internal constant RELEASE_DAYS = 100;
    uint256 internal constant BURN_MAX_BPS = 3_000;   // 30% — the other 5 points go to the foundation
    uint256 public constant FOUNDATION_BPS = 500;   // 5% of every deposit, funded from the burn leg
    uint256 public constant REF_MAX_BPS = 1_000;    // 10% cap for V3; Blue / Red / Color Diamond derive from it (up to 3×)
    /// Half of the BURN leg is executed at deposit, the other half waits for a dip (or `dipMaxWait`
    /// when that window is enabled).
    uint256 internal constant IMMEDIATE_BPS = 5_000;
    /// A dip must persist this long before it can be bought (spot-price manipulation guard).
    uint256 internal constant DIP_CONFIRM = 1 hours;
    /// A dip trigger is ignored when the daily reference is older than this.
    uint256 internal constant DIP_REF_MAX_AGE = 2 days;
    /// V20: dynamic rate. Coverage 40 days → 1%, 80 days → 2% (`currentRateBps`).
    uint16 public constant RATE_MIN_BPS = 100;
    uint16 public constant RATE_MAX_BPS = 200;
    uint256 private constant ONE = 1e18;

    struct Order {
        uint256 bnbIn;        // gross deposit
        uint256 releaseBnb;   // BNB side reserved for this order's release (informational)
        uint256 releaseTwo;   // 02 locked at the deposit price
        uint256 claimedTwo;   // 02 already released
        uint256 startTime;
    }

    IERC20 public twoToken;
    IERC20 public lpToken;
    address public router;
    address public factory;
    address public wbnb;
    address public usdt;
    address public vault;      // TwoProtocol (addVaultBNB)
    address public lpReward;   // LPReward (creditLpPrincipal)
    address public pair;       // 02/WBNB pair, for quotes

    uint256 public burnBps;
    uint256 public vaultBps;
    uint256 public lpBps;
    uint256 public refBpsBase;
    uint256 public refBpsV1;
    uint256 public refBpsV2;
    uint256 public refBpsV3;
    uint256 public tier1Bnb;
    uint256 public tier2Bnb;
    uint256 public tier3Bnb;
    uint256 private minSelfBurnUsd; // legacy USD gate (kept for the storage slot; the flat BNB gate is live)
    uint256 public minMineBnb;     // per-deposit floor (0.3 BNB)
    uint256 public maxMineBnb;     // per-deposit cap (1 BNB): keeps a single buy from moving the pair
    uint256 public slippageBps;
    bool public miningEnabled;
    address public operator;       // keeper allowed to execute dip buys

    mapping(address => Order[]) public orders;
    mapping(address => uint256) public orderCount;
    mapping(address => uint256) public totalDeposited;   // own cumulative deposits (USD gate and display)
    mapping(address => address) public referrers;       // user → direct referrer (one-time)
    mapping(address => uint256) public referralVolume;  // referrer → direct referrals' cumulative BNB
    mapping(address => uint256) public referralEarned;  // referrer → cumulative BNB received
    mapping(address => bool) public referralExempt;     // team / community-core whitelist: may refer without the gate and mine without a referrer

    uint256 public scheduledTotal;    // lifetime 02 promised to orders (diagnostics)
    uint256 public burnedBnb;         // BNB spent buying + burning 02
    uint256 public lpBnbUsed;         // BNB spent building LP
    uint256 public vaultBnbSent;      // BNB forwarded to the backing vault
    uint256 public vaultBnbPending;   // retired: now only readable (the 5% falls back to the foundation)
    uint256 public referralBnbPaid;   // BNB paid out as referral rewards

    // Pre-funded 02 budget (foundation / community donations). Claims are paid from it; the deferred
    // halves of the burn/release legs top it up again when they are bought.
    uint256 public twoPoolBudget;
    uint256 public twoPoolSpent;
    uint256 public surplusBnb;        // stray BNB (not owed to any order), sweepable by the owner

    // Deferred ("dip") reserve: the other half of the BURN leg. The release leg is bought in full at
    // deposit, so every order's 02 is already in the pool and no foundation backstop is ever needed.
    uint256 public dipBurnBnb;        // queued to buy + burn
    uint256 public dipBoughtBnb;      // lifetime BNB executed from the queue
    uint256 public dipRefPrice;       // daily reference: USD per 02, 1e18
    uint256 public dipRefTime;
    uint256 public dipThresholdBps;   // 800 = buy when the day's drop reaches 8%
    uint256 public dipEpochStart;     // retired (forced-buy clock); kept for storage layout and the UI
    uint256 public dipArmedAt;        // when the current dip was first observed

    // V2 (append-only): flat BNB gate for referral binding. When non-zero it replaces the USD gate
    // above, so the requirement no longer moves with the BNB price. 0 = fall back to minSelfBurnUsd.
    uint256 public minSelfMineBnb;

    // V3 (append-only): U-denominated perpetual release.
    // 20000 = an order stops producing once the 02 released so far is worth 2× its USD principal.
    uint256 public exitMultipleBps;
    mapping(address => mapping(uint256 => uint256)) public principalUsd; // order → USD principal, 1e18
    mapping(address => mapping(uint256 => bool)) public exited;          // order reached the exit cap

    // V4 (append-only): dynamic allocation. The release pool is paid first: every deposit buys a
    // floor slice for its own order, then lifts the shared pool to `coverageDays` of payouts at the
    // 24h price snapshot. Burn and LP only take what is left, capped at `burnBps` / `lpBps`.
    bool public dynamicEnabled;
    uint256 public releaseMinBps;      // floor slice that always backs an order (2000 = 20%)
    uint256 public coverageDays;       // pool top-up target = the 1% anchor of the V20 rate (40)
    uint256 public releaseReserveBnb;  // counter-cyclical BNB buffer for release top-ups
    uint256 public reserveCapBnb;      // soft cap on that buffer
    uint256 public dynSpot;            // 24h snapshot: 02 per BNB, 1e18
    uint256 public dynBnbUsd;          // 24h snapshot: USD per BNB, 1e18
    uint256 public dynUpdatedAt;       // timestamp of the last hourly average sample
    uint256 public activePrincipalUsd; // Σ USD principal of orders that are still producing

    // V5 (append-only): 5% of every deposit goes to the foundation (community incentives), paid for
    // by cutting the burn cap from 35% to 30%. Fixed like the vault leg, never part of the dynamics.
    address public foundation;
    uint256 private foundationBnbPending; // held here only if the transfer to the foundation fails

    // V6 (append-only): referral rewards are accrued and claimed by the referrer, not pushed.
    // `referralClaimable` is the BNB the referrer can withdraw (or route to the foundation / stake).
    mapping(address => uint256) public referralClaimable;

    // V7 (append-only): invite rights are granted automatically once a member's own cumulative
    // deposit reaches this amount, so the foundation does not have to whitelist every member.
    // 0 = disabled (whitelist only, the previous behaviour).
    uint256 public autoReferBnb;

    // V8 (append-only): limited role that may ONLY toggle referralExempt. Lets operations keep the
    // whitelist in sync after ownership moves to the foundation multisig, without granting upgrade
    // or fund-movement rights.
    address public referralOperator;

    // V9 (append-only): LP floor. This slice of every deposit is added to the pair before the release
    // pool and burn take their share, so liquidity grows on every deposit instead of only on residual.
    uint256 public lpMinBps;
    /// V10 (append-only): forced-buy window for the dip queue. 0 = never force-buy (the queue just
    /// waits for a dip); any positive value restores "buy after this long whatever the price".
    uint256 public dipMaxWait;

    /// V11 (append-only): retired USD ledger from an intermediate build. V18 reuses it as the
    /// **cumulative issued 02** per order (the frozen total once `exited`). Private: the public view is
    /// `claimableTwo` / `orderInfo`, so no getter bytes are spent at the EIP-170 edge.
    mapping(address => mapping(uint256 => uint256)) private claimedUsd;

    /// V12 (append-only): day-price history. V18 no longer reads it for accrual (the live price is read
    /// when `settle` runs); it is kept only as the frontend's "today's price" and is still written by
    /// the trade hook, claims and deposits.
    mapping(uint256 => uint256) public dayPrice;                       // unix day → USD per 02, 1e18
    mapping(address => mapping(uint256 => uint256)) public entryPrice; // order → deposit price, 1e18

    /// V18 (append-only): days already issued for an order. 0 = not seeded (orders created before the
    /// live-price engine were seeded once at the V18 upgrade). New orders start at 1 (day 1 is issued at
    /// deposit at the entry price).
    mapping(address => mapping(uint256 => uint256)) public settledDays;

    /// V19 (append-only): FIFO of every order, walked one gas-bounded slice per trigger. Any transfer
    /// on the 02 token pokes this contract, so a slice is settled at the live price of that moment and
    /// no keeper is required. An order enters at deposit (`mine`) or once through `seedQueue`.
    struct OrderRef {
        address user;
        uint32 index;
    }
    OrderRef[] public orderQueue;
    uint256 public queueCursor;      // next entry to settle
    uint256 public lastProcessBlock; // throttle: at most one walk per PROCESS_BLOCK_DEBT blocks
    uint256 public constant PROCESS_BLOCK_DEBT = 50;

    /// V20 (append-only): dynamic release rate. `paidUsd` enforces the lifetime 1× principal cap so
    /// the rate only changes the pace, never the total.
    mapping(address => mapping(uint256 => uint256)) private paidUsd;  // lifetime USD issued

    event ReferrerBound(address indexed user, address indexed referrer);
    event Mined(address indexed user, uint256 indexed index, uint256 bnbIn, uint256 burnBnb, uint256 burnTwo,
                uint256 vaultBnb, uint256 lpBnb, uint256 lpReceived, uint256 refBnb, uint256 reserveBnb,
                uint256 reserveTwo);
    event Released(address indexed user, uint256 indexed index, uint256 twoOut);
    event MiningEnabledSet(bool enabled);
    event AllocationSet(uint256 burnBps, uint256 vaultBps, uint256 lpBps);
    event ReferralTierSet(uint256 base, uint256 v1, uint256 v2, uint256 v3);
    event ReferralThresholdsSet(uint256 t1, uint256 t2, uint256 t3);
    event ReferralExemptSet(address indexed user, bool exempt);
    event AutoReferBnbSet(uint256 amount);
    event ReferralOperatorSet(address indexed operator);
    event Exited(address indexed user, uint256 indexed index, uint256 usdTarget);
    event DynamicEnabledSet(bool enabled);
    event DynamicParamsSet(uint256 coverageDays, uint256 releaseMinBps, uint256 reserveCapBnb);
    event DynamicUpdated(uint256 twoPerBnb, uint256 bnbUsd, uint256 at);
    event ReleaseReserveSet(uint256 reserveBnb);
    event PoolTopped(uint256 bnbIn, uint256 twoBought, bool fromReserve);
    event FoundationSet(address indexed foundation);
    event FoundationBnbPaid(address indexed foundation, uint256 amount);
    event FoundationBnbPending(uint256 amount, uint256 totalPending);
    event EndpointsSet(address vault, address lpReward, address router);
    event MinMineBnbSet(uint256 amount);
    event MaxMineBnbSet(uint256 amount);
    event OperatorSet(address indexed operator);
    event DipThresholdSet(uint256 bps);
    event DipArmed(uint256 at);
    event DipBought(uint256 bnbIn, uint256 burnBnb, uint256 burnTwo);
    event DipRefUpdated(uint256 price, uint256 at);
    event TwoPoolFunded(address indexed from, uint256 amount, uint256 budget);
    event TwoPoolDonated(address indexed from, uint256 amount);
    event SurplusSwept(address indexed to, uint256 amount);
    event VaultBnbPending(uint256 amount, uint256 totalPending);

    modifier onlyOperator() {
        require(msg.sender == operator || msg.sender == owner(), "Operator");
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _two,
        address _lpToken,
        address _router,
        address _factory,
        address _wbnb,
        address _usdt,
        address _vault,
        address _lpReward,
        address _pair
    ) external initializer {
        __Ownable2Step_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        twoToken = IERC20(_two);
        lpToken = IERC20(_lpToken);
        router = _router;
        factory = _factory;
        wbnb = _wbnb;
        usdt = _usdt;
        vault = _vault;
        lpReward = _lpReward;
        pair = _pair;

        burnBps = 3_000;
        vaultBps = 500;
        lpBps = 1_750;
        refBpsBase = 300;
        refBpsV1 = 500;
        refBpsV2 = 700;
        refBpsV3 = 1_000;
        tier1Bnb = 1e18;
        tier2Bnb = 5e18;
        tier3Bnb = 10e18;
        minSelfBurnUsd = 500e18;
        minSelfMineBnb = 0.5 ether;
        exitMultipleBps = 20_000;
        minMineBnb = 0.3 ether;
        maxMineBnb = 1 ether;
        slippageBps = 300;
        dipThresholdBps = 800;
        operator = msg.sender;
        miningEnabled = false;

        // V4 defaults. Dynamic allocation is switched on for the live proxy by the migration below;
        // a fresh deployment keeps the legacy static split until the owner turns it on.
        dynamicEnabled = false;
        releaseMinBps = 2_000;
        coverageDays = 40;
        reserveCapBnb = 5 ether;
        lpMinBps = 1_000;
        dipMaxWait = 0; // retired: the queue only buys on a real dip
    }

    function _authorizeUpgrade(address /*newImplementation*/) internal override onlyOwner {}

    /* ============ Owner configuration ============ */
    function setMiningEnabled(bool _enabled) external onlyOwner {
        miningEnabled = _enabled;
        emit MiningEnabledSet(_enabled);
    }

    /// EIP-170: the owner-only configuration paths share one custom error instead of one string each.
    error BadParam();

    /// Burn is capped at its configured share (0%–37%); LP is capped too. Under dynamic allocation
    /// both are maxima, and the release leg takes priority over them.
    function setAllocation(uint256 _burnBps, uint256 _vaultBps, uint256 _lpBps) external onlyOwner {
        if (_burnBps > BURN_MAX_BPS) revert BadParam();
        if (_vaultBps + _lpBps + _burnBps >= BPS) revert BadParam();
        // The highest referral tier must still leave room for the release slice; otherwise mine() reverts.
        if (_burnBps + _vaultBps + _lpBps + refBpsV3 * 3 >= BPS) revert BadParam();
        burnBps = _burnBps;
        vaultBps = _vaultBps;
        lpBps = _lpBps;
        emit AllocationSet(_burnBps, _vaultBps, _lpBps);
    }

    /// LP floor: this share of every deposit always goes into the pair (must stay ≤ `lpBps`).
    function setLpMinBps(uint256 _bps) external onlyOwner {
        if (_bps > lpBps) revert BadParam();
        lpMinBps = _bps;
    }

    function setReferralTiers(uint256 _base, uint256 _v1, uint256 _v2, uint256 _v3) external onlyOwner {
        if (!(_base <= _v1 && _v1 <= _v2 && _v2 <= _v3 && _v3 <= REF_MAX_BPS)) revert BadParam();
        if (burnBps + vaultBps + lpBps + _v3 * 3 >= BPS) revert BadParam();
        refBpsBase = _base;
        refBpsV1 = _v1;
        refBpsV2 = _v2;
        refBpsV3 = _v3;
        emit ReferralTierSet(_base, _v1, _v2, _v3);
    }

    function setReferralThresholds(uint256 _t1, uint256 _t2, uint256 _t3) external onlyOwner {
        if (!(_t1 > 0 && _t1 < _t2 && _t2 < _t3)) revert BadParam();
        tier1Bnb = _t1;
        tier2Bnb = _t2;
        tier3Bnb = _t3;
        emit ReferralThresholdsSet(_t1, _t2, _t3);
    }

    function setReferralExempt(address _user, bool _exempt) external {
        if (msg.sender != owner() && msg.sender != referralOperator) revert BadParam();
        referralExempt[_user] = _exempt;
        emit ReferralExemptSet(_user, _exempt);
    }

    /// Whitelist-only role: can flip `referralExempt` and nothing else. Keeps the list in sync after
    /// ownership is handed to the foundation multisig.
    function setReferralOperator(address _op) external onlyOwner {
        if (_op == address(0)) revert BadParam();
        referralOperator = _op;
        emit ReferralOperatorSet(_op);
    }

    /// Auto invite rights: once a member's own cumulative deposit reaches `_amount` BNB, the next
    /// deposit flips `referralExempt[user]` on. 0 disables the rule (whitelist only).
    function setAutoReferBnb(uint256 _amount) external onlyOwner {
        autoReferBnb = _amount;
        emit AutoReferBnbSet(_amount);
    }

    /// 2× by default. Bounds keep the target meaningful (1×–10× of the USD principal).
    function setExitMultipleBps(uint256 _bps) external onlyOwner {
        if (_bps < 10_000 || _bps > 100_000) revert BadParam();
        exitMultipleBps = _bps;
    }

    function setFoundation(address _foundation) external onlyOwner {
        if (_foundation == address(0)) revert BadParam();
        foundation = _foundation;
        emit FoundationSet(_foundation);
    }

    /// 5% slice. Any amount that could not be delivered is retried with the next deposit, so nothing
    /// is ever lost and no separate flush call is needed.
    function _payFoundation(uint256 amount) internal {
        uint256 due = foundationBnbPending + amount;
        (bool ok, ) = payable(foundation).call{value: due}("");
        if (ok) {
            foundationBnbPending = 0;
            emit FoundationBnbPaid(foundation, due);
        } else {
            foundationBnbPending = due;
            emit FoundationBnbPending(due, due);
        }
    }

    function setDynamicEnabled(bool _enabled) external onlyOwner {
        dynamicEnabled = _enabled;
        emit DynamicEnabledSet(_enabled);
    }

    /// `coverageDays` = how many days of payouts the shared release pool should hold.
    /// `releaseMinBps` = the slice every deposit always buys for its own order (10%–35%).
    /// `reserveCapBnb` = soft cap on the counter-cyclical BNB buffer.
    function setDynamicParams(uint256 _coverageDays, uint256 _releaseMinBps, uint256 _reserveCapBnb)
        external
        onlyOwner
    {
        if (_coverageDays == 0 || _coverageDays > 365) revert BadParam();
        if (_releaseMinBps < 1_000 || _releaseMinBps > 3_500) revert BadParam();
        coverageDays = _coverageDays;
        releaseMinBps = _releaseMinBps;
        reserveCapBnb = _reserveCapBnb;
        emit DynamicParamsSet(_coverageDays, _releaseMinBps, _reserveCapBnb);
    }

    /// 24h-average price reference, sampled hourly. Anyone may call, at most once per hour, and each
    /// sample moves the reference only 1/24 of the way to spot. A single block's manipulated price
    /// therefore barely registers, while a genuine move is fully priced in after about a day — the
    /// split is sized off an average, never off the instantaneous price.
    function sampleDynamic() external {
        require(dynUpdatedAt == 0 || block.timestamp >= dynUpdatedAt + 1 hours, "Soon");
        uint256 spot = _spotTwoPerBnb();
        uint256 usd = bnbUsdPrice();
        require(spot > 0 && usd > 0, "No price");
        if (dynSpot == 0 || dynBnbUsd == 0) {
            dynSpot = spot;
            dynBnbUsd = usd;
        } else {
            dynSpot = (dynSpot * 23 + spot) / 24;
            dynBnbUsd = (dynBnbUsd * 23 + usd) / 24;
        }
        dynUpdatedAt = block.timestamp;
        emit DynamicUpdated(dynSpot, dynBnbUsd, block.timestamp);
    }

    /// Per-deposit floor. 0.3 BNB keeps a single order's 100-day schedule meaningful.
    function setMinMineBnb(uint256 _min) external onlyOwner {
        if (_min == 0 || _min > maxMineBnb) revert BadParam();
        minMineBnb = _min;
        emit MinMineBnbSet(_min);
    }

    /// Per-deposit cap. Keeping one deposit at ≤1 BNB means no single burn/LP buy can move the pair.
    function setMaxMineBnb(uint256 _max) external onlyOwner {
        if (_max < minMineBnb) revert BadParam();
        maxMineBnb = _max;
        emit MaxMineBnbSet(_max);
    }

    function setOperator(address _operator) external onlyOwner {
        if (_operator == address(0)) revert BadParam();
        operator = _operator;
        emit OperatorSet(_operator);
    }

    function setDipThreshold(uint256 _bps) external onlyOwner {
        if (_bps > 5_000) revert BadParam();
        dipThresholdBps = _bps;
        emit DipThresholdSet(_bps);
    }

    /// Retired: the dip queue only buys on a real dip (`dipMaxWait` is always 0). The variable and
    /// getter are kept so the keeper's read keeps working and the storage slot is not reused.
    function setSlippageBps(uint256 _bps) external onlyOwner {
        if (_bps < 100 || _bps > 1_000) revert BadParam();
        slippageBps = _bps;
    }

    function setEndpoints(address _vault, address _lpReward, address _router) external onlyOwner {
        if (_vault == address(0) || _lpReward == address(0) || _router == address(0)) revert BadParam();
        vault = _vault;
        lpReward = _lpReward;
        router = _router;
        emit EndpointsSet(_vault, _lpReward, _router);
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    /* ============ 02 budget ============ */
    /// Donation entry for the release pool (approve + pull). Permissionless: the only thing a caller
    /// can do is hand 02 over.
    function donateTwo(uint256 amount) external nonReentrant {
        require(amount > 0, "Zero");
        _pullTwo(msg.sender, amount);
        emit TwoPoolDonated(msg.sender, amount);
    }

    /// Credits 02 that was sent to this contract with a plain transfer (no approve, no call).
    function syncBudget() external nonReentrant returns (uint256 credited) {
        uint256 balance = twoToken.balanceOf(address(this));
        credited = balance > twoPoolBudget ? balance - twoPoolBudget : 0;
        require(credited > 0, "None");
        twoPoolBudget += credited;
        emit TwoPoolDonated(address(this), credited);
    }

    function _pullTwo(address from, uint256 amount) internal {
        uint256 before = twoToken.balanceOf(address(this));
        twoToken.safeTransferFrom(from, address(this), amount);
        uint256 received = twoToken.balanceOf(address(this)) - before;
        require(received > 0, "Zero");
        twoPoolBudget += received;
        emit TwoPoolFunded(from, received, twoPoolBudget);
    }

    /// Moves BNB that is not owed to any order (stray transfers / router refunds).
    function sweepSurplusBnb(address to, uint256 amount) external onlyOwner nonReentrant {
        require(to != address(0), "Zero");
        require(amount <= surplusBnb, "Max");
        surplusBnb -= amount;
        (bool ok, ) = payable(to).call{value: amount}("");
        require(ok, "Transfer");
        emit SurplusSwept(to, amount);
    }

    /* ============ Referral ============ */
    /// Binding is mandatory before mining. The gate sits on the *inviter*: the address must be
    /// whitelisted (`canRefer`) or have reached the automatic threshold `autoReferBnb`. Members then
    /// start mining with that binding.
    function bindReferrer(address ref) external {
        require(ref != address(0), "Zero");
        require(ref != msg.sender, "Self");
        require(referrers[msg.sender] == address(0), "Bound");
        require(canRefer(ref), "Ref");
        referrers[msg.sender] = ref;
        emit ReferrerBound(msg.sender, ref);
    }

    /// Invite rights come from the whitelist, plus the automatic rule: a member whose own cumulative
    /// deposit has reached `autoReferBnb` qualifies even before their next deposit flips the flag
    /// (existing depositors are covered retroactively). `minSelfMineBnb` is kept for storage
    /// compatibility but no longer opens the gate.
    function canRefer(address user) public view returns (bool) {
        return referralExempt[user] || (autoReferBnb > 0 && totalDeposited[user] >= autoReferBnb);
    }

    /// V19.1: owner-only correction for chained self-referrals. Direct referral volume is credited to the
    /// IMMEDIATE referrer only, so a chain of one's own wallets (A→B→C…) never accumulates on the wallet
    /// the operator wants to rank up. This moves that number — not tokens, not orders — between wallets.
    function moveReferralVolume(address from, address to, uint256 amount) external onlyOwner {
        if (from == address(0) || to == address(0) || from == to || amount == 0) revert BadParam();
        if (referralVolume[from] < amount) revert BadParam();
        referralVolume[from] -= amount;
        referralVolume[to] += amount;
    }

    /// Seven direct-referral tiers (based on direct referral volume only): Agate 3% → Crystal 5% →
    /// Emerald 7% → White Diamond 10% → Blue Diamond 15% → Red Diamond 20% → Color Diamond 30%.
    /// The top three are derived from the highest tier (threshold ×2 / ×5 / ×10, rebate +500bp / ×2 / ×3)
    /// so they need no extra storage slot or setter — the implementation bytecode is already close to
    /// the EIP-170 limit (24,451 / 24,576).
    function referralBpsFor(address ref) public view returns (uint256) {
        uint256 v = referralVolume[ref];
        uint256 t3 = tier3Bnb;
        if (v >= t3) {
            uint256 m = v / t3; // 1 = White Diamond, 2–4 = Blue Diamond, 5–9 = Red Diamond, ≥10 = Color Diamond
            uint256 v3 = refBpsV3;
            if (m >= 10) return v3 * 3;
            if (m >= 5) return v3 * 2;
            if (m >= 2) return v3 + 500;
            return v3;
        }
        if (v >= tier2Bnb) return refBpsV2;
        if (v >= tier1Bnb) return refBpsV1;
        return refBpsBase;
    }

    /// Claims the accrued referral BNB. `toFoundation` routes the whole balance to the foundation
    /// instead of the caller's wallet; the "buy 02 and stake" option claims to the wallet first and
    /// then runs the normal buy-and-stake flow from the frontend.
    function claimReferral(bool toFoundation) external nonReentrant {
        uint256 amount = referralClaimable[msg.sender];
        require(amount > 0, "None");
        referralClaimable[msg.sender] = 0;
        address to = toFoundation ? foundation : msg.sender;
        require(to != address(0), "Zero");
        (bool ok, ) = payable(to).call{value: amount}("");
        require(ok, "Transfer");
    }

    /* ============ Mine ============ */
    function mine() external payable nonReentrant whenNotPaused {
        require(miningEnabled, "Closed");
        require(referrers[msg.sender] != address(0) || canRefer(msg.sender), "Bind");
        require(msg.value >= minMineBnb, "Min");
        require(msg.value <= maxMineBnb, "Max");

        address ref = referrers[msg.sender];
        uint256 refBps = ref != address(0) ? referralBpsFor(ref) : 0;

        uint256 vaultBnb = (msg.value * vaultBps) / BPS;
        uint256 refBnb = (msg.value * refBps) / BPS;
        uint256 foundationBnb = foundation == address(0) ? 0 : (msg.value * FOUNDATION_BPS) / BPS;
        if (foundationBnb > 0) _payFoundation(foundationBnb);
        uint256 burnBnb;
        uint256 lpBnb;
        uint256 reserveBnb;
        if (dynamicEnabled) {
            (burnBnb, lpBnb, reserveBnb) = _allocateDynamic(msg.value, vaultBnb + foundationBnb, refBnb);
        } else {
            burnBnb = (msg.value * burnBps) / BPS;
            lpBnb = (msg.value * lpBps) / BPS;
            reserveBnb = msg.value - burnBnb - vaultBnb - lpBnb - refBnb - foundationBnb;
        }

        // 1) burn: half now, half queued for a dip
        uint256 burnNow = (burnBnb * IMMEDIATE_BPS) / BPS;
        uint256 burnLater = burnBnb - burnNow;
        uint256 burnTwo = _buyAndBurn(burnNow);

        // 2) backing vault. addVaultBNB() is live on the protocol; if that call ever fails the slice
        //    is forwarded to the foundation instead of being parked here (the old pending pot is retired).
        if (vaultBnb > 0) {
            try IVaultDeposit(vault).addVaultBNB{value: vaultBnb}() {
                vaultBnbSent += vaultBnb;
            } catch {
                _payFoundation(vaultBnb);
            }
        }

        // 3) LP: half buys 02, then paired; the LP is booked to stakers, not paid out
        uint256 lpReceived = _buildLp(lpBnb);

        // 4) referral: accrued to the referrer, who claims it later (wallet, foundation or stake).
        //    There is no self-mining gate on the payout: the referrer earns from the very first
        //    referred deposit. Cumulative direct volume only decides the tier (3% → 10%).
        if (ref != address(0)) {
            referralVolume[ref] += msg.value;
            if (refBnb > 0) {
                referralClaimable[ref] += refBnb;
                referralEarned[ref] += refBnb;
                referralBnbPaid += refBnb;
            }
        }

        // 5) release: buy the whole release slice now and lock the 02 actually received. No quote and
        //    no deferred half: the order is fully backed by tokens already sitting in the pool, so a
        //    price spike can never create a shortfall and no foundation backstop is needed.
        uint256 releaseTwo = 0;
        if (reserveBnb > 0) {
            uint256 minOut = (_quoteTwoOut(reserveBnb) * (BPS - slippageBps)) / BPS;
            releaseTwo = _buyTwo(reserveBnb, minOut);
            twoPoolBudget += releaseTwo;
        }
        require(releaseTwo > 0, "Zero");

        dipBurnBnb += burnLater;

        uint256 index = orderCount[msg.sender];
        orders[msg.sender].push(Order({
            bnbIn: msg.value,
            releaseBnb: reserveBnb,
            releaseTwo: releaseTwo,
            claimedTwo: 0,
            startTime: block.timestamp
        }));
        orderCount[msg.sender] += 1;
        orderQueue.push(OrderRef(msg.sender, uint32(index)));
        totalDeposited[msg.sender] += msg.value;
        scheduledTotal += releaseTwo;

        // 6) invite rights: a member whose own cumulative deposit reaches `autoReferBnb` becomes a
        //    qualified inviter automatically, so the foundation does not have to whitelist every
        //    member by hand. 0 keeps the whitelist-only behaviour.
        if (!referralExempt[msg.sender] && canRefer(msg.sender)) {
            referralExempt[msg.sender] = true;
            emit ReferralExemptSet(msg.sender, true);
        }

        // USD principal fixes the day count in dollars (1% per day, 2× cap). The entry price is the
        // market price at deposit and prices day 1 of this order.
        uint256 usd = bnbUsdPrice();
        require(usd > 0, "No price");
        uint256 usdPrincipal = (msg.value * usd) / ONE;
        principalUsd[msg.sender][index] = usdPrincipal;
        activePrincipalUsd += usdPrincipal;
        uint256 ep = twoUsdPrice();
        require(ep > 0, "No price");
        entryPrice[msg.sender][index] = ep;
        // V18: day 1 is issued right here at the deposit price, and is fixed from now on.
        claimedUsd[msg.sender][index] = ((usdPrincipal / RELEASE_DAYS) * ONE) / ep;
        settledDays[msg.sender][index] = 1;
        _pokeDayPrice();

        emit Mined(msg.sender, index, msg.value, burnBnb, burnTwo, vaultBnb, lpBnb, lpReceived, refBnb,
                   reserveBnb, releaseTwo);
    }

    /* ============ Release (V18: live-price settlement, V19: queue) ============ */
    /// Day 1 is issued at deposit, at the entry price. Every later day is issued when the order is
    /// settled for the first time after that 24h boundary, at the live price of that moment — no
    /// historical price is stored, so there is nothing to read back. The issued amount is fixed once
    /// settled; claiming is only a withdrawal and never changes it.
    function dailyTwo(address user, uint256 index) public view returns (uint256) {
        if (index >= orderCount[user] || exited[user][index]) return 0;
        uint256 principal = principalUsd[user][index];
        uint256 spot = twoUsdPrice();
        if (principal == 0 || spot == 0) return 0;
        return (((principal * currentRateBps()) / BPS) * ONE) / spot;
    }

    /// Records today's price if the day has no snapshot yet. Anyone's first claim/deposit of the day
    /// fills it in; the keeper is optional and there is no fixed time of day involved.
    function _pokeDayPrice() internal {
        uint256 today = block.timestamp / 1 days;
        // Writing a fresh read of 0 is a no-op on an already-zero slot, so no `> 0` guard is needed:
        // a day with no price stays empty and the next interaction retries.
        if (dayPrice[today] == 0) dayPrice[today] = twoUsdPrice();
    }

    /// V17/V19: entry point for the 02 token's transfer hook (TwoProtocol.tradeHook). Every transfer
    /// pings it, not just V2 trades: it records today's price and settles one gas-bounded slice of the
    /// order queue at that moment's live price, so release settlement keeps pace with real usage and no
    /// keeper is needed. Deliberately NOT `nonReentrant`: the token pings it from inside `mine()`'s buy
    /// swap, where this contract's own lock is held; it only writes release accounting.
    function pokeDayPrice() external {
        _pokeDayPrice();
        _processOrders(200_000);
    }

    /// V19: settle one FIFO slice of the order queue within `gasBudget` of gas. Public so the keeper
    /// can still nudge it; a transfer on the token does the same thing automatically.
    function processOrders(uint256 gasBudget) external {
        _processOrders(gasBudget);
    }

    function _processOrders(uint256 gasBudget) internal {
        // One walk per PROCESS_BLOCK_DEBT blocks: a burst of transfers must not pay for the whole queue
        // several times in one block, and each slice settles at the price of its own trigger block.
        // `lastProcessBlock == 0` means "never walked yet", which must NOT be throttled (a fresh
        // deployment would otherwise idle for the first 50 blocks).
        if (lastProcessBlock != 0 && block.number < lastProcessBlock + PROCESS_BLOCK_DEBT) return;
        uint256 n = orderQueue.length;
        if (n == 0) return;
        uint256 spot = twoUsdPrice();
        if (spot == 0) return;
        uint256 startGas = gasleft();
        lastProcessBlock = block.number;
        uint256 i = queueCursor;
        uint256 rate = currentRateBps(); // one rate per walk: all orders in this slice use the same day's rate
        for (uint256 k = 0; k < n; k++) {
            // Keep enough gas to finish the surrounding transfer; stop when the slice budget is spent.
            if (gasleft() < 120_000 || startGas - gasleft() > gasBudget) break;
            OrderRef storage r = orderQueue[i];
            _settleAt(r.user, r.index, spot, rate);
            i = i + 1 == n ? 0 : i + 1;
        }
        queueCursor = i;
    }

    // V20: `seedQueue` retired — every order is enqueued in `mine()` and the V19 migration is done.

    /// Number of entries in the settlement queue (diagnostics / keeper).
    function queueLength() external view returns (uint256) {
        return orderQueue.length;
    }

    /// V18: issue every whole day that has elapsed since the last settlement, at the live price.
    /// Permissionless on purpose — the first call after a 24h boundary fixes that day's price, which is
    /// exactly what "the price 24h later" means on-chain (there is no history to read back). A missed
    /// boundary is caught up here at this call's price. V20: the days are paid at `currentRateBps()`
    /// and trimmed so an order never pays more than 1× its USD principal over its life nor more than
    /// `exitMultipleBps` × the principal in market value; reaching either limit exits the order.
    function settle(address user, uint256 index) public {
        uint256 spot = twoUsdPrice();
        if (spot == 0) return; // no price: nothing is recorded, the next call retries
        _settleAt(user, index, spot, currentRateBps());
    }

    function _settleAt(address user, uint256 index, uint256 spot, uint256 rate) internal {
        if (index >= orderCount[user] || exited[user][index]) return;
        uint256 principal = principalUsd[user][index];
        if (principal == 0) return;
        Order storage o = orders[user][index];
        uint256 sd = settledDays[user][index];
        if (sd == 0) return; // not seeded: never issued (all live orders are seeded)
        uint256 issued = claimedUsd[user][index];
        uint256 targetUsd = (principal * exitMultipleBps) / BPS;
        uint256 valueNow = (issued * spot) / ONE;
        if (valueNow >= targetUsd) {
            _exit(user, index, issued, principal);
            return;
        }
        uint256 daysTotal = (block.timestamp - o.startTime) / 1 days + 1;
        if (daysTotal <= sd) return;
        uint256 perDay = (principal * rate) / BPS;
        if (perDay == 0) return;
        uint256 paid = paidUsd[user][index];
        if (paid == 0) paid = (sd * principal) / RELEASE_DAYS; // legacy: 1%/day history
        uint256 due = daysTotal - sd;
        uint256 maxDays = (targetUsd - valueNow) / perDay;                       // 2× market cap
        uint256 capDays = paid >= principal ? 0 : (principal - paid) / perDay;   // lifetime 1× cap
        if (capDays < maxDays) maxDays = capDays;
        bool capped = due >= maxDays;
        if (due > maxDays) due = maxDays;
        if (due > 0) {
            uint256 addUsd = due * perDay;
            paidUsd[user][index] = paid + addUsd;
            issued += (addUsd * ONE) / spot;
            claimedUsd[user][index] = issued;
            settledDays[user][index] = sd + due;
        }
        if (capped) _exit(user, index, issued, principal);
    }

    /// V20: rate for the release, read at settlement time. Coverage is how many days of 1% payouts
    /// the release pool could fund: 40 days → 1%, 80 days → 2%, linear in between, clamped to
    /// [1%, 2%]. The price comes from the 24h snapshot (`sampleDynamic`), so one block cannot move it.
    function currentRateBps() public view returns (uint256 r) {
        uint256 a = activePrincipalUsd;
        if (a == 0 || dynSpot == 0) return RATE_MIN_BPS;
        r = (twoPoolBudget * dynBnbUsd * 250) / (dynSpot * a); // coverage days × 2.5
        if (r < RATE_MIN_BPS) return RATE_MIN_BPS;
        if (r > RATE_MAX_BPS) return RATE_MAX_BPS;
    }

    function _exit(address user, uint256 index, uint256 issued, uint256 principal) private {
        exited[user][index] = true;
        activePrincipalUsd = principal >= activePrincipalUsd ? 0 : activePrincipalUsd - principal;
        emit Exited(user, index, issued);
    }

    function claimableTwo(address user, uint256 index) public view returns (uint256) {
        if (index >= orderCount[user]) return 0;
        uint256 issued = claimedUsd[user][index];
        uint256 claimed = orders[user][index].claimedTwo;
        return issued > claimed ? issued - claimed : 0;
    }

    /// Pays the unlocked 02 straight out of the shared release pool.
    /// Orders are priced by `settle` (the first call after each 24h boundary); a claim only withdraws
    /// what has already been issued, so the claim moment never changes the amount.
    function claim(uint256 index) external nonReentrant whenNotPaused {
        require(index < orderCount[msg.sender], "Range");
        Order storage o = orders[msg.sender][index];
        _pokeDayPrice();

        settle(msg.sender, index); // first call after the boundary fixes that day's price
        uint256 issued = claimedUsd[msg.sender][index];
        require(issued > o.claimedTwo, "Empty");

        uint256 due = issued - o.claimedTwo;
        if (due > twoPoolBudget) due = twoPoolBudget;
        require(due > 0, "No reserve");
        twoPoolBudget -= due;
        twoPoolSpent += due;
        o.claimedTwo += due;
        twoToken.safeTransfer(msg.sender, due);
        emit Released(msg.sender, index, due);
    }

    /* ============ Dip reserve ============ */
    /// Daily reference price in USD per 02 (1e18). Call once a day; anyone may call, at most once per 24h.
    /// USD (not 02/BNB) is the unit on purpose: a drop must mean the token got cheaper for holders,
    /// whichever side of the pair moved.
    function updateDipReference() external {
        require(dipRefTime == 0 || block.timestamp >= dipRefTime + 1 days, "Too soon");
        _storeDipRef();
    }

    /// One-off after the USD-denominated upgrade: rewrites the reference in the new unit without
    /// waiting out the 24h cooldown (the stored value would otherwise be read as USD).
    function resetDipReference() external onlyOwner {
        _storeDipRef();
    }

    function _storeDipRef() internal {
        uint256 spot = twoUsdPrice();
        require(spot > 0, "No price");
        dipRefPrice = spot;
        dipRefTime = block.timestamp;
        // Same call also stores the day's price used by the daily release accrual.
        dayPrice[block.timestamp / 1 days] = spot;
        emit DipRefUpdated(spot, block.timestamp);
    }

    /// Arms a dip: the drop must persist for DIP_CONFIRM before a buy is allowed. Recovery disarms.
    function armDip() external {
        uint256 drop = dipDropBps();
        if (dipThresholdBps > 0 && drop >= dipThresholdBps) {
            if (dipArmedAt == 0) {
                dipArmedAt = block.timestamp;
                emit DipArmed(block.timestamp);
            }
        } else if (dipArmedAt != 0) {
            dipArmedAt = 0;
        }
    }

    /// Current drop from the daily reference, in bps of the USD price (0 when unavailable or price up).
    function dipDropBps() public view returns (uint256) {
        uint256 ref = dipRefPrice;
        if (ref == 0) return 0;
        uint256 spot = twoUsdPrice();
        if (spot == 0 || spot >= ref) return 0;
        return ((ref - spot) * BPS) / ref;
    }

    /// Operator entry for one randomized tranche. The keeper fires several of these with random sizes
    /// through a private bundle; the contract only verifies the trigger and the slippage floor.
    function executeDipBuy(uint256 bnbAmount, uint256 minTwoOut) external onlyOperator nonReentrant whenNotPaused {
        require(bnbAmount > 0 && bnbAmount <= dipBurnBnb, "Amt");
        require(dipThresholdBps > 0 && dipDropBps() >= dipThresholdBps, "Dip");
        require(dipArmedAt > 0 && block.timestamp >= dipArmedAt + DIP_CONFIRM, "Arm");
        require(dipRefTime > 0 && block.timestamp <= dipRefTime + DIP_REF_MAX_AGE, "Stale");
        _executeDip(bnbAmount, minTwoOut);
    }

    function _executeDip(uint256 bnbAmount, uint256 minTwoOut) internal {
        uint256 floor = (_quoteTwoOut(bnbAmount) * (BPS - slippageBps)) / BPS;
        require(minTwoOut > 0 && minTwoOut >= floor, "Slip");

        uint256 bought = _buyTwo(bnbAmount, minTwoOut);
        if (bought > 0) {
            ITwoBurnable(address(twoToken)).burn(bought);
            burnedBnb += bnbAmount;
        }

        dipBurnBnb -= bnbAmount;
        dipBoughtBnb += bnbAmount;
        if (dipBurnBnb == 0) dipArmedAt = 0;
        emit DipBought(bnbAmount, bnbAmount, bought);
    }

    /* ============ Internals ============ */
    /// Payout-first waterfall for one deposit under dynamic allocation.
    ///   0. the LP floor (`lpMinBps`) is set aside first, so every deposit mints liquidity
    ///   1. spend the counter-cyclical buffer on the pool gap first (it was built at a high price)
    ///   2. buy this order's floor slice, plus whatever the shared pool still needs
    ///   3. burn gets the residual, capped at `burnBps` (0–37%)
    ///   4. LP gets the floor plus the next residual, capped at `lpBps`
    ///   5. anything left refills the buffer (up to its cap); past the cap it buys pool 02
    /// A 02 price rise shrinks the token gap, so less is bought and more is burned; a drop widens
    /// it, so more is bought and burn shrinks — exactly the counter-cyclical behaviour we want.
    function _allocateDynamic(uint256 value, uint256 fixedBnb, uint256 refBnb)
        internal
        returns (uint256 burnBnb, uint256 lpBnb, uint256 releaseBnb)
    {
        uint256 afterFixed = value - fixedBnb - refBnb;

        // 0) LP floor comes off the top so every deposit mints liquidity; `lpBps` stays the ceiling.
        uint256 lpFloorBnb = (value * lpMinBps) / BPS;
        if (lpFloorBnb > afterFixed) lpFloorBnb = afterFixed;
        afterFixed -= lpFloorBnb;
        uint256 floorBnb = (afterFixed * releaseMinBps) / BPS;

        // 1) the shared pool is short: deploy the buffer instead of eating into the burn
        uint256 gap = releaseGapBnb();
        if (gap > 0) {
            uint256 useReserve = gap < releaseReserveBnb ? gap : releaseReserveBnb;
            if (useReserve > 0) {
                releaseReserveBnb -= useReserve;
                uint256 bought = _buyIntoPool(useReserve);
                emit PoolTopped(useReserve, bought, true);
                gap -= useReserve;
            }
        }

        // 2) this order's own slice plus the remaining pool need, never above the deposit
        uint256 room = afterFixed - floorBnb;
        uint256 extra = gap < room ? gap : room;
        releaseBnb = floorBnb + extra;
        uint256 rest = afterFixed - releaseBnb;

        // 3) burn is the residual, capped
        uint256 burnCap = (value * burnBps) / BPS;
        burnBnb = rest < burnCap ? rest : burnCap;
        rest -= burnBnb;

        // 4) LP follows: the floor already set aside, plus whatever the cap still allows
        uint256 lpCap = (value * lpBps) / BPS;
        uint256 lpRoom = lpCap > lpFloorBnb ? lpCap - lpFloorBnb : 0;
        uint256 lpExtra = rest < lpRoom ? rest : lpRoom;
        lpBnb = lpFloorBnb + lpExtra;
        rest -= lpExtra;

        // 5) the remainder is the counter-cyclical buffer; past its cap it tops the pool up
        if (rest > 0) {
            uint256 roomReserve = reserveCapBnb > releaseReserveBnb ? reserveCapBnb - releaseReserveBnb : 0;
            uint256 toReserve = rest < roomReserve ? rest : roomReserve;
            releaseReserveBnb += toReserve;
            rest -= toReserve;
            if (rest > 0) {
                uint256 bought = _buyIntoPool(rest);
                emit PoolTopped(rest, bought, false);
            }
        }
    }

    /// BNB still needed to lift the shared release pool to `coverageDays` of payouts, priced off the
    /// cached 24h snapshot. 0 when dynamic allocation is off, the snapshot is cold, or the pool
    /// already covers the target.
    function releaseGapBnb() public view returns (uint256) {
        if (!dynamicEnabled || dynSpot == 0 || dynBnbUsd == 0) return 0;
        uint256 targetTwo = (activePrincipalUsd * coverageDays * dynSpot) / (RELEASE_DAYS * dynBnbUsd);
        if (twoPoolBudget >= targetTwo) return 0;
        return ((targetTwo - twoPoolBudget) * ONE) / dynSpot;
    }

    function _buyIntoPool(uint256 bnbAmount) internal returns (uint256 bought) {
        if (bnbAmount == 0) return 0;
        uint256 minOut = (_quoteTwoOut(bnbAmount) * (BPS - slippageBps)) / BPS;
        bought = _buyTwo(bnbAmount, minOut);
        twoPoolBudget += bought;
    }

    function _buyAndBurn(uint256 bnbAmount) internal returns (uint256 bought) {
        if (bnbAmount == 0) return 0;
        uint256 minOut = (_quoteTwoOut(bnbAmount) * (BPS - slippageBps)) / BPS;
        bought = _buyTwo(bnbAmount, minOut);
        if (bought > 0) {
            ITwoBurnable(address(twoToken)).burn(bought);
            burnedBnb += bnbAmount;
        }
    }

    function _buyTwo(uint256 bnbAmount, uint256 minOut) internal returns (uint256 bought) {
        if (bnbAmount == 0) return 0;
        require(minOut > 0, "No price");
        uint256 before = twoToken.balanceOf(address(this));
        address[] memory path = new address[](2);
        path[0] = wbnb;
        path[1] = address(twoToken);
        IUniswapV2Router02(router).swapExactETHForTokensSupportingFeeOnTransferTokens{value: bnbAmount}(
            minOut,
            path,
            address(this),
            block.timestamp + 300
        );
        bought = twoToken.balanceOf(address(this)) - before;
    }

    /// Half the slice buys 02, then both sides are paired into new LP sent to LPReward and booked as
    /// principal. Nothing is paid to stakers directly — they claim after their own stake matures.
    function _buildLp(uint256 bnbAmount) internal returns (uint256 lpAmount) {
        if (bnbAmount == 0) return 0;
        uint256 half = bnbAmount / 2;
        if (half == 0) return 0;

        uint256 minOut = (_quoteTwoOut(half) * (BPS - slippageBps)) / BPS;
        uint256 before = twoToken.balanceOf(address(this));
        address[] memory path = new address[](2);
        path[0] = wbnb;
        path[1] = address(twoToken);
        IUniswapV2Router02(router).swapExactETHForTokensSupportingFeeOnTransferTokens{value: half}(
            minOut,
            path,
            address(this),
            block.timestamp + 300
        );
        uint256 bought = twoToken.balanceOf(address(this)) - before;
        if (bought == 0) return 0;

        twoToken.safeApprove(router, 0);
        twoToken.safeApprove(router, bought);
        // Do not add liquidity with 0/0 minimums: a sandwich can otherwise force an unfavourable mix
        // and leak value out of the LP slice. Both sides are floored at the configured slippage.
        uint256 amountTokenMin = (bought * (BPS - slippageBps)) / BPS;
        uint256 amountBnbMin = (half * (BPS - slippageBps)) / BPS;
        (, uint256 usedBnb, uint256 liquidity) = IUniswapV2Router02(router)
            .addLiquidityETH{value: half}(
            address(twoToken), bought, amountTokenMin, amountBnbMin, address(this), block.timestamp + 300
        );
        lpBnbUsed += usedBnb;

        if (liquidity > 0) {
            IERC20(address(lpToken)).safeApprove(lpReward, 0);
            IERC20(address(lpToken)).safeApprove(lpReward, liquidity);
            ILpPrincipalSink(lpReward).creditLpPrincipal(liquidity);
            lpAmount = liquidity;
        }
    }

    /// Pair reserves in (02, WBNB) order regardless of how the pair was created.
    function _reserves() internal view returns (uint256 rTwo, uint256 rBnb) {
        address p = pair;
        if (p == address(0)) return (0, 0);
        (uint112 r0, uint112 r1, ) = IPancakePair(p).getReserves();
        if (IPancakePair(p).token0() == wbnb) {
            rBnb = uint256(r0);
            rTwo = uint256(r1);
        } else {
            rTwo = uint256(r0);
            rBnb = uint256(r1);
        }
    }

    /// 02 out for `bnbIn`, Pancake V2 constant product with the 0.25% fee. 0 when the pair is unavailable.
    function _quoteTwoOut(uint256 bnbIn) internal view returns (uint256) {
        (uint256 rTwo, uint256 rBnb) = _reserves();
        if (rTwo == 0 || rBnb == 0) return 0;
        uint256 inWithFee = bnbIn * 9_975;
        return (inWithFee * rTwo) / (rBnb * 10_000 + inWithFee);
    }

    function _spotTwoPerBnb() internal view returns (uint256) {
        (uint256 rTwo, uint256 rBnb) = _reserves();
        if (rTwo == 0 || rBnb == 0) return 0;
        return (rTwo * ONE) / rBnb;
    }

    /// USD per BNB (1e18-scaled) off the Pancake WBNB/USDT pair.
    function bnbUsdPrice() public view returns (uint256) {
        address p = IPancakeFactory(factory).getPair(wbnb, usdt);
        if (p == address(0)) return 0;
        (uint112 r0, uint112 r1, ) = IPancakePair(p).getReserves();
        if (r0 == 0 || r1 == 0) return 0;
        (uint256 rBnb, uint256 rUsd) = IPancakePair(p).token0() == wbnb
            ? (uint256(r0), uint256(r1))
            : (uint256(r1), uint256(r0));
        if (rBnb == 0) return 0;
        return (rUsd * ONE) / rBnb;
    }

    /// USD per 02 (1e18-scaled) = BNB/USD ÷ (02 per BNB). 0 when either pair is unavailable.
    function twoUsdPrice() public view returns (uint256) {
        uint256 twoPerBnb = _spotTwoPerBnb();
        uint256 bnbUsd = bnbUsdPrice();
        if (twoPerBnb == 0 || bnbUsd == 0) return 0;
        return (bnbUsd * ONE) / twoPerBnb;
    }

    /// 02 still owed to orders (lifetime promised minus lifetime paid). `unbackedTwo` is the part the
    /// current pool cannot cover; the deferred BNB is meant to buy it, and the foundation can top the
    /// pool up with `fundTwoPool`. Both are diagnostics for the keeper, not accounting state.
    function outstandingTwo() public view returns (uint256) {
        return scheduledTotal > twoPoolSpent ? scheduledTotal - twoPoolSpent : 0;
    }

    function unbackedTwo() public view returns (uint256) {
        uint256 owed = outstandingTwo();
        return owed > twoPoolBudget ? owed - twoPoolBudget : 0;
    }

    /// Diagnostics for the frontend: how many orders a user has and what each one owes.
    function orderInfo(address user, uint256 index)
        external
        view
        returns (uint256 bnbIn, uint256 releaseBnb, uint256 releaseTwo, uint256 claimedTwo,
                 uint256 claimableTwoOut, uint256 startTime)
    {
        if (index >= orderCount[user]) return (0, 0, 0, 0, 0, 0);
        Order storage o = orders[user][index];
        return (o.bnbIn, o.releaseBnb, o.releaseTwo, o.claimedTwo, claimableTwo(user, index), o.startTime);
    }

    receive() external payable {
        // Stray BNB (router refunds, direct transfers) is not owed to any order; the owner can sweep it.
        surplusBnb += msg.value;
    }
}
