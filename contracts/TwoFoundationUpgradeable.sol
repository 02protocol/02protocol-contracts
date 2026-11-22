// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

interface IPancakePair {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function token0() external view returns (address);
}

/// Destination of the V14 tax slice once the mining pool exists: it registers the received 02 as its own
/// budget. Kept minimal (and called through try/catch) so a sink upgrade can never block a seller.
interface ITwoPoolSink {
    function syncBudget() external returns (uint256);
}

/// @title TwoFoundationUpgradeable
/// @notice 02Protocol Foundation: multisig management + community donations + LP referral incentives.
///   - Multisig: 5 members by default, 3 required confirmations (required is adjustable). Members can join/leave (multisig approval).
///   - Donations: 02 donations go into the LP referral incentive pool; BNB / USDT donations go into the community-building fund.
///   - LP referral incentives: a user binds a referrer; every time LPReward pays that user BNB dividends, the direct
///     referrer is credited the same value in 02 (converted at the 02/WBNB pool price) and the incentive pool budget is
///     deducted by that amount. Once the budget is used up no further referral rewards accrue.
///   - Community funds (BNB/USDT) and the incentive pool (02) can both be spent via multisig (generic multisig transactions).
contract TwoFoundationUpgradeable is
    Initializable,
    Ownable2StepUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    uint256 public constant MAX_REQUIRED = 9;

    /// @notice Public notice period in front of every implementation / ownership change executed by this
    ///   multisig. A proposal touching `upgradeTo`, `upgradeToAndCall`, `transferOwnership` or
    ///   `renounceOwnership` can only be executed once it has been visible on chain for this long.
    uint256 public constant UPGRADE_DELAY = 24 hours;

    /* ============ Multisig members ============ */
    address[] public signers;
    mapping(address => bool) public isSigner;
    uint256 public required; // required confirmations (default 3)

    /// Multisig transaction spend category (chosen when submitting; on successful execution it enters the expenditure ledger)
    enum SpendCategory { NONE, COMMUNITY, MEMBER, DAO_ACTION, OTHER }

    struct Transaction {
        address to;
        uint256 value;
        bytes data;
        bool executed;
        uint256 confirmCount;
        uint8   category;   // SpendCategory (0=NONE, not recorded as expenditure)
        string  note;
        mapping(address => bool) confirmed;
    }
    Transaction[] public transactions;

    /* ============ Expenditure ledger ============ */
    struct ExpenditureRecord {
        uint256 txId;
        address to;
        uint256 value;
        bytes data;
        uint8   category;
        string  note;
        uint256 timestamp;
    }
    ExpenditureRecord[] public expenditureRecords;

    /* ============ Donations ============ */
    IERC20 public twoToken; // 02
    IERC20 public usdt;     // USDT

    uint256 public lpIncentivePool; // 02 referral-incentive budget: += every donateTwo receipt, -= every claimIncentive payout
    uint256 public communityUsdt;   // community-building USDT (the usdt balance is the source of truth)

    enum AssetType { TWO, BNB, USDT }

    struct DonationRecord {
        address donor;
        AssetType assetType;
        uint256 amount;
        uint256 timestamp;
    }
    DonationRecord[] public donationRecords;

    struct DonatorStat {
        uint256 twoAmount;
        uint256 bnbAmount;
        uint256 usdtAmount;
        uint256 count;
    }
    mapping(address => DonatorStat) public donators;

    /* ============ LP referral incentives ============ */
    mapping(address => address) public referrers; // user -> referrer (one-time binding)
    mapping(address => uint256) public referralRewards; // referrer's cumulative 02 entitlement
    uint256 public referralBps; // share of the referee's BNB dividend credited to the referrer (10000 = 100%)
    address public lpReward;    // LPReward contract (calls back onLpDividend when BNB dividends are paid)

    /* ============ DAO association ============ */
    address public dao; // TwoDAO (executing/rejecting user proposals goes through generic multisig transactions)

    /* ============ Announcements ============ */
    struct Announcement {
        string title;
        string content;
        uint256 timestamp;
    }
    /// Addresses allowed to publish announcements (granted/revoked by multisig)
    mapping(address => bool) public announcementPublishers;
    Announcement[] public announcements;

    /* ============ Feature switches (append-only: must be appended at the end; inserting before old variables is forbidden, otherwise upgrades would shift existing storage) ============ */
    bool public donationsEnabled;      // donation feature switch (default false; once the owner enables it the frontend shows the donation page)
    bool public governanceEnabled;     // DAO governance / referral switch (default false; the owner enables it at an opportune time)
    uint256 public governanceActivatedAt; // governance activation timestamp (referral settlement check: the stake must start after activation)

    /* ============ Referral dividend matching (appended: never insert above) ============ */
    address public referralPricePair;     // 02/WBNB Pancake pair used to convert BNB dividends into 02
    uint256 public referralAccruedTotal;  // lifetime 02 credited to referrers (diagnostics)

    /* ============ Referral risk controls (appended: never insert above) ============ */
    // The pool is the only input a manipulator controls, so the conversion price is banded around an
    // anchor: spot can move the payout by at most `referralBandBps` (2000 = ±20%). 0 = unconfigured,
    // in which case nothing accrues (fail closed — see _bnbToTwo).
    uint256 public referralAnchorTwoPerBnb; // anchor price, 02 per 1 BNB (1e18 = 1 02 per BNB)
    uint256 public referralBandBps;         // allowed spot deviation from the anchor, in bps
    address public stakingContract;         // RewardDistributor, read for the referrer stake threshold
    uint256 public minReferrerStake;        // minimum active single-token stake for a referrer (0 = off)
    uint256 public minReferrerStakeAge;     // minimum CUMULATIVE LP staking time (seconds) required to claim (0 = off)
    mapping(address => address[]) public referrals; // referrer -> users who bound them (frontend estimate)
    mapping(address => uint256) public referralCount; // number of entries in `referrals` (not enumerable on-chain)
    address public lpStakingContract;       // LPReward, read for the LP gates below
    uint256 public minReferrerLp;           // minimum live LP stake a referrer must hold to claim (0 = off)

    // Appended: 02 actually paid out through claimIncentive. Together with `referralAccruedTotal`
    // (lifetime credited) it gives the exact amount still owed to referrers, which is what
    // `sweepIdleTwo` must leave untouched.
    uint256 public referralClaimedTotal;

    // Appended: where new referral income goes once the mining pool is live. While this is set, the
    // V14 tax slice is forwarded to the mining-pool budget instead of piling up in `lpIncentivePool`
    // (a programme that no longer accrues). Zero keeps the legacy behaviour exactly as it was.
    address public poolSink;

    /* ============ Upgrade timelock (appended: never insert above) ============ */
    /// Submission time of every multisig transaction — the start of its public notice period.
    /// Proposals submitted before this variable existed read 0, which means "notice already elapsed".
    mapping(uint256 => uint256) public txSubmittedAt;

    /* ============ Events ============ */
    /// V14: 02 credited to the referral-incentive pool from the protocol's tax leg
    event ReferralPoolCredited(address indexed source, uint256 amount, uint256 pool);
    event SignerAdded(address indexed signer);
    event SignerRemoved(address indexed signer);
    event RequirementChanged(uint256 oldRequired, uint256 newRequired);
    event TransactionSubmitted(uint256 indexed txId, address indexed proposer, address to, uint256 value, bytes data, uint8 category);
    event TransactionConfirmed(uint256 indexed txId, address indexed signer);
    event TransactionRevoked(uint256 indexed txId, address indexed signer);
    event TransactionExecuted(uint256 indexed txId, address to, uint256 value, bytes data);
    event ExpenditureRecorded(uint256 indexed txId, address to, uint256 value, uint8 category, string note, uint256 timestamp);

    event Donated(address indexed donor, AssetType assetType, uint256 amount, uint256 timestamp);
    event ReferrerSet(address indexed user, address indexed referrer);
    event ReferralRewardAccrued(address indexed referrer, address indexed user, uint256 lpAmount, uint256 reward);
    event ReferralDividendAccrued(address indexed referrer, address indexed user, uint256 bnbAmount, uint256 reward);
    event ReferralPricePairSet(address pair);
    event ReferralAnchorSet(uint256 twoPerBnb, uint256 bandBps);
    event ReferralStakeGateSet(address staking, uint256 minStake);
    event ReferralStakeAgeSet(uint256 secondsRequired);
    event ReferralLpGateSet(address lpStaking, uint256 minLp);
    event IncentiveClaimed(address indexed referrer, uint256 amount);
    event ReferralBpsSet(uint256 bps);
    event IdleTwoSwept(address indexed to, uint256 amount);
    event PoolSinkSet(address indexed sink);
    event ReferralPoolForwarded(address indexed sink, uint256 amount);
    event LpRewardSet(address lpReward);
    event DaoSet(address dao);
    event AnnouncementPublisherSet(address indexed addr, bool allowed);
    event AnnouncementPublished(uint256 indexed id, address indexed publisher, string title, string content, uint256 timestamp);
    event DonationsEnabledSet(bool enabled);
    event GovernanceEnabled(uint256 at);

    /// A proposal that changes an implementation or an owner was submitted: it stays public until `executableAt`.
    event UpgradeNoticeStarted(uint256 indexed txId, uint256 executableAt);

    /// Selectors that can replace the code behind a proxy or move its ownership. Those are the only
    /// multisig actions with a mandatory 24h public notice period (`UPGRADE_DELAY`); everything else
    /// executes as soon as `required` confirmations are in, so day-to-day operations stay fast.
    bytes4 private constant SEL_UPGRADE_TO = 0x3659cfe6;          // upgradeTo(address)
    bytes4 private constant SEL_UPGRADE_TO_AND_CALL = 0x4f1ef286; // upgradeToAndCall(address,bytes)
    bytes4 private constant SEL_TRANSFER_OWNERSHIP = 0xf2fde38b;  // transferOwnership(address)
    bytes4 private constant SEL_RENOUNCE_OWNERSHIP = 0x715018a6;  // renounceOwnership()

    modifier onlySelfOrOwner() {
        require(msg.sender == address(this) || msg.sender == owner(), "Not self/owner");
        _;
    }
    modifier onlySigner() {
        require(isSigner[msg.sender], "Not signer");
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address[] calldata _signers, uint256 _required, address _twoToken, address _usdt) external initializer {
        __Ownable2Step_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        require(_signers.length > 0 && _signers.length <= MAX_REQUIRED * 2, "Bad signers");
        require(_required > 0 && _required <= _signers.length, "Bad required");
        require(_twoToken != address(0) && _usdt != address(0), "Zero address");

        for (uint256 i = 0; i < _signers.length; i++) {
            require(_signers[i] != address(0) && !isSigner[_signers[i]], "Dup/zero signer");
            signers.push(_signers[i]);
            isSigner[_signers[i]] = true;
        }
        required = _required;
        twoToken = IERC20(_twoToken);
        usdt = IERC20(_usdt);
        referralBps = 3000; // 30% of the referee's BNB dividend, converted to 02 (governable)
        referralBandBps = 2000; // ±20% around the anchor price; the anchor itself is set by the owner
    }

    function _authorizeUpgrade(address /*newImplementation*/) internal override onlyOwner {}

    /* ============ Multisig member management (multisig approval / owner) ============ */
    function addSigner(address _signer) external onlySelfOrOwner {
        require(_signer != address(0), "Zero address");
        require(!isSigner[_signer], "Already signer");
        require(signers.length < MAX_REQUIRED * 2, "Too many signers");
        isSigner[_signer] = true;
        signers.push(_signer);
        emit SignerAdded(_signer);
    }

    function removeSigner(address _signer) external onlySelfOrOwner {
        require(isSigner[_signer], "Not signer");
        require(signers.length > 1, "Last signer");
        // A removed signer's existing confirmations would keep counting: confirmCount is a running total
        // that removal does not (and cannot, per-transaction) recompute, so a pending transaction could
        // reach `required` with fewer CURRENT signers than the threshold demands. Refuse to drop a signer
        // that is still on the hook for a pending transaction — the signer revokes first, then leaves.
        for (uint256 i = 0; i < transactions.length; i++) {
            require(transactions[i].executed || !transactions[i].confirmed[_signer], "Pending confirmation");
        }
        isSigner[_signer] = false;
        for (uint256 i = 0; i < signers.length; i++) {
            if (signers[i] == _signer) {
                signers[i] = signers[signers.length - 1];
                signers.pop();
                break;
            }
        }
        if (required > signers.length) required = signers.length;
        emit SignerRemoved(_signer);
    }

    function changeRequired(uint256 _required) external onlySelfOrOwner {
        require(_required > 0 && _required <= signers.length, "Bad required");
        emit RequirementChanged(required, _required);
        required = _required;
    }

    /* ============ Multisig transactions ============ */
    function submitTransaction(
        address _to,
        uint256 _value,
        bytes calldata _data,
        uint8 _category,
        string calldata _note
    ) external onlySigner returns (uint256 txId) {
        require(_to != address(0), "Zero to");
        require(_category <= uint8(SpendCategory.OTHER), "Bad category");
        txId = transactions.length;
        transactions.push();
        Transaction storage t = transactions[txId];
        t.to = _to;
        t.value = _value;
        t.data = _data;
        t.category = _category;
        t.note = _note;
        t.confirmed[msg.sender] = true;
        t.confirmCount = 1;
        txSubmittedAt[txId] = block.timestamp;
        emit TransactionSubmitted(txId, msg.sender, _to, _value, _data, _category);
        emit TransactionConfirmed(txId, msg.sender);
        if (_requiresUpgradeNotice(_data)) {
            emit UpgradeNoticeStarted(txId, block.timestamp + UPGRADE_DELAY);
        }
    }

    function confirmTransaction(uint256 txId) external onlySigner nonReentrant {
        Transaction storage t = transactions[txId];
        require(txId < transactions.length && !t.executed, "Bad tx");
        require(!t.confirmed[msg.sender], "Already confirmed");
        t.confirmed[msg.sender] = true;
        t.confirmCount += 1;
        emit TransactionConfirmed(txId, msg.sender);
    }

    function revokeConfirmation(uint256 txId) external onlySigner {
        Transaction storage t = transactions[txId];
        require(txId < transactions.length && !t.executed, "Bad tx");
        require(t.confirmed[msg.sender], "Not confirmed");
        t.confirmed[msg.sender] = false;
        t.confirmCount -= 1;
        emit TransactionRevoked(txId, msg.sender);
    }

    function executeTransaction(uint256 txId) external nonReentrant {
        Transaction storage t = transactions[txId];
        require(txId < transactions.length && !t.executed, "Bad tx");
        require(t.confirmCount >= required, "Not enough confirms");
        // Implementation / ownership changes only become executable after the proposal has been public
        // on chain for UPGRADE_DELAY. Everything else executes immediately once the threshold is met.
        if (_requiresUpgradeNotice(t.data)) {
            require(block.timestamp >= txSubmittedAt[txId] + UPGRADE_DELAY, "Upgrade notice period");
        }

        t.executed = true;
        emit TransactionExecuted(txId, t.to, t.value, t.data);

        (bool success, ) = t.to.call{value: t.value}(t.data);
        require(success, "Tx failed");

        // Categorized expenditure accounting: when execution succeeds and a category was chosen, write to the expenditure ledger
        if (t.category != uint8(SpendCategory.NONE)) {
            expenditureRecords.push(ExpenditureRecord(
                txId, t.to, t.value, t.data, t.category, t.note, block.timestamp
            ));
            emit ExpenditureRecorded(txId, t.to, t.value, t.category, t.note, block.timestamp);
        }
    }

    function getTransactionCount() external view returns (uint256) { return transactions.length; }

    /// @notice Unix time from which proposal `txId` may be executed (0 = not a noticed proposal / unknown).
    function upgradeExecutableAt(uint256 txId) external view returns (uint256) {
        uint256 submittedAt = txId < transactions.length ? txSubmittedAt[txId] : 0;
        return submittedAt == 0 ? 0 : submittedAt + UPGRADE_DELAY;
    }

    function _requiresUpgradeNotice(bytes memory _data) private pure returns (bool) {
        if (_data.length < 4) return false;
        bytes4 selector;
        assembly {
            selector := mload(add(_data, 32))
        }
        return selector == SEL_UPGRADE_TO
            || selector == SEL_UPGRADE_TO_AND_CALL
            || selector == SEL_TRANSFER_OWNERSHIP
            || selector == SEL_RENOUNCE_OWNERSHIP;
    }

    function getExpenditureRecordCount() external view returns (uint256) { return expenditureRecords.length; }
    function getSigners() external view returns (address[] memory) { return signers; }
    function isConfirmed(uint256 txId, address addr) external view returns (bool) {
        return txId < transactions.length && transactions[txId].confirmed[addr];
    }

    /* ============ Donations ============ */
    /// Credit referral-incentive 02 that the PROTOCOL sends in (V14 tax leg). Pull-based and verified
    /// against the balance delta, exactly like donateTwo, because during the mint phase a 02 transfer
    /// between two non-whitelisted addresses is burned on the way — crediting the requested amount would
    /// then record income the contract never received. Unlike donateTwo this is not a donation (no donor
    /// record) and is not gated on `donationsEnabled`: it is protocol revenue, not a user action.
    /// `claimIncentive` pays only out of the CREDITED budget (lpIncentivePool), never out of the whole 02
    /// balance, so this is what makes the tax income spendable as referral rewards.
    function creditReferralPool(uint256 amount) external nonReentrant {
        require(amount > 0, "Zero amount");
        uint256 before = twoToken.balanceOf(address(this));
        twoToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = twoToken.balanceOf(address(this)) - before;
        require(received > 0, "Income not received");

        // Once the mining pool is live every new slice goes straight to its 02 budget, so the old
        // (non-accruing) referral pool cannot quietly refill after it was swept.
        address sink = poolSink;
        if (sink != address(0)) {
            twoToken.safeTransfer(sink, received);
            // Best-effort registration: if the sink's sync reverts the 02 is still there and anyone can
            // call syncBudget() later, so a sink-side hiccup must never revert a seller's transfer.
            try ITwoPoolSink(sink).syncBudget() {} catch {}
            emit ReferralPoolForwarded(sink, received);
            return;
        }

        lpIncentivePool += received;
        emit ReferralPoolCredited(msg.sender, received, lpIncentivePool);
    }

    /// Destination of new referral income (the burn-mine contract). Zero restores the legacy pool.
    function setPoolSink(address _sink) external onlySelfOrOwner {
        poolSink = _sink;
        emit PoolSinkSet(_sink);
    }

    /// 02 donation. With `poolSink` set it lands in the mining-pool budget like the tax slice; otherwise
    /// it credits the legacy referral pool. The donor record is written either way, so the donation
    /// history never depends on where the money is routed.
    function donateTwo(uint256 amount) external nonReentrant {
        require(donationsEnabled, "Donations closed");
        require(amount > 0, "Zero amount");
        // Credit what actually ARRIVES, not what was asked for. During the mint phase 02 only moves
        // freely between whitelisted addresses; a donation from an ordinary holder would be BURNED on
        // the way here (the token's transfer hook burns it outright). Crediting `amount` regardless
        // would then record a donation the contract never received — the donor loses the tokens and
        // the pool ends up claiming more than it holds.
        uint256 before = twoToken.balanceOf(address(this));
        twoToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = twoToken.balanceOf(address(this)) - before;
        require(received > 0, "Donation not received");

        donators[msg.sender].twoAmount += received;
        donators[msg.sender].count += 1;
        donationRecords.push(DonationRecord(msg.sender, AssetType.TWO, received, block.timestamp));
        emit Donated(msg.sender, AssetType.TWO, received, block.timestamp);

        address sink = poolSink;
        if (sink != address(0)) {
            twoToken.safeTransfer(sink, received);
            try ITwoPoolSink(sink).syncBudget() {} catch {}
            emit ReferralPoolForwarded(sink, received);
            return;
        }
        lpIncentivePool += received;
    }

    /// BNB donation -> community-building fund
    function donateBNB() external payable nonReentrant {
        require(donationsEnabled, "Donations closed");
        require(msg.value > 0, "Zero amount");
        donators[msg.sender].bnbAmount += msg.value;
        donators[msg.sender].count += 1;
        donationRecords.push(DonationRecord(msg.sender, AssetType.BNB, msg.value, block.timestamp));
        emit Donated(msg.sender, AssetType.BNB, msg.value, block.timestamp);
    }

    /// USDT donation -> community-building fund
    function donateUsdt(uint256 amount) external nonReentrant {
        require(donationsEnabled, "Donations closed");
        require(amount > 0, "Zero amount");
        // Same rule as donateTwo: credit what actually ARRIVES, not what was asked for, so the
        // recorded total cannot drift from the contract's real balance if `usdt` is ever pointed at a
        // fee-on-transfer token.
        uint256 before = usdt.balanceOf(address(this));
        usdt.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = usdt.balanceOf(address(this)) - before;
        require(received > 0, "Donation not received");
        communityUsdt += received;
        donators[msg.sender].usdtAmount += received;
        donators[msg.sender].count += 1;
        donationRecords.push(DonationRecord(msg.sender, AssetType.USDT, received, block.timestamp));
        emit Donated(msg.sender, AssetType.USDT, received, block.timestamp);
    }

    function getDonationRecordCount() external view returns (uint256) { return donationRecords.length; }

    /* ============ LP referral incentives ============ */
    /// User binds a referrer (one-time, cannot be changed)
    function setReferrer(address _referrer) external {
        require(_referrer != address(0) && _referrer != msg.sender, "Bad referrer");
        require(referrers[msg.sender] == address(0), "Already set");
        referrers[msg.sender] = _referrer;
        // Reverse index so a referrer (and the frontend) can enumerate who they referred — the forward
        // mapping alone cannot be walked on-chain.
        referrals[_referrer].push(msg.sender);
        referralCount[_referrer] += 1;
        emit ReferrerSet(msg.sender, _referrer);
    }

    /// All users who bound `ref` as their referrer. View only, meant for the frontend's live estimate.
    function getReferrals(address ref) external view returns (address[] memory) {
        return referrals[ref];
    }

    /// Callback from LPReward every time a staker is actually paid BNB dividends. The direct referrer is
    /// credited the same value in 02, converted at the 02/WBNB pool price, and that amount is deducted from
    /// the incentive budget immediately — so the budget is what caps total referral payouts: once it reaches
    /// zero nothing more accrues. Two gates keep this from being farmed: the referrer must hold at least
    /// `minReferrerStake` in active single-token staking, and the conversion price is clamped to the anchor.
    function onLpDividend(address user, uint256 bnbAmount) external nonReentrant {
        require(msg.sender == lpReward, "Only lpReward");
        if (!governanceEnabled || bnbAmount == 0 || referralBps == 0) return;
        address ref = referrers[user];
        if (ref == address(0)) return;
        if (!_referrerQualifies(ref)) return;
        uint256 budget = lpIncentivePool;
        if (budget == 0) return;
        uint256 bnbShare = (bnbAmount * referralBps) / 10000;
        uint256 reward = _bnbToTwo(bnbShare);
        if (reward == 0) return;
        if (reward > budget) reward = budget; // budget exhausted: pay what is left, then stop
        lpIncentivePool = budget - reward;
        referralRewards[ref] += reward;
        referralAccruedTotal += reward;
        emit ReferralDividendAccrued(ref, user, bnbAmount, reward);
    }

    /// Referrer admission rule: at least `minReferrerStake` in live single-token staking. Read through a
    /// staticcall because the staking contract is upgraded separately and may not expose the mirror yet —
    /// a failed read fails CLOSED. The caller (LPReward) ignores this callback's success, so returning
    /// early here can never block a staker's dividend; it only means no referral reward is credited.
    function _referrerQualifies(address ref) internal view returns (bool) {
        uint256 minStake = minReferrerStake;
        if (minStake == 0) return true; // gate disabled
        if (stakingContract == address(0)) return false;
        return _referrerStakeAmount(ref) >= minStake;
    }

    /// Live single-token stake of `ref`. Same staticcall / fail-CLOSED treatment as the age gate: an
    /// unreadable value reads as 0, never as "assume they are staking".
    function _referrerStakeAmount(address ref) internal view returns (uint256) {
        address rd = stakingContract;
        if (rd == address(0)) return 0;
        (bool ok, bytes memory data) = rd.staticcall(abi.encodeWithSignature("activeStaked(address)", ref));
        if (!ok || data.length < 32) return 0;
        return abi.decode(data, (uint256));
    }

    /// Live LP stake of `ref`, recomputed by LPReward from its own stake records (no mirror to migrate).
    /// An unreadable value reads as 0 (fail CLOSED), never as "assume they are staking".
    function _referrerLpAmount(address ref) internal view returns (uint256) {
        address lpr = lpStakingContract;
        if (lpr == address(0)) return 0;
        (bool ok, bytes memory data) = lpr.staticcall(abi.encodeWithSignature("activeLpAmount(address)", ref));
        if (!ok || data.length < 32) return 0;
        return abi.decode(data, (uint256));
    }

    /// Cumulative seconds `ref` has kept LP locked (earned across several stakes, reset to 0 once all LP
    /// is withdrawn). Same staticcall / fail-CLOSED treatment as the amount gate.
    function _referrerLpAge(address ref) internal view returns (uint256 age) {
        address lpr = lpStakingContract;
        if (lpr == address(0)) return 0;
        (bool ok, bytes memory data) = lpr.staticcall(abi.encodeWithSignature("activeLpStakeAge(address)", ref));
        if (!ok || data.length < 32) return 0;
        return abi.decode(data, (uint256));
    }

    /// BNB -> 02. The spot price (02 per BNB) is clamped to the anchor ±band before it is applied, so
    /// moving the pool — the only input an attacker controls — can shift the payout by at most the band.
    /// With no anchor configured nothing accrues (fail CLOSED): pricing off a raw, manipulable spot is
    /// exactly the hole the band exists to close, so it must never be the silent fallback.
    function _bnbToTwo(uint256 bnbAmount) internal view returns (uint256) {
        if (bnbAmount == 0) return 0;
        uint256 anchor = referralAnchorTwoPerBnb;
        if (anchor == 0) return 0;
        uint256 spot = _spotTwoPerBnb();
        if (spot == 0) return 0;
        uint256 band = referralBandBps;
        uint256 lo = (anchor * (10000 - band)) / 10000;
        uint256 hi = (anchor * (10000 + band)) / 10000;
        uint256 price = spot < lo ? lo : (spot > hi ? hi : spot);
        return (bnbAmount * price) / 1e18;
    }

    /// 02 per 1 BNB, 1e18-scaled, read straight off the pair reserves.
    function _spotTwoPerBnb() internal view returns (uint256) {
        address pair = referralPricePair;
        if (pair == address(0)) return 0;
        (uint112 r0, uint112 r1, ) = IPancakePair(pair).getReserves();
        if (r0 == 0 || r1 == 0) return 0;
        (uint256 rTwo, uint256 rBnb) = IPancakePair(pair).token0() == address(twoToken)
            ? (uint256(r0), uint256(r1))
            : (uint256(r1), uint256(r0));
        if (rBnb == 0) return 0;
        return (rTwo * 1e18) / rBnb;
    }

    /* ============ Legacy referral callbacks (retired) ============ */
    /// Superseded by onLpDividend. Kept as no-ops so an LPReward implementation that still calls them (the
    /// deployed one does, until it is upgraded) cannot accrue the old 1%-of-LP reward on top of the new one.
    function onLpStake(address, uint256) external pure {}

    function settleReferral(address, uint256, uint256) external pure {}

    /// Referrer claims 02 rewards (from the incentive pool)
    function claimIncentive() external nonReentrant {
        uint256 pending = referralRewards[msg.sender];
        require(pending > 0, "Nothing to claim");
        // Claim gates: the reward is already booked, but it only becomes withdrawable while the referrer
        // is STILL an LP staker. (a) at least `minReferrerLp` in live LP staking; (b) the cumulative LP
        // staking clock has reached `minReferrerStakeAge` — it accumulates across stakes and is wiped
        // when all LP is withdrawn. A refused claim never loses the entitlement: it stays booked until
        // the requirement is met.
        uint256 minLp = minReferrerLp;
        if (minLp > 0) require(_referrerLpAmount(msg.sender) >= minLp, "Not enough LP");
        uint256 minAge = minReferrerStakeAge;
        if (minAge > 0) require(_referrerLpAge(msg.sender) >= minAge, "LP stake too short");
        // The incentive budget is deducted when a reward ACCRUES (see onLpDividend), so the entitlement is
        // already reserved and must not be charged against the pool a second time here. Only the actual 02
        // balance can limit the transfer (02 may have left for other multisig-approved purposes).
        uint256 poolBal = twoToken.balanceOf(address(this));
        uint256 payout = pending > poolBal ? poolBal : pending;
        require(payout > 0, "Pool empty");
        referralRewards[msg.sender] -= payout;
        // Verify the payout actually arrived, exactly like donateTwo does on the way in. During the mint
        // phase TwoProtocol burns any 02 transfer whose sender AND recipient are both off the whitelist —
        // and this contract is NOT whitelisted by default. Without this check the burn would still return
        // success, so the accounting above would be consumed while the referrer received nothing and the
        // pool's 02 was destroyed. Reverting keeps the entitlement intact and makes the misconfiguration
        // visible instead of silently eating the reward.
        uint256 balBefore = twoToken.balanceOf(msg.sender);
        twoToken.safeTransfer(msg.sender, payout);
        require(twoToken.balanceOf(msg.sender) - balBefore == payout, "Incentive not delivered");
        referralClaimedTotal += payout;
        emit IncentiveClaimed(msg.sender, payout);
    }

    /// 02 still owed to referrers: everything ever credited minus everything already paid out.
    function referralOutstanding() public view returns (uint256) {
        uint256 accrued = referralAccruedTotal;
        uint256 paid = referralClaimedTotal;
        return accrued > paid ? accrued - paid : 0;
    }

    /// Moves the un-owed 02 out of this contract. With `referralBps` at 0 the old referral programme
    /// no longer accrues, so its budget would otherwise sit here forever. The transfer is bounded by
    /// `balance − referralOutstanding()`, which keeps every booked entitlement fully backed — the
    /// owner (3/5 multisig) only decides where the idle part goes, never how much of it is idle.
    function sweepIdleTwo(address to, uint256 amount) external onlySelfOrOwner nonReentrant {
        require(to != address(0), "Zero address");
        require(amount > 0, "Zero amount");
        uint256 balance = twoToken.balanceOf(address(this));
        uint256 idle = balance > referralOutstanding() ? balance - referralOutstanding() : 0;
        require(amount <= idle, "Exceeds idle balance");
        twoToken.safeTransfer(to, amount);
        emit IdleTwoSwept(to, amount);
    }

    function setReferralBps(uint256 _bps) external onlySelfOrOwner {
        require(_bps <= 10000, "Over cap"); // cap 100% of the referee's BNB dividend
        referralBps = _bps;
        emit ReferralBpsSet(_bps);
    }

    /// 02/WBNB pair used to price BNB dividends into 02. Must be set before referral rewards can accrue.
    function setReferralPricePair(address _pair) external onlySelfOrOwner {
        require(_pair != address(0), "Zero address");
        referralPricePair = _pair;
        emit ReferralPricePairSet(_pair);
    }

    /// Anchor conversion price (02 per 1 BNB, 1e18 scaled) and the band around it, set together so the two
    /// can never be inconsistent. A wide band buys little protection, so it is capped at ±50%.
    /// `_twoPerBnb = 0` turns banding off and falls back to the raw spot price.
    function setReferralAnchor(uint256 _twoPerBnb, uint256 _bandBps) external onlySelfOrOwner {
        require(_bandBps <= 5000, "Band too wide");
        referralAnchorTwoPerBnb = _twoPerBnb;
        referralBandBps = _bandBps;
        emit ReferralAnchorSet(_twoPerBnb, _bandBps);
    }

    /// Referrer admission: only addresses holding at least `_minStake` 02 in active single-token staking
    /// earn. 0 disables the gate; a non-zero value with no staking contract fails closed.
    function setReferralStakeGate(address _staking, uint256 _minStake) external onlySelfOrOwner {
        stakingContract = _staking;
        minReferrerStake = _minStake;
        emit ReferralStakeGateSet(_staking, _minStake);
    }

    /// Claim gate, amount: the referrer must hold at least `_minLp` in live LP staking. 0 disables it;
    /// a non-zero value with no LP staking contract fails closed.
    function setReferralLpGate(address _lpStaking, uint256 _minLp) external onlySelfOrOwner {
        lpStakingContract = _lpStaking;
        minReferrerLp = _minLp;
        emit ReferralLpGateSet(_lpStaking, _minLp);
    }

    /// Claim gate, time: minimum CUMULATIVE LP staking time (seconds) a referrer needs before the booked
    /// reward can be claimed. The clock accumulates across stakes and resets when all LP is withdrawn.
    /// 0 disables the gate. Capped at 90 days so a typo cannot lock the entitlement forever.
    function setReferralStakeAge(uint256 _seconds) external onlySelfOrOwner {
        require(_seconds <= 90 days, "Age too long");
        minReferrerStakeAge = _seconds;
        emit ReferralStakeAgeSet(_seconds);
    }

    function setLpReward(address _lpReward) external onlyOwner {
        require(_lpReward != address(0), "Zero address");
        lpReward = _lpReward;
        emit LpRewardSet(_lpReward);
    }

    /* ============ DAO association ============ */
    function setDao(address _dao) external onlyOwner {
        require(_dao != address(0), "Zero address");
        dao = _dao;
        emit DaoSet(_dao);
    }

    /* ============ Feature switches (enabled by the owner at an opportune time) ============ */
    /// Enable/disable donations (once enabled, the frontend shows the donation page and the community can donate)
    function setDonationsEnabled(bool _enabled) external onlyOwner {
        donationsEnabled = _enabled;
        emit DonationsEnabledSet(_enabled);
    }

    /// Enable DAO governance (one-way): after enabling, governance/referral features take effect and the activation time is recorded for referral settlement checks
    function enableGovernance() external onlyOwner {
        require(!governanceEnabled, "Already enabled");
        governanceEnabled = true;
        governanceActivatedAt = block.timestamp;
        emit GovernanceEnabled(block.timestamp);
    }

    /* ============ Announcements ============ */
    /// Multisig grants/revokes announcement publishing rights for a wallet address (the owner can also set it directly)
    function setAnnouncementPublisher(address addr, bool allowed) external onlySelfOrOwner {
        require(addr != address(0), "Zero address");
        announcementPublishers[addr] = allowed;
        emit AnnouncementPublisherSet(addr, allowed);
    }

    /// An authorized publisher publishes an announcement (written on-chain, displayed by the frontend)
    function publishAnnouncement(string calldata title, string calldata content) external {
        require(announcementPublishers[msg.sender], "Not publisher");
        require(bytes(title).length > 0 && bytes(content).length > 0, "Empty input");
        announcements.push(Announcement(title, content, block.timestamp));
        emit AnnouncementPublished(announcements.length - 1, msg.sender, title, content, block.timestamp);
    }

    function getAnnouncementCount() external view returns (uint256) { return announcements.length; }

    /* ============ Receiving funds ============ */
    /// Fallback for receiving funds (plain BNB transfers, multisig transfers back, etc.)
    receive() external payable {}
}
