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

    event LPStaked(address indexed user, uint256 index, uint256 amount, uint256 lockDays);
    event LPUnstaked(address indexed user, uint256 index, uint256 amount, uint256 reward);
    event LPEarlyUnstaked(address indexed user, uint256 index, uint256 amount);
    event LPRewardDistributed(uint256 amount);
    event LPExpiredSwept(address indexed user, uint256 totalDeducted);
    event RewardParked(address indexed user, uint256 amount);

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

    /* ============ Read-only ============ */
    function getUserPendingLpReward(address user, uint256 index) external view returns (uint256) {
        if (index >= userLpStakes[user].length) return 0;
        LPStakeInfo memory info = userLpStakes[user][index];
        if (!info.isActive) return 0;
        uint256 _acc = lpAccumulatedRewardPerShare;
        if (block.timestamp >= lastLpRewardTime + REWARD_INTERVAL && totalWeightedLpStaked > 0 && lpRewardPool > 0) {
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
        } else {
            unclaimedReward[user] += payout;
            emit RewardParked(user, payout);
        }
    }

    /// Pull a parked dividend (see _payOrPark). The amount is still inside lpClaimableReserve, so
    /// ownerRescueBNB keeps treating it as owed to LP stakers.
    function claimReward() external nonReentrant {
        uint256 amount = unclaimedReward[msg.sender];
        require(amount > 0, "Nothing to claim");
        unclaimedReward[msg.sender] = 0;
        lpClaimableReserve -= amount;
        totalLpRewardPaid += amount;
        (bool ok, ) = payable(msg.sender).call{value: amount}("");
        require(ok, "Reward transfer failed");
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

    /* ============ Stake LP (30/60/90 days) ============ */
    function stakeLp(uint256 amount, uint256 lockDays) external nonReentrant {
        require(lpStakingEnabled, "LP staking closed");
        require(amount > 0, "Zero amount");
        require(lockDays == LOCK_30_DAYS || lockDays == LOCK_60_DAYS || lockDays == LOCK_90_DAYS, "Invalid lock");

        _settleNow();
        _sweepLpExpiredForUser(msg.sender);

        lpToken.safeTransferFrom(msg.sender, address(this), amount);

        uint256 index = userLpStakes[msg.sender].length;
        userLpStakes[msg.sender].push();
        LPStakeInfo storage info = userLpStakes[msg.sender][index];
        info.amount    = amount;
        info.weight    = lockDays == LOCK_60_DAYS ? WEIGHT_60 : (lockDays == LOCK_90_DAYS ? WEIGHT_90 : WEIGHT_30);
        info.startTime = block.timestamp;
        info.endTime   = block.timestamp + lockDays;
        info.rewardDebt = (amount * info.weight * lpAccumulatedRewardPerShare) / ONE_ETHER;
        info.isActive  = true;

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

        uint256 index = userLpStakes[user].length;
        userLpStakes[user].push();
        LPStakeInfo storage info = userLpStakes[user][index];
        info.amount     = amount;
        info.weight     = lockDays == LOCK_60_DAYS ? WEIGHT_60 : (lockDays == LOCK_90_DAYS ? WEIGHT_90 : WEIGHT_30);
        info.startTime  = block.timestamp;
        info.endTime    = block.timestamp + lockDays;
        info.rewardDebt = (amount * info.weight * lpAccumulatedRewardPerShare) / ONE_ETHER;
        info.isActive   = true;

        totalLpStaked += amount;
        totalWeightedLpStaked += amount * info.weight;
        userLpStakeCount[user] += 1;

        emit LPStaked(user, index, amount, lockDays);
    }

    /* ============ Unstake at maturity (principal + dividends) ============ */
    function unstakeLp(uint256 index) external nonReentrant {
        require(index < userLpStakes[msg.sender].length, "Out of range");
        LPStakeInfo storage info = userLpStakes[msg.sender][index];
        require(info.isActive, "Not active");
        require(block.timestamp >= info.endTime, "Not mature");
        require(block.timestamp >= info.startTime + MIN_LOCK_TIME, "Locked 24h");

        _settleNow();
        _sweepLpExpiredForUser(msg.sender);

        uint256 amount = info.amount;
        uint256 pendingReward = (amount * info.weight * lpAccumulatedRewardPerShare) / ONE_ETHER - info.rewardDebt;

        info.isActive = false;
        info.isWithdrawn = true;
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
        // Settle referral rewards at maturity: accrue 1% to the referrer only if governance is enabled and the stake started after governance activation (never blocks withdrawal)
        if (foundation != address(0)) {
            (bool s, ) = foundation.call(abi.encodeWithSignature("settleReferral(address,uint256,uint256)", msg.sender, amount, info.startTime));
            s;
        }
        emit LPUnstaked(msg.sender, index, amount, payout);
    }

    /* ============ Early unstake (principal only, no dividends; pending redistributed to the rest) ============ */
    function earlyUnstakeLp(uint256 index) external nonReentrant {
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

        info.isActive = false;
        info.isWithdrawn = true;
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
    function unstakeAllLp(uint256 count) external nonReentrant {
        require(count > 0, "Zero count");
        uint256 len = userLpStakes[msg.sender].length;
        if (count > len) count = len;

        _settleNow();
        _sweepLpExpiredForUser(msg.sender);

        uint256 totalAmount;
        uint256 totalReward;
        uint256 processed;
        // Skip cancelled/placeholder entries; iterate until count valid stakes have been processed (avoids under-refunding when there are gaps in between)
        for (uint256 i = 0; i < len && processed < count; i++) {
            LPStakeInfo storage info = userLpStakes[msg.sender][i];
            if (!info.isActive || info.isWithdrawn) continue;
            if (block.timestamp < info.endTime) continue;
            if (block.timestamp < info.startTime + MIN_LOCK_TIME) continue;

            uint256 amount = info.amount;
            uint256 pendingReward = (amount * info.weight * lpAccumulatedRewardPerShare) / ONE_ETHER - info.rewardDebt;

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

            // Settle referral rewards per stake, exactly like the single unstake path does — the batch
            // path used to skip it entirely, so a referred user who unstaked through the batch left
            // their referrer with nothing (the referral is otherwise only ever settled here).
            if (foundation != address(0)) {
                (bool sr, ) = foundation.call(abi.encodeWithSignature("settleReferral(address,uint256,uint256)", msg.sender, amount, info.startTime));
                sr;
            }

            emit LPUnstaked(msg.sender, i, amount, pendingReward);
            processed++;
        }

        require(totalAmount > 0 || totalReward > 0, "No matured stakes");

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
