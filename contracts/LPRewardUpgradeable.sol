// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title LPRewardUpgradeable
/// @notice UUPS-upgradeable variant of LPReward, deployed behind an ERC1967 proxy so the address
///         stays fixed while the implementation can be upgraded locally. Business logic is
///         identical to LPReward — only the skeleton changed (constructor -> initialize,
///         Ownable2Step/ReentrancyGuard -> their *Upgradeable twins, plus UUPSUpgradeable).
contract LPRewardUpgradeable is
    Initializable,
    Ownable2StepUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    /* ============ Constants ============ */
    uint256 public constant REWARD_INTERVAL  = 1 hours; // snapshot dividends every 1 hour
    uint256 public constant LOCK_30_DAYS     = 30 days;
    uint256 public constant LOCK_60_DAYS     = 60 days;
    uint256 public constant LOCK_90_DAYS     = 90 days;
    uint256 public constant MIN_LOCK_TIME    = 24 hours; // principal can be withdrawn early after 24h (no dividends)
    /// After the pool goes from "no stakers" to its first staker, distributions are held for this long
    /// so the market has a full day to join. Without it, the whole backlog that accrued while nobody
    /// was staked (the mint-phase 3%/7% pre-funding, plus any V2 tax that arrived in between) would be
    /// swept by whoever staked first — even with a minimal stake, because the dividend denominator is
    /// then just that one stake's weight. See _settleNow().
    uint256 public constant BOOTSTRAP_WINDOW = 24 hours;
    uint256 private constant ONE_ETHER       = 1e18;
    // Lock-duration weighting for dividend shares (applies to ALL phases):
    // staking LP for 90 days grants 3x the dividend share of a 30-day stake.
    uint256 private constant WEIGHT_30       = 1;
    uint256 private constant WEIGHT_60       = 2;
    uint256 private constant WEIGHT_90       = 3;

    /* ============ Data ============ */
    struct LPStakeInfo {
        uint256 amount;
        uint256 weight;      // dividend weight 1/2/3 by lock duration
        uint256 startTime;
        uint256 endTime;
        uint256 rewardDebt;
        bool    isActive;
        bool    isWithdrawn;
        bool    isExpiredDeducted;   // plan d: share already deducted from totalStaked after maturity
    }

    IERC20  public lpToken;
    address public twoProtocolAddress;
    address public liquidityManager;        // LiquidityManager can stake LP on behalf of users
    bool    public lpStakingEnabled;       // closed during mint; opened manually by owner after V2

    mapping(address => LPStakeInfo[]) public userLpStakes;
    mapping(address => uint256)        public userLpStakeCount;

    uint256 public lpRewardPool;            // pending distribution (not yet snapshotted)
    uint256 public lpClaimableReserve;      // distributed but unclaimed
    uint256 public totalLpRewardPaid;       // cumulative BNB dividends actually paid to LP stakers (frontend display)
    uint256 public totalLpStaked;           // total staked LP shares (not expired & not yet deducted)
    uint256 public totalWeightedLpStaked;   // weighted dividend shares (amount * weight), the dividend denominator
    uint256 public lpAccumulatedRewardPerShare; // cumulative reward per weighted share * 1e18
    uint256 public lastLpRewardTime;

    // DAO governance (appended — storage MUST stay append-only across upgrades):
    // TwoFoundation association (notifies referral incentives when LP is staked)
    address public foundation;

    // Dividends that could not be pushed to the recipient (a contract wallet that rejects BNB) are
    // parked here instead of reverting the unstake, and pulled with claimReward(). Appended.
    mapping(address => uint256) public unclaimedReward;

    // Deadline of the bootstrap window opened by the first LP stake after a stretch with no stakers
    // (0 = no window running). Appended last: proxy storage stays append-only.
    uint256 public bootstrapUntil;

    // Referral claim gate (the Foundation reads these). The cumulative lock-time clock accumulates across
    // stakes and is wiped when everything is withdrawn. Amounts are NOT mirrored: they are recomputed
    // from userLpStakes on demand, so users who were already staked when this implementation went live
    // are gated correctly without any migration call. Appended last for the usual storage reason.
    mapping(address => uint256) public lpStakeTimeAccrued;
    mapping(address => uint256) public lpStakeTimeCheckpoint;

    // LP principal built by the burn mine (17.5% of every deposit). Booked per weighted share and
    // released per stake once that stake matures — see creditLpPrincipal / claimLpPrincipal.
    address public principalSource;
    uint256 public lpPrincipalPerShare;                    // 1e18-scaled LP per weighted unit
    uint256 public lpPrincipalCredited;                    // cumulative LP booked (diagnostics)
    uint256 public lpPrincipalPending;                     // credited while nobody was staked
    mapping(address => mapping(uint256 => uint256)) public lpPrincipalDebt; // user → stake index → debt
    // Accumulator snapshot taken when a stake is withdrawn. It keeps the principal earned up to that
    // point claimable, but stops the stake from earning principal credited after it left the pool.
    // 0 = still active; a 1 sentinel means "settled while the accumulator was still 0".
    mapping(address => mapping(uint256 => uint256)) public lpPrincipalSettledAt;

    // V13 freeze (appended last — proxy storage stays append-only):
    // Only addresses on the early-user list (`freezeEligible`) may be frozen. The operator fills that
    // list; the owner seals it at launch, after which nobody can be added — so users who join later
    // can never be frozen. A frozen address cannot unstake LP, claim dividends or claim LP principal.
    address public lpOperator;
    bool public freezeListSealed;
    mapping(address => bool) public freezeEligible;
    mapping(address => bool) public lpFrozen;

    event LpOperatorSet(address indexed operator);
    event FreezeEligibleSet(address indexed account, bool flag);
    event FreezeListSealed();
    event LpFrozenSet(address indexed account, bool flag);

    event LPStaked(address indexed user, uint256 index, uint256 amount, uint256 lockDays);
    event LPUnstaked(address indexed user, uint256 index, uint256 amount, uint256 reward);
    event LPEarlyUnstaked(address indexed user, uint256 index, uint256 amount);
    event LPRewardDistributed(uint256 amount);
    event LPExpiredSwept(address indexed user, uint256 totalDeducted);
    event RewardParked(address indexed user, uint256 amount);
    event BootstrapWindowStarted(uint256 until);
    event LpPrincipalCredited(uint256 amount, uint256 weightedDenom);
    event LpPrincipalParked(uint256 pending);
    event LpPrincipalClaimed(address indexed user, uint256 index, uint256 amount);
    event PrincipalSourceSet(address indexed source);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// One-time initialization, called by the proxy right after deployment (delegatecall).
    function initialize(address _lpToken, address _twoProtocol) external initializer {
        __Ownable2Step_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        lpToken = IERC20(_lpToken);
        twoProtocolAddress = _twoProtocol;
        lastLpRewardTime = block.timestamp;
    }

    /// Only the owner may upgrade the implementation (UUPS).
    function _authorizeUpgrade(address /*newImplementation*/) internal override onlyOwner {}

    /* ============ Owner setters ============ */
    function setLpToken(address _lpToken)         external onlyOwner { lpToken = IERC20(_lpToken); }
    function setTwoProtocol(address _twoProtocol) external onlyOwner { twoProtocolAddress = _twoProtocol; }
    function setLpStakingEnabled(bool _flag)      external onlyOwner { lpStakingEnabled = _flag; }
    function setLiquidityManager(address _m)      external onlyOwner { liquidityManager = _m; }
    function setFoundation(address _f)            external onlyOwner { foundation = _f; }

    /* ============ Freeze (early-user list only) ============ */
    /// Frozen accounts cannot unstake LP, claim dividends, pull parked rewards or claim LP principal.
    /// Freezing is deliberately restricted to the early-user list so members who join after launch
    /// can never be frozen, whatever happens later.
    modifier notFrozen() {
        require(!lpFrozen[msg.sender], "LP frozen");
        _;
    }

    /// Backend operator that curates the early-user list and toggles freeze flags.
    function setLpOperator(address _op) external onlyOwner {
        lpOperator = _op;
        emit LpOperatorSet(_op);
    }

    /// Add / remove an address from the early-user list. Only the operator, and only before the list
    /// is sealed at launch — afterwards this reverts for everyone.
    function setFreezeEligible(address account, bool flag) external {
        require(msg.sender == lpOperator || msg.sender == owner(), "Only operator");
        require(!freezeListSealed, "List sealed");
        require(account != address(0), "Zero address");
        freezeEligible[account] = flag;
        emit FreezeEligibleSet(account, flag);
    }

    /// Locks the early-user list forever. Called once at launch; after that no address can be added,
    /// so users who join later are structurally unfreezable.
    function sealFreezeList() external onlyOwner {
        freezeListSealed = true;
        emit FreezeListSealed();
    }

    /// Freeze / unfreeze an account. Freezing requires the account to be on the sealed early list;
    /// unfreezing is always allowed so a user can be released after review.
    function setLpFrozen(address account, bool flag) external {
        require(msg.sender == lpOperator || msg.sender == owner(), "Only operator");
        if (flag) require(freezeEligible[account], "Not in early list");
        lpFrozen[account] = flag;
        emit LpFrozenSet(account, flag);
    }

    /* ============ Read-only ============ */
    /// True while the bootstrap window is holding distributions (see _settleNow). Callers that
    /// simulate a snapshot must check this, or they would show a dividend that is not payable yet.
    function bootstrapHolding() public view returns (bool) {
        return bootstrapUntil != 0 && block.timestamp < bootstrapUntil;
    }

    function getUserPendingLpReward(address user, uint256 index) external view returns (uint256) {
        if (index >= userLpStakes[user].length) return 0;
        LPStakeInfo memory info = userLpStakes[user][index];
        if (!info.isActive) return 0;
        uint256 _acc = lpAccumulatedRewardPerShare;
        // Skipped while the bootstrap window is holding, because no settlement would actually happen then.
        if (block.timestamp >= lastLpRewardTime + REWARD_INTERVAL && totalWeightedLpStaked > 0 && lpRewardPool > 0
            && !bootstrapHolding()) {
            _acc += (lpRewardPool * ONE_ETHER) / totalWeightedLpStaked;
        }
        uint256 gross = (info.amount * info.weight * _acc) / ONE_ETHER;
        return gross > info.rewardDebt ? gross - info.rewardDebt : 0;
    }

    /* ============ Dividend snapshot ============ */
    /// Moves the pending pool into the claimable reserve and raises accPerShare against the CURRENT
    /// weights. Split out of updateReward() so the stake / unstake paths can settle BEFORE the weight
    /// set changes — otherwise whoever joins just before an hourly snapshot is paid for time they
    /// were not staked, and whoever leaves just before it forfeits a share they had already earned.
    function _settleNow() internal {
        // Bootstrap window: hold every distribution until it expires, so the market has a full day to
        // join before the first settlement. Without it the backlog that accrued while nobody was staked
        // is divided by the first staker's own weight alone and lands on them entirely. Every settling
        // path goes through here (updateReward, stakeLp, stakeLpFor, unstakeLp, earlyUnstakeLp,
        // unstakeAllLp, sweep), so gating it here is enough — a second staker joining mid-window must
        // not settle either.
        if (bootstrapUntil != 0) {
            if (block.timestamp < bootstrapUntil) return; // still holding
            bootstrapUntil = 0;                            // expired — clear it and settle below
        }
        if (totalWeightedLpStaked == 0 || lpRewardPool == 0) return;
        uint256 rewardAmount = lpRewardPool;
        lpRewardPool = 0;
        lpClaimableReserve += rewardAmount;
        lpAccumulatedRewardPerShare += (rewardAmount * ONE_ETHER) / totalWeightedLpStaked;
        emit LPRewardDistributed(rewardAmount);
    }

    function updateReward() public {
        if (block.timestamp < lastLpRewardTime + REWARD_INTERVAL) return;
        if (totalWeightedLpStaked == 0) { lastLpRewardTime = block.timestamp; return; }
        _settleNow();
        lastLpRewardTime = block.timestamp;
    }

    /// Hands `payout` to `user`. A recipient that cannot receive BNB (a contract wallet without
    /// receive(), or one that reverts) must never block the stake from being returned, so on failure
    /// the amount stays inside lpClaimableReserve and is parked under the user's name instead.
    function _payOrPark(address user, uint256 payout) internal {
        if (payout == 0) return;
        (bool ok, ) = payable(user).call{value: payout}("");
        if (ok) {
            lpClaimableReserve -= payout;
            totalLpRewardPaid += payout;
            _accrueReferral(user, payout);
        } else {
            unclaimedReward[user] += payout;
            emit RewardParked(user, payout);
        }
    }

    /// Referral matching: tell the Foundation how much BNB dividend this user just received so it can
    /// credit the referrer an equivalent amount in 02. Best-effort — a failing Foundation must never
    /// block the staker's payout.
    function _accrueReferral(address user, uint256 bnbAmount) internal {
        if (foundation == address(0) || bnbAmount == 0) return;
        (bool s, ) = foundation.call(abi.encodeWithSignature("onLpDividend(address,uint256)", user, bnbAmount));
        s;
    }

    /// Pull a parked dividend (see _payOrPark). The amount is still inside lpClaimableReserve, so
    /// ownerRescueBNB keeps treating it as owed to LP stakers.
    function claimReward() external nonReentrant notFrozen {
        uint256 amount = unclaimedReward[msg.sender];
        require(amount > 0, "Nothing to claim");
        unclaimedReward[msg.sender] = 0;
        lpClaimableReserve -= amount;
        totalLpRewardPaid += amount;
        (bool ok, ) = payable(msg.sender).call{value: amount}("");
        require(ok, "Reward transfer failed");
        _accrueReferral(msg.sender, amount);
    }

    /* ============ Plan d: deduct matured shares (gas spread across operations) ============ */
    /// Mirrors RewardDistributor._sweepExpiredForUser: touches ONLY totalLpStaked (the LP stake-cap
    /// counter), never totalWeightedLpStaked (the dividend denominator). A stake's claim is
    /// `amount*weight*acc - rewardDebt`, so the numerator keeps the stake's weight for as long as the
    /// stake exists; dropping it from the denominator while the numerator kept growing would make the
    /// claims sum to more than the BNB injected and shorten whichever staker claimed last — and
    /// sweepLpExpired() is permissionless, so anyone could trigger it for any matured stake.
    function _sweepLpExpiredForUser(address user) internal returns (uint256 deducted) {
        uint256 len = userLpStakes[user].length;
        for (uint256 i = 0; i < len; i++) {
            LPStakeInfo storage info = userLpStakes[user][i];
            if (info.isActive && !info.isExpiredDeducted && block.timestamp >= info.endTime) {
                totalLpStaked -= info.amount;
                info.isExpiredDeducted = true;
                deducted += info.amount;
            }
        }
        if (deducted > 0) emit LPExpiredSwept(user, deducted);
    }
    function sweepLpExpired(address user) external {
        // Anyone can sweep (e.g. a keeper). Settle first, for the same reason as every other
        // weight-changing path: the pool sitting in lpRewardPool has not been snapshotted yet, and it must
        // be settled against the weights that were live while it accrued.
        _settleNow();
        _sweepLpExpiredForUser(user);
    }

    /// Latest endTime among the user's LP stakes that have not been withdrawn (0 if none): the point up
    /// to which the user is guaranteed to have LP locked, so the cumulative clock never runs past it.
    function _openLpStakeHorizon(address user) internal view returns (uint256 h) {
        uint256 len = userLpStakes[user].length;
        for (uint256 i = 0; i < len; i++) {
            LPStakeInfo storage info = userLpStakes[user][i];
            if (info.isActive && !info.isWithdrawn && info.endTime > h) h = info.endTime;
        }
    }

    function _hasOpenLpStake(address user) internal view returns (bool) {
        uint256 len = userLpStakes[user].length;
        for (uint256 i = 0; i < len; i++) {
            LPStakeInfo storage info = userLpStakes[user][i];
            if (info.isActive && !info.isWithdrawn) return true;
        }
        return false;
    }

    /// Roll the cumulative LP staking clock up to now, capped at the locked horizon. Call BEFORE mutating
    /// the stakes: overlapping stakes are counted once and a gap with nothing locked is not credited.
    function _accrueLpStakeTime(address user) internal {
        uint256 ckpt = lpStakeTimeCheckpoint[user];
        if (ckpt == 0) {
            lpStakeTimeCheckpoint[user] = block.timestamp; // clock starts now
            return;
        }
        uint256 h = _openLpStakeHorizon(user);
        uint256 t = h < block.timestamp ? h : block.timestamp;
        if (t > ckpt) lpStakeTimeAccrued[user] += t - ckpt;
        lpStakeTimeCheckpoint[user] = block.timestamp;
    }

    /// Called after a withdrawal: one open stake keeps the clock running, taking EVERYTHING out wipes it.
    function _closeLpStakeClock(address user) internal {
        if (_hasOpenLpStake(user)) return;
        lpStakeTimeAccrued[user] = 0;
        lpStakeTimeCheckpoint[user] = 0;
    }

    /// Earliest startTime among the user's still-open LP stakes (0 if none). Used as the clock's origin for
    /// positions that predate this implementation (their checkpoint is still 0), so existing stakers are
    /// credited for the time they genuinely spent locked instead of being locked out until they touch it.
    function _firstOpenLpStakeStart(address user) internal view returns (uint256 s) {
        uint256 len = userLpStakes[user].length;
        for (uint256 i = 0; i < len; i++) {
            LPStakeInfo storage info = userLpStakes[user][i];
            if (info.isActive && !info.isWithdrawn && (s == 0 || info.startTime < s)) s = info.startTime;
        }
    }

    /// Cumulative seconds the user has kept LP locked — the union of every lock's elapsed time. The
    /// Foundation reads this to decide whether a referrer may claim. Withdrawing everything zeroes it.
    function activeLpStakeAge(address user) external view returns (uint256) {
        uint256 total = lpStakeTimeAccrued[user];
        uint256 ckpt = lpStakeTimeCheckpoint[user];
        if (ckpt == 0) {
            // Never touched since this implementation went live: start from the earliest open lock.
            ckpt = _firstOpenLpStakeStart(user);
            if (ckpt == 0) return 0;
        }
        uint256 h = _openLpStakeHorizon(user);
        uint256 t = h < block.timestamp ? h : block.timestamp;
        if (t > ckpt) total += t - ckpt;
        return total;
    }

    /// Live LP stake of the user, recomputed from userLpStakes (no mirror to migrate). Counts a position
    /// that has matured but has not been withdrawn: the LP is still sitting in this contract.
    function activeLpAmount(address user) external view returns (uint256 sum) {
        uint256 len = userLpStakes[user].length;
        for (uint256 i = 0; i < len; i++) {
            LPStakeInfo storage info = userLpStakes[user][i];
            if (info.isActive && !info.isWithdrawn) sum += info.amount;
        }
    }

    /* ============ Stake LP (30/60/90 days) ============ */
    function stakeLp(uint256 amount, uint256 lockDays) external nonReentrant {
        require(lpStakingEnabled, "LP staking closed");
        require(amount > 0, "Zero amount");
        require(lockDays == LOCK_30_DAYS || lockDays == LOCK_60_DAYS || lockDays == LOCK_90_DAYS, "Invalid lock");

        _settleNow();
        _sweepLpExpiredForUser(msg.sender);

        lpToken.safeTransferFrom(msg.sender, address(this), amount);

        // First LP stake after a stretch with no stakers: open the bootstrap window so the backlog is
        // shared by everyone who joins within it instead of being captured by this single stake. The
        // check runs before the new weight is added, so it fires on the 0 -> 1 transition (and again if
        // the pool ever empties out completely).
        if (totalWeightedLpStaked == 0) {
            bootstrapUntil = block.timestamp + BOOTSTRAP_WINDOW;
            emit BootstrapWindowStarted(bootstrapUntil);
        }

        // Roll the cumulative clock before the new lock exists, so a gap with nothing locked is not credited.
        _accrueLpStakeTime(msg.sender);

        uint256 index = userLpStakes[msg.sender].length;
        userLpStakes[msg.sender].push();
        LPStakeInfo storage info = userLpStakes[msg.sender][index];
        info.amount    = amount;
        info.weight    = lockDays == LOCK_60_DAYS ? WEIGHT_60 : (lockDays == LOCK_90_DAYS ? WEIGHT_90 : WEIGHT_30);
        info.startTime = block.timestamp;
        info.endTime   = block.timestamp + lockDays;
        info.rewardDebt = (amount * info.weight * lpAccumulatedRewardPerShare) / ONE_ETHER;
        info.isActive  = true;
        // Snapshot the LP-principal accumulator so this stake only earns the LP the burn module
        // distributes from now on, never anything credited before it existed.
        lpPrincipalDebt[msg.sender][index] = (amount * info.weight * lpPrincipalPerShare) / ONE_ETHER;

        totalLpStaked += amount;
        totalWeightedLpStaked += amount * info.weight;
        userLpStakeCount[msg.sender] += 1;

        emit LPStaked(msg.sender, index, amount, lockDays);
    }

    /* ============ Stake LP on behalf of a user (LiquidityManager only; LP pulled from msg.sender) ============ */
    function stakeLpFor(address user, uint256 amount, uint256 lockDays) external nonReentrant {
        require(msg.sender == liquidityManager, "Only manager");
        require(user != address(0), "Zero address");
        require(lpStakingEnabled, "LP staking closed");
        require(amount > 0, "Zero amount");
        require(lockDays == LOCK_30_DAYS || lockDays == LOCK_60_DAYS || lockDays == LOCK_90_DAYS, "Invalid lock");

        _settleNow();
        _sweepLpExpiredForUser(user);

        lpToken.safeTransferFrom(msg.sender, address(this), amount);

        // First LP stake after a stretch with no stakers: open the bootstrap window (same rule as
        // stakeLp). On-behalf staking from the LiquidityManager must arm it too, or the very first
        // stake through that path would reopen the hole.
        if (totalWeightedLpStaked == 0) {
            bootstrapUntil = block.timestamp + BOOTSTRAP_WINDOW;
            emit BootstrapWindowStarted(bootstrapUntil);
        }

        // Same clock rule as stakeLp, applied to the beneficiary (the LP comes from the manager).
        _accrueLpStakeTime(user);

        uint256 index = userLpStakes[user].length;
        userLpStakes[user].push();
        LPStakeInfo storage info = userLpStakes[user][index];
        info.amount     = amount;
        info.weight     = lockDays == LOCK_60_DAYS ? WEIGHT_60 : (lockDays == LOCK_90_DAYS ? WEIGHT_90 : WEIGHT_30);
        info.startTime  = block.timestamp;
        info.endTime    = block.timestamp + lockDays;
        info.rewardDebt = (amount * info.weight * lpAccumulatedRewardPerShare) / ONE_ETHER;
        info.isActive   = true;
        lpPrincipalDebt[user][index] = (amount * info.weight * lpPrincipalPerShare) / ONE_ETHER;

        totalLpStaked += amount;
        totalWeightedLpStaked += amount * info.weight;
        userLpStakeCount[user] += 1;

        emit LPStaked(user, index, amount, lockDays);
    }

    /* ============ Unstake at maturity (principal + dividends) ============ */
    function unstakeLp(uint256 index) external nonReentrant notFrozen {
        require(index < userLpStakes[msg.sender].length, "Out of range");
        LPStakeInfo storage info = userLpStakes[msg.sender][index];
        require(info.isActive, "Not active");
        require(block.timestamp >= info.endTime, "Not mature");
        require(block.timestamp >= info.startTime + MIN_LOCK_TIME, "Locked 24h");

        _settleNow();
        _sweepLpExpiredForUser(msg.sender);

        uint256 amount = info.amount;
        uint256 pendingReward = (amount * info.weight * lpAccumulatedRewardPerShare) / ONE_ETHER - info.rewardDebt;

        _accrueLpStakeTime(msg.sender); // before the stake leaves the horizon
        _settlePrincipalAcc(msg.sender, index); // stop earning principal credited after this point
        info.isActive = false;
        info.isWithdrawn = true;
        _closeLpStakeClock(msg.sender);
        // Guarded: the sweep above may already have deducted this stake from totalLpStaked.
        if (!info.isExpiredDeducted) {
            totalLpStaked -= amount;
            info.isExpiredDeducted = true;
        }
        // Unguarded, and exactly once: the sweep no longer removes the weight from the dividend
        // denominator, so the denominator only drops here, where the stake actually leaves.
        totalWeightedLpStaked -= amount * info.weight;

        uint256 payout;
        if (pendingReward > 0) {
            payout = pendingReward > lpClaimableReserve ? lpClaimableReserve : pendingReward;
        }
        // Principal first: a failing dividend transfer must never block the return of the stake.
        lpToken.safeTransfer(msg.sender, amount);
        _payOrPark(msg.sender, payout);
        emit LPUnstaked(msg.sender, index, amount, payout);
    }

    /* ============ Early unstake (principal only, no dividends; pending redistributed to the rest) ============ */
    function earlyUnstakeLp(uint256 index) external nonReentrant notFrozen {
        require(index < userLpStakes[msg.sender].length, "Out of range");
        LPStakeInfo storage info = userLpStakes[msg.sender][index];
        require(info.isActive, "Not active");
        require(block.timestamp >= info.startTime + MIN_LOCK_TIME, "Locked 24h");
        require(block.timestamp <  info.endTime, "Matured; use unstakeLp");

        _settleNow();
        _sweepLpExpiredForUser(msg.sender);

        uint256 amount = info.amount;
        uint256 pendingReward = (amount * info.weight * lpAccumulatedRewardPerShare) / ONE_ETHER - info.rewardDebt;

        // The forfeited pending goes to the remaining LP stakers. The BNB already sits in
        // lpClaimableReserve and STAYS there — only the entitlement moves (accPerShare). Reducing the
        // reserve as well would leave the remaining stakers' claim under-backed and turn the
        // difference into sweepable "surplus" for ownerRescueBNB.
        // Skipped entirely when the reserve is short — never lets a stale accounting block the principal return.
        if (pendingReward > 0 && lpClaimableReserve >= pendingReward) {
            uint256 remaining = totalWeightedLpStaked - (info.isExpiredDeducted ? 0 : amount * info.weight);
            if (remaining > 0) {
                lpAccumulatedRewardPerShare += (pendingReward * ONE_ETHER) / remaining;
            } else {
                // Nobody left to absorb it: release it back to the pending pool, distributed by
                // updateReward once new stakers enter (this branch MUST reduce the reserve, or the
                // amount would be counted twice once lpRewardPool is moved back in)
                lpClaimableReserve -= pendingReward;
                lpRewardPool += pendingReward;
            }
        }

        _accrueLpStakeTime(msg.sender); // before the stake leaves the horizon
        _settlePrincipalAcc(msg.sender, index); // stop earning principal credited after this point
        info.isActive = false;
        info.isWithdrawn = true;
        _closeLpStakeClock(msg.sender);
        // This stake is by definition not matured (require above), so it cannot have been swept:
        // the guard is kept for the normal reason (never deduct totalLpStaked twice).
        if (!info.isExpiredDeducted) {
            totalLpStaked -= amount;
            info.isExpiredDeducted = true;
        }
        // Unguarded, and exactly once: the denominator only drops where the stake actually leaves.
        totalWeightedLpStaked -= amount * info.weight;

        lpToken.safeTransfer(msg.sender, amount);
        emit LPEarlyUnstaked(msg.sender, index, amount);
    }

    /* ============ Batch unstake at maturity ============ */
    function unstakeAllLp(uint256 count) external nonReentrant notFrozen {
        require(count > 0, "Zero count");
        uint256 len = userLpStakes[msg.sender].length;
        if (count > len) count = len;

        _settleNow();
        _sweepLpExpiredForUser(msg.sender);

        uint256 totalAmount;
        uint256 totalReward;
        uint256 processed;
        _accrueLpStakeTime(msg.sender); // once, before any stake leaves the horizon
        // Skip cancelled/placeholder entries; iterate until count valid stakes have been processed (avoids under-refunding when there are gaps in between)
        for (uint256 i = 0; i < len && processed < count; i++) {
            LPStakeInfo storage info = userLpStakes[msg.sender][i];
            if (!info.isActive || info.isWithdrawn) continue;
            if (block.timestamp < info.endTime) continue;
            if (block.timestamp < info.startTime + MIN_LOCK_TIME) continue;

            uint256 amount = info.amount;
            uint256 pendingReward = (amount * info.weight * lpAccumulatedRewardPerShare) / ONE_ETHER - info.rewardDebt;

            _settlePrincipalAcc(msg.sender, i); // stop earning principal credited after this point
            info.isActive = false;
            info.isWithdrawn = true;
            // Guarded: the sweep above already deducted the matured stakes from totalLpStaked.
            if (!info.isExpiredDeducted) {
                totalLpStaked -= amount;
                info.isExpiredDeducted = true;
            }
            // Unguarded, and exactly once per stake: the denominator drops here.
            totalWeightedLpStaked -= amount * info.weight;
            totalAmount += amount;
            totalReward += pendingReward;

            emit LPUnstaked(msg.sender, i, amount, pendingReward);
            processed++;
        }

        require(totalAmount > 0 || totalReward > 0, "No matured stakes");
        _closeLpStakeClock(msg.sender); // only wipes the clock if nothing is left open

        uint256 payout;
        if (totalReward > 0) {
            payout = totalReward > lpClaimableReserve ? lpClaimableReserve : totalReward;
        }
        // Principal first: a failing dividend transfer must never block the return of the stakes.
        if (totalAmount > 0) lpToken.safeTransfer(msg.sender, totalAmount);
        _payOrPark(msg.sender, payout);
    }

    /* ============ Receiving reward BNB (from the V2 tax fee 1% LP share) ============ */
    receive() external payable { lpRewardPool += msg.value; }
    function addLpReward() external payable { lpRewardPool += msg.value; }

    /* ============ LP principal from the burn module (booked, unlocked at maturity) ============ */
    /// Credit the LP the burn module built with its 17.5% slice. The tokens are pulled in and split by
    /// dividend weight, but nothing is paid out here: each stake keeps earning from the moment it was
    /// created and can only withdraw its share once its own lock has ended. In other words: book it
    /// now, claim it at maturity — existing stakes are untouched because their debt is snapshotted on
    /// creation, and a matured stake is still the only thing that can release anything.
    function creditLpPrincipal(uint256 amount) external nonReentrant {
        require(msg.sender == principalSource && principalSource != address(0), "Only principal source");
        require(amount > 0, "Zero amount");
        lpToken.safeTransferFrom(msg.sender, address(this), amount);

        uint256 total = amount + lpPrincipalPending;
        uint256 denom = totalWeightedLpStaked;
        if (denom == 0) {
            // Nobody staked: hold it. It is folded into the next credit, so it can never be captured
            // by the first staker who shows up afterwards.
            lpPrincipalPending = total;
            emit LpPrincipalParked(total);
            return;
        }
        lpPrincipalPending = 0;
        lpPrincipalPerShare += (total * ONE_ETHER) / denom;
        lpPrincipalCredited += total;
        emit LpPrincipalCredited(amount, denom);
    }

    /// LP principal `user` has earned on stake `index` but not yet taken.
    function pendingLpPrincipal(address user, uint256 index) public view returns (uint256) {
        if (index >= userLpStakes[user].length) return 0;
        LPStakeInfo storage info = userLpStakes[user][index];
        if (info.amount == 0) return 0;
        // A withdrawn stake uses the accumulator snapshot from the moment it left; an active stake uses
        // the live one. A stake that was ALREADY withdrawn before the burn-principal feature existed
        // (snapshot 0 + isWithdrawn) never shared in it, so it must not start earning now.
        uint256 acc = lpPrincipalSettledAt[user][index];
        if (acc == 0) {
            if (info.isWithdrawn) return 0;
            acc = lpPrincipalPerShare;
        }
        uint256 accrued = (info.amount * info.weight * acc) / ONE_ETHER;
        uint256 debt = lpPrincipalDebt[user][index];
        return accrued > debt ? accrued - debt : 0;
    }

    /// Freeze this stake's principal accumulator when its LP leaves. Anything earned up to here stays
    /// claimable through claimLpPrincipal(); principal credited afterwards no longer accrues to it.
    function _settlePrincipalAcc(address user, uint256 index) internal {
        if (lpPrincipalSettledAt[user][index] == 0) {
            lpPrincipalSettledAt[user][index] = lpPrincipalPerShare == 0 ? 1 : lpPrincipalPerShare;
        }
    }

    /// Withdraw the booked LP principal of ONE matured stake. Requires the stake's own lock to be over,
    /// even if it has already been unstaked (index stays valid and claimable after maturity).
    function claimLpPrincipal(uint256 index) external nonReentrant notFrozen {
        require(index < userLpStakes[msg.sender].length, "Out of range");
        LPStakeInfo storage info = userLpStakes[msg.sender][index];
        require(info.amount > 0, "No stake");
        require(block.timestamp >= info.endTime, "Not mature");
        uint256 amount = pendingLpPrincipal(msg.sender, index);
        require(amount > 0, "Nothing to claim");
        lpPrincipalDebt[msg.sender][index] += amount;
        lpToken.safeTransfer(msg.sender, amount);
        emit LpPrincipalClaimed(msg.sender, index, amount);
    }

    /// Source allowed to credit LP principal (the burn-mine module).
    function setPrincipalSource(address _source) external onlyOwner {
        principalSource = _source;
        emit PrincipalSourceSet(_source);
    }

    /* ============ Owner emergency: can only withdraw the pending pool (lpClaimableReserve always belongs to LP stakers) ============ */
    function emergencyWithdraw(uint256 amount) external onlyOwner {
        require(amount <= lpRewardPool, "Insufficient undistributed pool");
        lpRewardPool -= amount;
        (bool success, ) = payable(msg.sender).call{value: amount}("");
        require(success, "Transfer failed");
    }

    /// Owner rescue of STRAY BNB only: whatever the contract holds above the pools it owes.
    /// `lpClaimableReserve` belongs to LP stakers who have already earned it, and `lpRewardPool` is
    /// earmarked for the next distribution — neither may be swept. The earlier version of this
    /// function zeroed both and paid itself, contradicting the rule emergencyWithdraw() follows.
    function ownerRescueBNB() external onlyOwner {
        uint256 owed = lpRewardPool + lpClaimableReserve;
        uint256 bal = address(this).balance;
        if (bal <= owed) return;
        uint256 amount = bal - owed;
        (bool success, ) = payable(msg.sender).call{value: amount}("");
        require(success, "Transfer failed");
    }

    /// Owner rescue of tokens accidentally sent to the contract. The staked LP token itself is
    /// excluded: the contract's LP balance backs user stakes, so the owner must never move it.
    function ownerRescueToken(address token, uint256 amount) external onlyOwner {
        require(token != address(0), "Zero address");
        require(token != address(lpToken), "Staked token");
        require(IERC20(token).balanceOf(address(this)) >= amount, "Insufficient balance");
        IERC20(token).safeTransfer(msg.sender, amount);
    }
}
