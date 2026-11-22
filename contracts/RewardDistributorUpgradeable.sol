// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title RewardDistributorUpgradeable
/// @notice UUPS-upgradeable variant of RewardDistributor, deployed behind an ERC1967 proxy so the
///         address stays fixed while the implementation can be upgraded locally. Business logic is
///         identical to RewardDistributor — only the skeleton changed (constructor -> initialize,
///         Ownable2Step/ReentrancyGuard -> their *Upgradeable twins, plus UUPSUpgradeable).
contract RewardDistributorUpgradeable is
    Initializable,
    Ownable2StepUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    /* ============ Constants ============ */
    /// Seed for the governable cap below. 10000 = 100% of the circulating supply, which is also the
    /// mathematical maximum: every staked 02 is held by this contract, so totalStaked can never
    /// exceed circulatingSupply. In other words the default is already "no practical limit".
    uint256 public constant DEFAULT_MAX_STAKE_RATIO = 10_000;
    /// Hard bound for `maxStakeRatioBps`. Not a policy choice — above 100% the number stops meaning
    /// anything at all, so this just keeps it honest.
    uint256 public constant MAX_STAKE_RATIO_CEILING = 10_000;
    uint256 public constant REWARD_INTERVAL  = 1 hours; // snapshot dividends every 1 hour
    uint256 public constant LOCK_30_DAYS     = 30 days;
    uint256 public constant LOCK_60_DAYS     = 60 days;
    uint256 public constant LOCK_90_DAYS     = 90 days;
    uint256 public constant MIN_LOCK_TIME    = 24 hours; // principal can be withdrawn early after 24h (no dividends)
    /// After the pool goes from "no stakers" to its first staker, distributions are held for this long
    /// so the market has a full day to join. Without it, the whole backlog that accrued while nobody
    /// was staked (the mint-phase 3%/7% pre-funding, plus any V2 tax / interest that arrived in
    /// between) would be swept by whoever staked first — even with a minimal stake, because the
    /// dividend denominator is then just that one stake's weight. See _settleNow().
    uint256 public constant BOOTSTRAP_WINDOW = 24 hours;
    uint256 private constant ONE_ETHER       = 1e18;
    // Lock-duration weighting for dividend shares (applies to ALL phases):
    // staking 02 for 90 days grants 3x the dividend share of a 30-day stake.
    uint256 private constant WEIGHT_30       = 1;
    uint256 private constant WEIGHT_60       = 2;
    uint256 private constant WEIGHT_90       = 3;

    /* ============ Data ============ */
    struct StakeInfo {
        uint256 amount;
        uint256 weight;      // dividend weight 1/2/3 by lock duration
        uint256 startTime;
        uint256 endTime;
        uint256 rewardDebt;
        bool    isActive;
        bool    isWithdrawn;
        bool    isExpiredDeducted;   // share already deducted from totalStaked after maturity (plan d)
    }

    IERC20  public twoToken;
    address public twoProtocolAddress;
    address public twoLendAddress;
    bool    public stakingEnabled;          // closed during mint; opened manually by owner after V2

    mapping(address => StakeInfo[]) public userStakes;
    mapping(address => uint256)      public userStakeCount;

    uint256 public rewardPool;            // pending distribution (not yet in the accumulated share)
    uint256 public claimableReserve;      // distributed but unclaimed (user-claimable pool)
    uint256 public totalRewardPaid;       // cumulative BNB dividends actually paid to stakers (frontend display)
    uint256 public totalStaked;           // currently effective staking (not expired & not deducted; deducted by sweep after maturity)
    uint256 public totalWeightedStaked;   // weighted dividend shares (amount * weight), the dividend denominator
    uint256 public accumulatedRewardPerShare; // cumulative reward per weighted share * 1e18
    uint256 public lastRewardTime;

    // Dividends that could not be pushed to the recipient (a contract wallet that rejects BNB) are
    // parked here instead of reverting the unstake, and pulled with claimReward(). Appended.
    mapping(address => uint256) public unclaimedReward;

    // The live staking cap, in bps of the circulating supply — the governable replacement for what
    // used to be the compile-time constant MAX_STAKE_RATIO (=3000). Declared LAST on purpose: proxy
    // storage is append-only, so a slot declared before the two mappings above would shift them.
    // Seeded by initialize() on a fresh deploy and by initStakeV2() on the existing proxy; a proxy
    // that has not run that hook reads 0 here, which fails CLOSED (nothing new can be staked) until
    // the hook runs — never open by accident.
    uint256 public maxStakeRatioBps;

    // Deadline of the bootstrap window opened by the first stake after a stretch with no stakers
    // (0 = no window running). Appended after maxStakeRatioBps: proxy storage stays append-only.
    uint256 public bootstrapUntil;

    // Per-user mirror of totalStaked: live, unexpired single-token stake only. The Foundation's referral
    // gate reads this to decide whether a referrer stakes enough to earn. Appended last for the usual
    // reason (proxy storage is append-only). Subtractions SATURATE — a proxy upgraded while people are
    // already staked starts this mapping at 0, and a plain `-=` on the first sweep of such a stake would
    // underflow and brick unstake/sweep for that user. Anyone can repair a user with syncActiveStaked().
    mapping(address => uint256) public activeStaked;

    // Deprecated slots, kept only to preserve the storage layout. The referral time gate was moved to
    // LPReward (the claim gate is LP-based), so nothing reads or writes these any more.
    mapping(address => uint256) public stakeTimeAccrued;
    mapping(address => uint256) public stakeTimeCheckpoint;

    // Freeze (appended last — proxy storage stays append-only), mirroring LPReward:
    // only addresses on the early-user list (`freezeEligible`) can ever be frozen, so members who
    // join after launch are safe; a frozen address cannot unstake, unstake early or claim dividends.
    address public lpOperator;
    bool public freezeListSealed;
    mapping(address => bool) public freezeEligible;
    mapping(address => bool) public lpFrozen;

    event Staked(address indexed user, uint256 index, uint256 amount, uint256 lockDays);
    event Unstaked(address indexed user, uint256 index, uint256 amount, uint256 reward);
    event EarlyUnstaked(address indexed user, uint256 index, uint256 amount);
    event RewardDistributed(uint256 amount);
    event ExpiredSwept(address indexed user, uint256 totalDeducted);
    event RewardParked(address indexed user, uint256 amount);
    event MaxStakeRatioUpdated(uint256 bps);
    event BootstrapWindowStarted(uint256 until);
    event LpOperatorSet(address indexed operator);
    event FreezeEligibleSet(address indexed account, bool flag);
    event FreezeListSealed();
    event LpFrozenSet(address indexed account, bool flag);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// One-time initialization, called by the proxy right after deployment (delegatecall).
    function initialize(address _twoToken, address _twoProtocol) external initializer {
        __Ownable2Step_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        twoToken = IERC20(_twoToken);
        twoProtocolAddress = _twoProtocol;
        lastRewardTime = block.timestamp;
        maxStakeRatioBps = DEFAULT_MAX_STAKE_RATIO; // proxy storage starts zeroed — seed it here
    }

    /// Only the owner may upgrade the implementation (UUPS).
    function _authorizeUpgrade(address /*newImplementation*/) internal override onlyOwner {}

    /// Upgrade hook — run once through upgradeToAndCall in the SAME transaction as the implementation
    /// swap. It seeds the `maxStakeRatioBps` slot this implementation adds: proxy storage starts
    /// zeroed, so a proxy upgraded without it would read a cap of 0 and reject every new stake with
    /// "Stake cap reached". That failure is closed, never open, and recoverable on its own.
    function initStakeV2() external onlyOwner reinitializer(2) {
        maxStakeRatioBps = DEFAULT_MAX_STAKE_RATIO;
    }

    /* ============ Owner setters ============ */
    function setTwoProtocol(address _addr) external onlyOwner { twoProtocolAddress = _addr; }
    function setTwoLend(address _addr)     external onlyOwner { twoLendAddress = _addr; }
    function setStakingEnabled(bool _flag) external onlyOwner { stakingEnabled = _flag; }

    /// Owner: the staking cap, in bps of the circulating supply (see getMaxStakeAmount). Bounded by
    /// MAX_STAKE_RATIO_CEILING, a constant, so no setter call can widen it past 100%. Lowering it only
    /// affects NEW stakes: existing ones keep their terms and always unstake normally, because
    /// `unstake` / `earlyUnstake` never consult the cap.
    function setMaxStakeRatioBps(uint256 _bps) external onlyOwner {
        require(_bps <= MAX_STAKE_RATIO_CEILING, "Above ceiling");
        maxStakeRatioBps = _bps;
        emit MaxStakeRatioUpdated(_bps);
    }

    /* ============ Freeze (early-user list only) ============ */
    /// Frozen accounts cannot unstake, unstake early or claim dividends. The operator curates the
    /// early-user list and toggles the flags; the list can be sealed once at launch.
    modifier notFrozen() {
        require(!lpFrozen[msg.sender], "Stake frozen");
        _;
    }

    function setLpOperator(address _op) external onlyOwner {
        lpOperator = _op;
        emit LpOperatorSet(_op);
    }

    function setFreezeEligible(address account, bool flag) external {
        require(msg.sender == lpOperator || msg.sender == owner(), "Only operator");
        require(!freezeListSealed, "List sealed");
        require(account != address(0), "Zero address");
        freezeEligible[account] = flag;
        emit FreezeEligibleSet(account, flag);
    }

    function sealFreezeList() external onlyOwner {
        freezeListSealed = true;
        emit FreezeListSealed();
    }

    function setLpFrozen(address account, bool flag) external {
        require(msg.sender == lpOperator || msg.sender == owner(), "Only operator");
        if (flag) require(freezeEligible[account], "Not in early list");
        lpFrozen[account] = flag;
        emit LpFrozenSet(account, flag);
    }

    /// Bulk add to the early list and freeze: the operator handles the whole list in one transaction,
    /// with no per-address confirmation.
    function freezeMany(address[] calldata accounts) external {
        require(msg.sender == lpOperator || msg.sender == owner(), "Only operator");
        for (uint256 i = 0; i < accounts.length; i++) {
            address a = accounts[i];
            require(a != address(0), "Zero address");
            if (!freezeEligible[a]) {
                require(!freezeListSealed, "List sealed");
                freezeEligible[a] = true;
                emit FreezeEligibleSet(a, true);
            }
            if (!lpFrozen[a]) {
                lpFrozen[a] = true;
                emit LpFrozenSet(a, true);
            }
        }
    }

    /* ============ Read-only ============ */
    function circulatingSupply() public view returns (uint256 s) {
        (bool ok, bytes memory r) = twoProtocolAddress.staticcall(
            abi.encodeWithSignature("circulatingSupply()")
        );
        s = ok && r.length == 32 ? abi.decode(r, (uint256)) : 0;
    }
    function getMaxStakeAmount() public view returns (uint256) {
        uint256 s = circulatingSupply();
        return s == 0 ? 0 : (s * maxStakeRatioBps) / 10_000;
    }

    /// True while the bootstrap window is holding distributions (see _settleNow). Callers that
    /// simulate a snapshot must check this, or they would show a dividend that is not payable yet.
    function bootstrapHolding() public view returns (bool) {
        return bootstrapUntil != 0 && block.timestamp < bootstrapUntil;
    }

    /// Frontend query of a stake's accumulated dividend. `amount*weight*acc - rewardDebt` is now the exact
    /// payout, because the sweep no longer removes the stake's weight from the denominator; the only
    /// approximation left is the optional one-snapshot simulation below, which the caller's own
    /// transaction would perform anyway.
    function getUserPendingReward(address user, uint256 index) external view returns (uint256) {
        if (index >= userStakes[user].length) return 0;
        StakeInfo memory info = userStakes[user][index];
        if (!info.isActive) return 0;

        uint256 _acc = accumulatedRewardPerShare;
        // Simulate one snapshot (value only, no state change). Skipped while the bootstrap window is
        // holding, because no settlement would actually happen then.
        if (block.timestamp >= lastRewardTime + REWARD_INTERVAL && totalWeightedStaked > 0 && rewardPool > 0
            && !bootstrapHolding()) {
            _acc += (rewardPool * ONE_ETHER) / totalWeightedStaked;
        }
        uint256 gross = (info.amount * info.weight * _acc) / ONE_ETHER;
        return gross > info.rewardDebt ? gross - info.rewardDebt : 0;
    }

    /* ============ Dividend snapshot ============ */
    /// Moves the pending pool into the claimable reserve and raises accPerShare against the CURRENT
    /// weights. Split out of updateReward() so stake() can settle BEFORE the new weight is added —
    /// otherwise whoever joins just before an hourly snapshot is paid for the time they were not in.
    function _settleNow() internal {
        // Bootstrap window: hold every distribution until it expires, so the market has a full day to
        // join before the first settlement. Without it the backlog that accrued while nobody was staked
        // is divided by the first staker's own weight alone and lands on them entirely. Every path that
        // settles goes through here (updateReward, stake, unstake, earlyUnstake, unstakeAll, sweep),
        // so gating it here is enough — a second staker joining mid-window must not settle either.
        if (bootstrapUntil != 0) {
            if (block.timestamp < bootstrapUntil) return; // still holding
            bootstrapUntil = 0;                            // expired — clear it and settle below
        }
        if (totalWeightedStaked == 0 || rewardPool == 0) return;
        uint256 rewardAmount = rewardPool;
        rewardPool = 0;
        claimableReserve += rewardAmount;
        accumulatedRewardPerShare += (rewardAmount * ONE_ETHER) / totalWeightedStaked;
        emit RewardDistributed(rewardAmount);
    }

    function updateReward() public {
        if (block.timestamp < lastRewardTime + REWARD_INTERVAL) return;
        if (totalWeightedStaked == 0) { lastRewardTime = block.timestamp; return; }
        _settleNow();
        lastRewardTime = block.timestamp;
    }

    /// Hands `payout` to `user`. A recipient that cannot receive BNB (a contract wallet without
    /// receive(), or one that reverts) must never block the stake from being returned, so on failure
    /// the amount stays inside claimableReserve and is parked under the user's name instead.
    function _payOrPark(address user, uint256 payout) internal {
        if (payout == 0) return;
        (bool ok, ) = payable(user).call{value: payout}("");
        if (ok) {
            claimableReserve -= payout;
            totalRewardPaid += payout;
        } else {
            unclaimedReward[user] += payout;
            emit RewardParked(user, payout);
        }
    }

    /// Pull a parked dividend (see _payOrPark). The amount is still inside claimableReserve, so
    /// ownerRescueBNB keeps treating it as owed to stakers.
    function claimReward() external nonReentrant notFrozen {
        uint256 amount = unclaimedReward[msg.sender];
        require(amount > 0, "Nothing to claim");
        unclaimedReward[msg.sender] = 0;
        claimableReserve -= amount;
        totalRewardPaid += amount;
        (bool ok, ) = payable(msg.sender).call{value: amount}("");
        require(ok, "Reward transfer failed");
    }

    /* ============ Plan d: deduct matured shares from totalStaked (gas spread across operations) ============ */
    /// Scans a user's stakes, marking matured-but-undeducted ones isExpiredDeducted and
    /// decrementing totalStaked.
    ///
    /// This touches ONLY totalStaked (the stake-cap counter) — as the field comments say. It must NOT
    /// touch totalWeightedStaked, which is the dividend DENOMINATOR, because a stake's claim is
    /// `amount*weight*acc - rewardDebt`: the NUMERATOR keeps that stake's weight for as long as the stake
    /// exists. Removing the weight from the denominator while the numerator keeps growing would make
    /// every later snapshot raise `acc` by `rewardAmount / (TW - w)` while EVERY stake — the swept one
    /// included — multiplies by that same larger `acc`, so the claims would sum to more than the BNB
    /// actually injected and whoever claimed last would be shortened by the difference. And because
    /// sweepExpired() is permissionless, any third party could start that inflation for any matured
    /// stake at any moment. The weight therefore leaves the denominator where the stake itself leaves:
    /// unstake / unstakeAll / earlyUnstake.
    function _sweepExpiredForUser(address user) internal returns (uint256 deducted) {
        uint256 len = userStakes[user].length;
        for (uint256 i = 0; i < len; i++) {
            StakeInfo storage info = userStakes[user][i];
            if (info.isActive && !info.isExpiredDeducted && block.timestamp >= info.endTime) {
                totalStaked -= info.amount;
                _subActiveStaked(user, info.amount);
                info.isExpiredDeducted = true;
                deducted += info.amount;
            }
        }
        if (deducted > 0) emit ExpiredSwept(user, deducted);
    }
    function sweepExpired(address user) external {
        // Anyone can sweep (e.g. a keeper), the user can also sweep themselves.
        // Settle FIRST, before anything changes. Even though the sweep no longer touches the dividend
        // denominator (see _sweepExpiredForUser), the pool sitting in rewardPool has not been snapshotted
        // yet, and settling it against the weights that were live while it accrued is what keeps the
        // accrued share of the swept user intact. Every other path that changes weight does the same.
        _settleNow();
        _sweepExpiredForUser(user);
    }

    /// Decrement the per-user mirror without ever underflowing (see the storage note on `activeStaked`).
    function _subActiveStaked(address user, uint256 amount) internal {
        uint256 cur = activeStaked[user];
        activeStaked[user] = cur > amount ? cur - amount : 0;
    }

    /// Permissionless repair of `activeStaked` for one user, rebuilt from userStakes — it can only ever
    /// write the truth, so it cannot be used to inflate. Needed once for anyone who was already staked
    /// when this implementation went live (their mirror reads 0 until someone calls this).
    function syncActiveStaked(address user) external {
        _sweepExpiredForUser(user);
        uint256 len = userStakes[user].length;
        uint256 sum;
        for (uint256 i = 0; i < len; i++) {
            StakeInfo storage info = userStakes[user][i];
            if (info.isActive && !info.isExpiredDeducted && block.timestamp < info.endTime) sum += info.amount;
        }
        activeStaked[user] = sum;
    }

    /* ============ Stake ============ */
    function stake(uint256 amount, uint256 lockDays) external nonReentrant {
        require(stakingEnabled, "Staking closed");
        require(amount > 0, "Zero amount");
        require(lockDays == LOCK_30_DAYS || lockDays == LOCK_60_DAYS || lockDays == LOCK_90_DAYS, "Invalid lock");

        _settleNow();
        _sweepExpiredForUser(msg.sender);

        require(totalStaked + amount <= getMaxStakeAmount(), "Stake cap reached");

        twoToken.safeTransferFrom(msg.sender, address(this), amount);

        // First stake after a stretch with no stakers: open the bootstrap window. Distributed dividends
        // are held until it expires so the backlog is shared by everyone who joins within it instead of
        // being captured by this single stake. The check runs before the new weight is added, so it
        // fires exactly on the 0 -> 1 transition (and again if the pool ever empties out completely).
        if (totalWeightedStaked == 0) {
            bootstrapUntil = block.timestamp + BOOTSTRAP_WINDOW;
            emit BootstrapWindowStarted(bootstrapUntil);
        }

        uint256 index = userStakes[msg.sender].length;
        userStakes[msg.sender].push();
        StakeInfo storage info = userStakes[msg.sender][index];
        info.amount    = amount;
        info.weight    = lockDays == LOCK_60_DAYS ? WEIGHT_60 : (lockDays == LOCK_90_DAYS ? WEIGHT_90 : WEIGHT_30);
        info.startTime = block.timestamp;
        info.endTime   = block.timestamp + lockDays;
        info.rewardDebt = (amount * info.weight * accumulatedRewardPerShare) / ONE_ETHER;
        info.isActive  = true;

        totalStaked += amount;
        activeStaked[msg.sender] += amount;
        totalWeightedStaked += amount * info.weight;
        userStakeCount[msg.sender] += 1;

        emit Staked(msg.sender, index, amount, lockDays);
    }

    /* ============ Unstake at maturity (principal + dividends) ============ */
    function unstake(uint256 index) external nonReentrant notFrozen {
        require(index < userStakes[msg.sender].length, "Out of range");
        StakeInfo storage info = userStakes[msg.sender][index];
        require(info.isActive, "Not active");
        require(block.timestamp >= info.endTime, "Not mature");
        require(block.timestamp >= info.startTime + MIN_LOCK_TIME, "Locked 24h");

        _settleNow();
        _sweepExpiredForUser(msg.sender); // ensure totalStaked already deducted this matured stake (isExpiredDeducted=true)

        uint256 amount = info.amount;
        uint256 pendingReward = (amount * info.weight * accumulatedRewardPerShare) / ONE_ETHER - info.rewardDebt;

        info.isActive = false;
        info.isWithdrawn = true;
        // Guarded: the sweep above may already have deducted this stake from totalStaked.
        if (!info.isExpiredDeducted) {
            totalStaked -= amount;
            _subActiveStaked(msg.sender, amount);
            info.isExpiredDeducted = true;
        }
        // Unguarded, and exactly once: the sweep no longer removes the weight from the dividend
        // denominator, so the denominator only drops here, where the stake actually leaves.
        totalWeightedStaked -= amount * info.weight;

        uint256 payout;
        if (pendingReward > 0) {
            payout = pendingReward > claimableReserve ? claimableReserve : pendingReward;
        }
        // Principal first: a failing dividend transfer must never block the return of the stake.
        twoToken.safeTransfer(msg.sender, amount);
        _payOrPark(msg.sender, payout);
        emit Unstaked(msg.sender, index, amount, payout);
    }

    /* ============ Early unstake (principal only, no dividends; pending redistributed to the rest) ============ */
    function earlyUnstake(uint256 index) external nonReentrant notFrozen {
        require(index < userStakes[msg.sender].length, "Out of range");
        StakeInfo storage info = userStakes[msg.sender][index];
        require(info.isActive, "Not active");
        require(block.timestamp >= info.startTime + MIN_LOCK_TIME, "Locked 24h");
        require(block.timestamp <  info.endTime, "Matured; use unstake");

        _settleNow();
        _sweepExpiredForUser(msg.sender);

        uint256 amount = info.amount;
        uint256 pendingReward = (amount * info.weight * accumulatedRewardPerShare) / ONE_ETHER - info.rewardDebt;

        // The forfeited pending goes to the remaining stakers. The BNB already sits in
        // claimableReserve and STAYS there — only the entitlement moves (accPerShare). Reducing the
        // reserve as well would leave the remaining stakers' claim under-backed and turn the
        // difference into sweepable "surplus" for ownerRescueBNB.
        // Skipped entirely when the reserve is short — never lets a stale accounting block the principal return.
        if (pendingReward > 0 && claimableReserve >= pendingReward) {
            uint256 remaining = totalWeightedStaked - (info.isExpiredDeducted ? 0 : amount * info.weight);
            if (remaining > 0) {
                accumulatedRewardPerShare += (pendingReward * ONE_ETHER) / remaining;
            } else {
                // Nobody left to absorb it: release it back to the pending pool, distributed by
                // updateReward once new stakers enter (this branch MUST reduce the reserve, or the
                // amount would be counted twice once rewardPool is moved back in)
                claimableReserve -= pendingReward;
                rewardPool += pendingReward;
            }
        }

        info.isActive = false;
        info.isWithdrawn = true;
        // This stake is by definition not matured (require above), so it cannot have been swept:
        // the guard is kept for the normal reason (never deduct totalStaked twice).
        if (!info.isExpiredDeducted) {
            totalStaked -= amount;
            _subActiveStaked(msg.sender, amount);
            info.isExpiredDeducted = true;
        }
        // Unguarded, and exactly once: the denominator only drops where the stake actually leaves.
        totalWeightedStaked -= amount * info.weight;

        twoToken.safeTransfer(msg.sender, amount);
        emit EarlyUnstaked(msg.sender, index, amount);
    }

    /* ============ Batch unstake at maturity (multiple stakes at once) ============ */
    function unstakeAll(uint256 count) external nonReentrant notFrozen {
        require(count > 0, "Zero count");
        uint256 len = userStakes[msg.sender].length;
        if (count > len) count = len;

        _settleNow();
        _sweepExpiredForUser(msg.sender);

        uint256 totalAmount;
        uint256 totalReward;
        uint256 processed;
        // Skip cancelled/placeholder entries; iterate until count valid stakes have been processed (avoids under-refunding when there are gaps in between)
        for (uint256 i = 0; i < len && processed < count; i++) {
            StakeInfo storage info = userStakes[msg.sender][i];
            if (!info.isActive || info.isWithdrawn) continue;
            if (block.timestamp < info.endTime) continue;
            if (block.timestamp < info.startTime + MIN_LOCK_TIME) continue;

            uint256 amount = info.amount;
            uint256 pendingReward = (amount * info.weight * accumulatedRewardPerShare) / ONE_ETHER - info.rewardDebt;

            info.isActive = false;
            info.isWithdrawn = true;
            // Guarded: the sweep above already deducted the matured stakes from totalStaked.
            if (!info.isExpiredDeducted) {
                totalStaked -= amount;
                _subActiveStaked(msg.sender, amount);
                info.isExpiredDeducted = true;
            }
            // Unguarded, and exactly once per stake: the denominator drops here.
            totalWeightedStaked -= amount * info.weight;
            totalAmount += amount;
            totalReward += pendingReward;

            emit Unstaked(msg.sender, i, amount, pendingReward);
            processed++;
        }

        require(totalAmount > 0 || totalReward > 0, "No matured stakes");

        uint256 payout;
        if (totalReward > 0) {
            payout = totalReward > claimableReserve ? claimableReserve : totalReward;
        }
        // Principal first: a failing dividend transfer must never block the return of the stakes.
        if (totalAmount > 0) twoToken.safeTransfer(msg.sender, totalAmount);
        _payOrPark(msg.sender, payout);
    }

    /* ============ Receiving reward BNB (mint fee / V2 tax / lending interest) ============ */
    receive() external payable {
        // Plain transfer: default addFeeReward semantics (from the mint fee 50%)
        rewardPool += msg.value;
    }
    function addFeeReward()    external payable { rewardPool += msg.value; } // mint sell-fee staking 50%
    function addV2Reward()     external payable { rewardPool += msg.value; } // V2 staking 0.5%
    function addLendingReward() external payable { // lending interest 50% (only Lend)
        require(msg.sender == twoLendAddress || msg.sender == owner(), "Only lend/owner");
        rewardPool += msg.value;
    }

    /* ============ Owner emergency: can only withdraw the "pending pool" (claimableReserve always belongs to stakers) ============ */
    function emergencyWithdraw(uint256 amount) external onlyOwner {
        require(amount <= rewardPool, "Insufficient undistributed pool");
        rewardPool -= amount;
        (bool success, ) = payable(msg.sender).call{value: amount}("");
        require(success, "Transfer failed");
    }

    /// Owner rescue of STRAY BNB only: whatever the contract holds above the pools it owes.
    /// `claimableReserve` belongs to stakers who have already earned it, and `rewardPool` is
    /// earmarked for the next distribution — neither may be swept. The earlier version of this
    /// function zeroed both and paid itself, contradicting the rule emergencyWithdraw() follows.
    function ownerRescueBNB() external onlyOwner {
        uint256 owed = rewardPool + claimableReserve;
        uint256 bal = address(this).balance;
        if (bal <= owed) return;
        uint256 amount = bal - owed;
        (bool success, ) = payable(msg.sender).call{value: amount}("");
        require(success, "Transfer failed");
    }

    /// Owner rescue of tokens accidentally sent to the contract. The staked token itself is
    /// excluded: the contract's 02 balance backs user stakes, so the owner must never move it.
    function ownerRescueToken(address token, uint256 amount) external onlyOwner {
        require(token != address(0), "Zero address");
        require(token != address(twoToken), "Staked token");
        require(IERC20(token).balanceOf(address(this)) >= amount, "Insufficient balance");
        IERC20(token).safeTransfer(msg.sender, amount);
    }
}
