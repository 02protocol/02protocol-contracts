// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title TwoFoundationUpgradeable
/// @notice 02Protocol Foundation: multisig management + community donations + LP referral incentives.
///   - Multisig: 5 members by default, 3 required confirmations (required is adjustable). Members can join/leave (multisig approval).
///   - Donations: 02 donations go into the LP referral incentive pool; BNB / USDT donations go into the community-building fund.
///   - LP referral incentives: a user binds a referrer; when LPReward stakes LP, 02 rewards are accrued to the referrer proportionally,
///     and the referrer can claim from the incentive pool at any time.
///   - Community funds (BNB/USDT) and the incentive pool (02) can both be spent via multisig (generic multisig transactions).
contract TwoFoundationUpgradeable is
    Initializable,
    Ownable2StepUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    uint256 public constant MAX_REQUIRED = 9;

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
    uint256 public referralBps; // referral reward ratio (default 100 = 1% of staked LP)
    address public lpReward;    // LPReward contract (calls back onLpStake when LP is staked)

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
    event IncentiveClaimed(address indexed referrer, uint256 amount);
    event ReferralBpsSet(uint256 bps);
    event LpRewardSet(address lpReward);
    event DaoSet(address dao);
    event AnnouncementPublisherSet(address indexed addr, bool allowed);
    event AnnouncementPublished(uint256 indexed id, address indexed publisher, string title, string content, uint256 timestamp);
    event DonationsEnabledSet(bool enabled);
    event GovernanceEnabled(uint256 at);

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
        referralBps = 100; // 1%
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
        emit TransactionSubmitted(txId, msg.sender, _to, _value, _data, _category);
        emit TransactionConfirmed(txId, msg.sender);
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
        lpIncentivePool += received;
        emit ReferralPoolCredited(msg.sender, received, lpIncentivePool);
    }

    /// 02 donation -> LP referral incentive pool
    function donateTwo(uint256 amount) external nonReentrant {
        require(donationsEnabled, "Donations closed");
        require(amount > 0, "Zero amount");
        // Credit what actually ARRIVES, not what was asked for. During the mint phase 02 only moves
        // freely between whitelisted addresses; a donation from an ordinary holder would be BURNED on
        // the way here (the token's transfer hook burns it outright). Crediting `amount` regardless
        // would then record a donation the contract never received — the donor loses the tokens and
        // lpIncentivePool ends up claiming more than it holds.
        uint256 before = twoToken.balanceOf(address(this));
        twoToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = twoToken.balanceOf(address(this)) - before;
        require(received > 0, "Donation not received");
        lpIncentivePool += received;
        donators[msg.sender].twoAmount += received;
        donators[msg.sender].count += 1;
        donationRecords.push(DonationRecord(msg.sender, AssetType.TWO, received, block.timestamp));
        emit Donated(msg.sender, AssetType.TWO, received, block.timestamp);
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
        emit ReferrerSet(msg.sender, _referrer);
    }

    /// Callback after LPReward stakes LP: accrue 02 rewards to the referrer based on the staked amount (only effective after governance is enabled)
    function onLpStake(address user, uint256 lpAmount) external {
        require(msg.sender == lpReward, "Only lpReward");
        if (!governanceEnabled) return;
        address ref = referrers[user];
        if (ref == address(0) || lpAmount == 0 || referralBps == 0) return;
        uint256 reward = (lpAmount * referralBps) / 10000;
        if (reward == 0) return;
        referralRewards[ref] += reward;
        emit ReferralRewardAccrued(ref, user, lpAmount, reward);
    }

    /// Settle referral rewards when a stake is withdrawn at maturity (only callable by lpReward):
    /// rewards are accrued to the referrer only if governance is enabled AND the stake started after governance was activated (closes the "stake-withdraw farming loop")
    function settleReferral(address user, uint256 lpAmount, uint256 stakeStartTime) external {
        require(msg.sender == lpReward, "Only lpReward");
        if (!governanceEnabled || lpAmount == 0 || referralBps == 0) return;
        if (stakeStartTime < governanceActivatedAt) return; // staked before governance activation: no referral reward
        address ref = referrers[user];
        if (ref == address(0)) return;
        uint256 reward = (lpAmount * referralBps) / 10000;
        if (reward == 0) return;
        referralRewards[ref] += reward;
        emit ReferralRewardAccrued(ref, user, lpAmount, reward);
    }

    /// Referrer claims 02 rewards (from the incentive pool)
    function claimIncentive() external nonReentrant {
        uint256 pending = referralRewards[msg.sender];
        require(pending > 0, "Nothing to claim");
        // Pay only out of the DONATION-funded pool, never out of the whole 02 balance: 02 can arrive
        // here for other purposes (a plain transfer, or TwoSwap's input-token fee when path[0] is 02),
        // and those inflows would otherwise be claimable by whichever referrer asks first.
        // `lpIncentivePool` is credited only by donateTwo, so it is the real budget for this payout.
        uint256 poolBal = twoToken.balanceOf(address(this));
        uint256 budget = lpIncentivePool < poolBal ? lpIncentivePool : poolBal;
        uint256 payout = pending > budget ? budget : pending;
        require(payout > 0, "Pool empty");
        referralRewards[msg.sender] -= payout;
        lpIncentivePool -= payout;
        // Verify the payout actually arrived, exactly like donateTwo does on the way in. During the mint
        // phase TwoProtocol burns any 02 transfer whose sender AND recipient are both off the whitelist —
        // and this contract is NOT whitelisted by default. Without this check the burn would still return
        // success, so the accounting above would be consumed while the referrer received nothing and the
        // pool's 02 was destroyed. Reverting keeps the entitlement intact and makes the misconfiguration
        // visible instead of silently eating the reward.
        uint256 balBefore = twoToken.balanceOf(msg.sender);
        twoToken.safeTransfer(msg.sender, payout);
        require(twoToken.balanceOf(msg.sender) - balBefore == payout, "Incentive not delivered");
        emit IncentiveClaimed(msg.sender, payout);
    }

    function setReferralBps(uint256 _bps) external onlySelfOrOwner {
        require(_bps <= 5000, "Over cap"); // cap 50%
        referralBps = _bps;
        emit ReferralBpsSet(_bps);
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
