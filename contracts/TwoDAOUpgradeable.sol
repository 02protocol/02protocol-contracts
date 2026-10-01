// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

interface IRDStake {
    function userStakeCount(address user) external view returns (uint256);
    function userStakes(address user, uint256 i) external view returns (
        uint256 amount, uint256 weight, uint256 startTime, uint256 endTime,
        uint256 rewardDebt, bool isActive, bool isWithdrawn, bool isExpiredDeducted
    );
    function totalStaked() external view returns (uint256);
}

interface ILPRStake {
    function userLpStakeCount(address user) external view returns (uint256);
    function userLpStakes(address user, uint256 i) external view returns (
        uint256 amount, uint256 weight, uint256 startTime, uint256 endTime,
        uint256 rewardDebt, bool isActive, bool isWithdrawn, bool isExpiredDeducted
    );
    function totalLpStaked() external view returns (uint256);
}

interface IUniswapV2Pair {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function totalSupply() external view returns (uint256);
    function token0() external view returns (address);
}

interface IProtocolV2 {
    function TAX_RATE() external view returns (uint256);
}

/// The lending contract's vault leg. TwoLend caps its dividend split at 100% minus THAT value, and the
/// vault leg is not a proposal parameter — so a proposal has to be checked against the live leg here.
/// Without this it is created, passes, and then reverts inside _applyChanges on "Lend apply failed":
/// unexecutable, and its proposer cannot propose again until the Foundation rejects it.
interface ILendVaultLeg {
    function vaultShareBps() external view returns (uint256);
}

/// V11: mint parameters (for DAO proposal pre-check; on execution the protocol-side
/// setMintParams re-validates once more)
interface IMintParamsSource {
    /// Protocol-side **full** validation (reverts if invalid, returns the theoretical
    /// issuance S if valid). Same source as setMintParams:
    /// already covers the 21,000,000 "worst case" hard cap, cap ≤ 500 BNB, and that once
    /// minting has started both parameters **can only be lowered**.
    /// The price is not part of this — it is a constant curve inside the protocol and is
    /// never passed in via a proposal.
    function validateMintParams(uint256 cap, uint256 perAddressCap)
        external view returns (uint256);
}

/// @title TwoDAOUpgradeable
/// @notice 02Protocol staker DAO: proposal (dividend split change) -> vote (90-day stakers) -> execute.
///   - Governance scope: only the dividend split can be changed — the dividend destination
///     of V2 fees / TwoSwap protocol fee / lending interest (LP staking dividend pool vs
///     single-token staking dividend pool). The backing vault split is immutable.
///   - V11 mint parameters (mint cap / starting price / cap price / per-address cap):
///     **Foundation-only, not subject to voting** — minting happens before staking, so
///     staking voting power cannot exist yet; hence the Foundation decides and picks the
///     notice period (0 = effective immediately).
///   - Proposal creation: user (requires 90-day staking eligibility) or Foundation (multisig approval).
///   - Proposal window: chosen by the proposer from 0 ~ MAX_NOTICE_PERIOD (30 days), 0 = immediate; shorter is faster, longer is more transparent.
///   - Voting eligibility: a single-token/LP stake that has a 90-day lock (or has already been staked for 90 days).
///   - Voting power: single-token staking 1 02 = 1 vote; LP staking counts the contained 02 amount × 2.
///   - Execution: Foundation proposals are **not voted on**; anyone can execute once the
///     window expires. For user proposals the window is the voting period; on expiry it must
///     pass the threshold and must be executed by the Foundation multisig; the Foundation
///     may reject a user proposal at any time.
contract TwoDAOUpgradeable is
    Initializable,
    Ownable2StepUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    uint256 public constant VOTING_PERIOD_DEFAULT = 3 days;
    uint256 public constant MIN_90_DAYS = 90 days;
    /// A user proposal must give voters at least this long. Without a floor the proposer picks the window,
    /// and with quorum disabled a single voter can pass a proposal inside one block — which makes
    /// "passed" meaningless. The Foundation keeps its short notice period for operational changes.
    uint256 public constant MIN_USER_WINDOW = 1 days;
    /// Upper bound on the notice period of a mint-parameter proposal (Foundation picks 0 = effective immediately, at most 30 days)
    uint256 public constant MAX_NOTICE_PERIOD = 30 days;

    /* ============ Related contracts ============ */
    address public foundation;       // TwoFoundation (multisig Foundation)
    address public rewardDistributor; // single-token staking
    address public lpReward;          // LP staking
    address public twoProtocol;       // 02 main protocol (V2 tax)
    address public twoSwap;           // TwoSwap (protocol fee)
    address public twoLend;           // TwoLend (lending interest)
    address public twoToken;          // 02
    address public pair;              // 02-BNB pair (LP conversion)

    /* ============ Governance parameters ============ */
    uint256 public votingPeriod;      // 3 days: only the default window value for the frontend form (the actual window is chosen by the proposer)
    uint256 public quorumBps;         // quorum (default 0 = disabled)
    uint256 public proposalCount;

    /* ============ Current dividend split (the "governable state" managed by the DAO) ============ */
    uint256 public v2LpShareBps;      // LP share of V2 tax dividends (vault/burn fixed; default 6667)
    uint256 public swapDividendBps;   // share of TwoSwap protocol fee going to the dividend pool (default 0)
    uint256 public swapLpShareBps;    // LP share of swap dividends (default 6667)
    uint256 public lendDividendBps;   // share of lending interest going to the dividend pool (default 0)
    uint256 public lendLpShareBps;    // LP share of lending dividends (default 6667)

    /* ============ Proposals ============ */
    struct Proposal {
        address proposer;
        bool    isFoundationProposal;
        uint256 v2VaultBps;      // vault share of V2 tax (bps of the trade amount, default 100 = 1%)
        uint256 v2BurnBps;       // burn share of V2 tax (bps of the trade amount, default 50 = 0.5%)
        uint256 v2LpShareBps;
        uint256 swapDividendBps;
        uint256 swapLpShareBps;
        uint256 lendDividendBps;
        uint256 lendLpShareBps;
        string  description;
        uint256 createTime;
        uint256 voteEnd;
        uint256 forVotes;
        uint256 againstVotes;
        uint256 voterCount;   // number of voters who have voted
        bool    executed;
        bool    rejected;
        // LP→02 conversion snapshot (frozen when the proposal is created; both voting and
        // settlement use the snapshot to prevent real-time reserve manipulation)
        uint256 lpReserveTwo;  // 02 reserve in the pair (snapshot)
        uint256 lpTotalSupply; // total LP supply of the pair (snapshot)
        bool    closed;        // closed by anyone when voting ends without passing; frees the proposer and prevents "revival"
        // V10 (append-only, appended at the end): swap protocol fee switch (true = charge the protocol fee)
        bool    v10SwapFeeOn;
        // V11 (append-only, appended at the end): mint-parameter proposal (a separate type,
        // independent of dividend-split proposals).
        // A mint-parameter proposal = Foundation-only + not voted on (voteEnd means the
        // "earliest executable time" = creation + notice period).
        // ⚠️ Appended fields change the Proposal element size → the upgrade must happen
        //    while the proposals array is empty
        //    (currently getProposalCount() is 0 on both mainnet/testnet).
        bool    isMintProposal;
        uint256 mintBnbCap;         // mint cap BNB upper bound C (can only be lowered once minting starts)
        uint256 mintPerAddressCap;  // per-address cumulative cap (can only be lowered once minting starts)
    }
    Proposal[] public proposals;
    mapping(address => bool) public hasActiveProposal; // an address can have at most 1 active proposal at a time

    mapping(uint256 => mapping(address => bool)) public hasVoted;

    // Pass threshold (append-only, appended at the end): forVotes > total votes cast × passBps / 10000 (default 5100 = 51%)
    uint256 public passBps;

    // V9 (append-only, appended at the end): current vault / burn share (bps of the trade amount, default 100/50)
    uint256 public v2VaultBps;
    uint256 public v2BurnBps;

    // V10 (append-only, appended at the end): current swap fee switch state (true = charge the protocol fee)
    bool public swapFeeOn;

    event ProposalCreated(uint256 indexed id, address indexed proposer, bool isFoundation, string description);
    event VoteCast(uint256 indexed id, address indexed voter, bool support, uint256 power);
    event ProposalRejected(uint256 indexed id, address indexed by);
    event ProposalClosed(uint256 indexed id, address indexed by);
    event ProposalExecuted(uint256 indexed id, address indexed executor);
    event V2SplitSet(uint256 lpBps);
    event SwapSplitSet(uint256 dividendBps, uint256 lpBps);
    event LendSplitSet(uint256 dividendBps, uint256 lpBps);
    event VotingPeriodSet(uint256 period);
    event QuorumSet(uint256 bps);
    event PassBpsSet(uint256 bps);
    event VaultBurnSplitSet(uint256 vaultBps, uint256 burnBps);
    event SwapFeeOnSet(bool on);
    // V11: broadcast the effective values after a mint-parameter proposal is executed
    event MintParamsSet(uint256 mintBnbCap, uint256 perAddressCap);
    event AccountFrozen(address indexed account, bool flag);

    modifier onlyFoundation() {
        require(msg.sender == foundation, "Only foundation");
        _;
    }

    /// V12 emergency freeze / unfreeze: triggered **directly** by the Foundation multisig
    /// (no notice period, does not enter the proposal queue), used solely for emergency
    /// stop-loss when "a wallet is compromised and dumping". Forwards to the protocol-side
    /// setFrozen.
    /// ⚠️ Freeze only, no asset unlock: the protocol side has no entry point to seize or
    /// transfer frozen assets.
    /// ⚠️ A frozen address cannot receive tokens, so do not mistakenly freeze an address
    /// that still needs to receive funds (e.g. the distributor contract, the vault).
    function setFrozen(address _account, bool _flag) external onlyFoundation {
        require(twoProtocol != address(0), "No protocol");
        require(_account != address(0), "Zero address");
        (bool ok, ) = twoProtocol.call(abi.encodeWithSignature("setFrozen(address,bool)", _account, _flag));
        require(ok, "Freeze failed");
        emit AccountFrozen(_account, _flag);
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _foundation,
        address _rewardDistributor,
        address _lpReward,
        address _twoProtocol,
        address _twoSwap,
        address _twoLend,
        address _twoToken,
        address _pair
    ) external initializer {
        __Ownable2Step_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        foundation = _foundation;
        rewardDistributor = _rewardDistributor;
        lpReward = _lpReward;
        twoProtocol = _twoProtocol;
        twoSwap = _twoSwap;
        twoLend = _twoLend;
        twoToken = _twoToken;
        pair = _pair;
        votingPeriod = VOTING_PERIOD_DEFAULT;
        passBps = 5100; // forVotes > 51% of total votes cast
        v2VaultBps = 100; // vault 1% of V2 tax
        v2BurnBps = 50;   // burn 0.5% of V2 tax
        // default split: LP : single-token = 2 : 1
        v2LpShareBps = 6667;
        swapLpShareBps = 6667;
        lendLpShareBps = 6667;
    }

    function _authorizeUpgrade(address /*newImplementation*/) internal override onlyOwner {}

    /* ============ Owner configuration ============ */
    function setFoundation(address _f) external onlyOwner { foundation = _f; }
    function setVotingPeriod(uint256 _period) external onlyOwner {
        require(_period >= 1 days && _period <= 30 days, "Bad period");
        votingPeriod = _period;
        emit VotingPeriodSet(_period);
    }
    function setQuorumBps(uint256 _bps) external onlyOwner {
        require(_bps <= 10000, "Bad bps");
        quorumBps = _bps;
        emit QuorumSet(_bps);
    }
    function setPassBps(uint256 _bps) external onlyOwner {
        require(_bps > 5000 && _bps <= 10000, "Bad bps"); // must be strictly greater than 50%
        passBps = _bps;
        emit PassBpsSet(_bps);
    }
    function setContracts(address _twoProtocol, address _twoSwap, address _twoLend) external onlyOwner {
        require(_twoProtocol != address(0) && _twoSwap != address(0) && _twoLend != address(0), "Zero address");
        twoProtocol = _twoProtocol;
        twoSwap = _twoSwap;
        twoLend = _twoLend;
    }

    /* ============ Voting power ============ */
    /// 90-day staking eligibility: any active stake (single-token/LP) with a lock of >= 90 days, or already staked for 90 days
    function _isEligibleStake(uint256 startTime, uint256 endTime, uint256 snapshotTime) internal pure returns (bool) {
        // Strictly earlier than the snapshot: `>` let a stake that landed in the SAME block as the
        // proposal (same timestamp) count as pre-existing, so a stake could be bundled into the
        // proposal's block and still vote on it.
        if (startTime >= snapshotTime) return false; // stakes not already present at creation do not count
        if (endTime - startTime >= MIN_90_DAYS) return true; // 90-day lock tier
        return snapshotTime - startTime >= MIN_90_DAYS; // already staked for 90 days
    }

    /// 02 amount contained in the LP: lpAmount × reserve02 / totalLP (the reserves are passed in by the caller: proposal snapshot or real-time value)
    function _lpToTwo(uint256 lpAmount, uint256 reserveTwo, uint256 totalLp) internal pure returns (uint256) {
        if (lpAmount == 0 || totalLp == 0) return 0;
        return (lpAmount * reserveTwo) / totalLp;
    }

    /// Core voting-power calculation: single-token 1:1 + LP (contained 02 × 2); the conversion uses the passed-in reserve snapshot
    function _getVotingPower(
        address user,
        uint256 snapshotTime,
        uint256 lpReserveTwo,
        uint256 lpTotalSupply
    ) internal view returns (uint256 power) {
        if (rewardDistributor != address(0)) {
            uint256 n = IRDStake(rewardDistributor).userStakeCount(user);
            for (uint256 i = 0; i < n; i++) {
                (uint256 amount, , uint256 startTime, uint256 endTime, , bool isActive, , ) =
                    IRDStake(rewardDistributor).userStakes(user, i);
                if (isActive && _isEligibleStake(startTime, endTime, snapshotTime)) {
                    power += amount;
                }
            }
        }
        if (lpReward != address(0)) {
            uint256 m = ILPRStake(lpReward).userLpStakeCount(user);
            for (uint256 j = 0; j < m; j++) {
                (uint256 amount, , uint256 startTime, uint256 endTime, , bool isActive, , ) =
                    ILPRStake(lpReward).userLpStakes(user, j);
                if (isActive && _isEligibleStake(startTime, endTime, snapshotTime)) {
                    power += _lpToTwo(amount, lpReserveTwo, lpTotalSupply) * 2;
                }
            }
        }
    }

    /// Real-time voting power (proposal-creation eligibility / frontend display reference; official votes use the in-proposal snapshot)
    function getVotingPower(address user, uint256 snapshotTime) public view returns (uint256 power) {
        uint256 reserveTwo = 0;
        uint256 totalLp = 0;
        if (lpReward != address(0) && pair != address(0)) {
            (uint112 r0, uint112 r1, ) = IUniswapV2Pair(pair).getReserves();
            totalLp = IUniswapV2Pair(pair).totalSupply();
            address t0 = IUniswapV2Pair(pair).token0();
            reserveTwo = t0 == twoToken ? uint256(r0) : uint256(r1);
        }
        return _getVotingPower(user, snapshotTime, reserveTwo, totalLp);
    }

    function hasVotingRight(address user) external view returns (bool) {
        return getVotingPower(user, block.timestamp) > 0;
    }

    /* ============ Create proposal ============ */
    /// `_windowSeconds` = proposal window (chosen by the proposer, 0 = immediate; upper bound MAX_NOTICE_PERIOD):
    ///   - Foundation proposal: the window is the notice period; anyone can execute once it expires (no vote → emergency items can set 0 to take effect immediately)
    ///   - User proposal: the window is the voting period; on expiry it must pass the threshold + be executed by the Foundation
    function _createProposal(
        address proposer,
        bool isFoundation,
        uint256 _v2VaultBps,
        uint256 _v2BurnBps,
        uint256 _v2LpShareBps,
        uint256 _swapDividendBps,
        uint256 _swapLpShareBps,
        uint256 _lendDividendBps,
        uint256 _lendLpShareBps,
        bool _swapFeeOn,
        uint256 _windowSeconds,
        string calldata description
    ) internal {
        require(_v2LpShareBps <= 10000 && _swapDividendBps <= 10000 && _swapLpShareBps <= 10000
            && _lendDividendBps <= 10000 && _lendLpShareBps <= 10000, "Bad bps");
        if (twoProtocol != address(0)) {
            // vault > 0 and vault + burn < total tax (ensures the dividend portion is non-empty)
            uint256 tax = IProtocolV2(twoProtocol).TAX_RATE();
            require(_v2VaultBps > 0 && _v2VaultBps + _v2BurnBps < tax, "Bad vault/burn");
        }
        if (twoLend != address(0)) {
            // TwoLend's own constraint mirrored at creation time (see ILendVaultLeg).
            require(_lendDividendBps + ILendVaultLeg(twoLend).vaultShareBps() <= 10000, "Lend split over cap");
        }
        require(_windowSeconds <= MAX_NOTICE_PERIOD, "Bad window");
        if (!isFoundation) require(_windowSeconds >= MIN_USER_WINDOW, "Window too short");
        require(!hasActiveProposal[proposer], "One active");
        hasActiveProposal[proposer] = true;

        Proposal storage p = proposals.push();
        p.proposer = proposer;
        p.isFoundationProposal = isFoundation;
        p.v2VaultBps = _v2VaultBps;
        p.v2BurnBps = _v2BurnBps;
        p.v2LpShareBps = _v2LpShareBps;
        p.swapDividendBps = _swapDividendBps;
        p.swapLpShareBps = _swapLpShareBps;
        p.lendDividendBps = _lendDividendBps;
        p.lendLpShareBps = _lendLpShareBps;
        p.v10SwapFeeOn = _swapFeeOn;
        p.description = description;
        p.createTime = block.timestamp;
        p.voteEnd = block.timestamp + _windowSeconds; // window (0 = immediately executable)

        // LP→02 conversion snapshot: freeze the pair reserves at creation; voting/settlement use the snapshot to prevent real-time reserve manipulation
        _snapshotLp(p);

        uint256 id = proposalCount;
        proposalCount += 1;
        emit ProposalCreated(id, proposer, isFoundation, description);
    }

    /// Freeze the LP→02 conversion snapshot when the proposal is created (both voting and settlement use the snapshot to prevent real-time reserve manipulation)
    function _snapshotLp(Proposal storage p) internal {
        if (pair != address(0)) {
            (uint112 r0, uint112 r1, ) = IUniswapV2Pair(pair).getReserves();
            p.lpTotalSupply = IUniswapV2Pair(pair).totalSupply();
            address t0 = IUniswapV2Pair(pair).token0();
            p.lpReserveTwo = t0 == twoToken ? uint256(r0) : uint256(r1);
        }
    }

    /// Create a proposal as a user (requires 90-day staking eligibility; the Foundation may reject)
    /// `_windowSeconds` = voting window (self-chosen, upper bound MAX_NOTICE_PERIOD; must pass the threshold at window end to be executable)
    function proposeFromUser(
        uint256 _v2VaultBps,
        uint256 _v2BurnBps,
        uint256 _v2LpShareBps,
        uint256 _swapDividendBps,
        uint256 _swapLpShareBps,
        uint256 _lendDividendBps,
        uint256 _lendLpShareBps,
        bool _swapFeeOn,
        uint256 _windowSeconds,
        string calldata description
    ) external {
        require(getVotingPower(msg.sender, block.timestamp) > 0, "No voting power");
        _createProposal(msg.sender, false, _v2VaultBps, _v2BurnBps, _v2LpShareBps, _swapDividendBps,
            _swapLpShareBps, _lendDividendBps, _lendLpShareBps, _swapFeeOn, _windowSeconds, description);
    }

    /// Create a proposal as the Foundation (called only after Foundation multisig approval)
    /// `_windowSeconds` = notice period (self-chosen, 0 = effective immediately): Foundation proposals are not voted on and can be executed once the period expires
    function proposeFromFoundation(
        uint256 _v2VaultBps,
        uint256 _v2BurnBps,
        uint256 _v2LpShareBps,
        uint256 _swapDividendBps,
        uint256 _swapLpShareBps,
        uint256 _lendDividendBps,
        uint256 _lendLpShareBps,
        bool _swapFeeOn,
        uint256 _windowSeconds,
        string calldata description
    ) external onlyFoundation {
        _createProposal(msg.sender, true, _v2VaultBps, _v2BurnBps, _v2LpShareBps, _swapDividendBps,
            _swapLpShareBps, _lendDividendBps, _lendLpShareBps, _swapFeeOn, _windowSeconds, description);
    }

    /* ============ Mint-parameter proposals (Foundation-only, no vote) ============ */
    /// Mint parameters can only be decided by the Foundation: minting happens before staking,
    /// so staking voting power does not exist yet and is thus unsuitable for a vote.
    /// `noticeSeconds`: the Foundation chooses the notice period itself: 0 = effective
    /// immediately; otherwise anyone can execute once the notice period expires.
    /// Hard bounds are still enforced by the protocol: mint cap ≤ 500 BNB, theoretical
    /// issuance ≤ 21,000,000 tokens.
    function proposeMintParamsFromFoundation(
        uint256 _mintBnbCap,
        uint256 _mintPerAddressCap,
        uint256 _noticeSeconds,
        string calldata description
    ) external onlyFoundation {
        _createMintParamsProposal(msg.sender, _mintBnbCap, _mintPerAddressCap, _noticeSeconds, description);
    }

    /// Mint-parameter proposal: Foundation-only, no vote (voteEnd is the "earliest executable
    /// time" = creation time + notice period).
    /// Only two parameters: mint cap C and per-address cumulative cap. The bonding-curve price
    /// is a constant inside the protocol (a 10x curve) and is not passed in via the proposal —
    /// neither the customer nor the DAO can set the price.
    /// The creation-time pre-check **directly reuses the protocol-side validateMintParams**
    /// (the same entry point, so the conditions can never drift from setMintParams):
    /// it covers the 21,000,000 "worst case" hard cap, cap ≤ 500 BNB, and that once minting
    /// has started both parameters can only be lowered.
    function _createMintParamsProposal(
        address proposer,
        uint256 _cap,
        uint256 _perAddressCap,
        uint256 _noticeSeconds,
        string calldata description
    ) internal {
        require(twoProtocol != address(0), "No protocol");
        IMintParamsSource(twoProtocol).validateMintParams(_cap, _perAddressCap);
        require(_noticeSeconds <= MAX_NOTICE_PERIOD, "Bad window");

        require(!hasActiveProposal[proposer], "One active");
        hasActiveProposal[proposer] = true;

        Proposal storage p = proposals.push();
        p.proposer = proposer;
        p.isFoundationProposal = true;
        p.isMintProposal = true;
        p.mintBnbCap = _cap;
        p.mintPerAddressCap = _perAddressCap;
        p.description = description;
        p.createTime = block.timestamp;
        p.voteEnd = block.timestamp + _noticeSeconds; // notice period (0 = immediately executable)
        _snapshotLp(p);

        uint256 id = proposalCount;
        proposalCount += 1;
        emit ProposalCreated(id, proposer, true, description);
    }

    /* ============ Voting ============ */
    function castVote(uint256 id, bool support) external {
        require(id < proposals.length, "Bad id");
        Proposal storage p = proposals[id];
        require(!p.isFoundationProposal, "Foundation proposal: no vote"); // Foundation proposals are not voted on
        require(block.timestamp < p.voteEnd, "Voting ended");
        require(!p.executed && !p.rejected && !p.closed, "Closed");
        require(!hasVoted[id][msg.sender], "Already voted");

        // voting power is based on the snapshot at proposal creation (including the LP conversion reserve snapshot)
        uint256 power = _getVotingPower(msg.sender, p.createTime, p.lpReserveTwo, p.lpTotalSupply);
        require(power > 0, "No voting power");

        hasVoted[id][msg.sender] = true;
        p.voterCount += 1;
        if (support) {
            p.forVotes += power;
        } else {
            p.againstVotes += power;
        }
        emit VoteCast(id, msg.sender, support, power);
    }

    function getProposalCount() external view returns (uint256) { return proposals.length; }

    /* ============ Pass determination ============ */
    function _isPassed(uint256 id) internal view returns (bool) {
        Proposal storage p = proposals[id];
        if (block.timestamp < p.voteEnd) return false;
        // Pass threshold: forVotes > passBps/10000 of total votes cast (for+against) (default 51%)
        uint256 totalVotes = p.forVotes + p.againstVotes;
        if (totalVotes == 0 || p.forVotes * 10000 <= totalVotes * passBps) return false;
        if (quorumBps > 0) {
            // The base is unified to a 02-equivalent measure (consistent with voting power): single-token staked 02 + LP staked converted per snapshot to contained 02 ×2
            uint256 base = rewardDistributor != address(0) ? IRDStake(rewardDistributor).totalStaked() : 0;
            if (lpReward != address(0)) {
                base += _lpToTwo(ILPRStake(lpReward).totalLpStaked(), p.lpReserveTwo, p.lpTotalSupply) * 2;
            }
            if (base == 0 || (p.forVotes + p.againstVotes) * 10000 < base * quorumBps) return false;
        }
        return true;
    }

    /* ============ Close a failed proposal ============ */
    /// When a user proposal's voting ends without passing, anyone can close it: frees the
    /// proposer and prevents "revival" after parameters change
    /// Foundation proposals are not voted on (and cannot be closed by a third party) → only
    /// the Foundation can abandon them voluntarily
    function closeProposal(uint256 id) external {
        require(id < proposals.length, "Bad id");
        Proposal storage p = proposals[id];
        if (p.isFoundationProposal) require(msg.sender == foundation, "Only foundation");
        require(block.timestamp >= p.voteEnd, "Not ended");
        require(!p.executed && !p.rejected && !p.closed, "Closed");
        require(!_isPassed(id), "Passed");
        p.closed = true;
        hasActiveProposal[p.proposer] = false;
        emit ProposalClosed(id, msg.sender);
    }

    /* ============ Execution ============ */
    /// Foundation rejects a user proposal
    function rejectProposal(uint256 id) external onlyFoundation nonReentrant {
        require(id < proposals.length, "Bad id");
        Proposal storage p = proposals[id];
        require(!p.executed, "Executed");
        p.rejected = true;
        hasActiveProposal[p.proposer] = false;
        emit ProposalRejected(id, msg.sender);
    }

    /// Execute (the window is chosen by the proposer, 0 = immediate):
    ///   - Foundation proposal (including mint parameters): no vote; anyone can execute once the window expires
    ///   - User proposal: the window is the voting period; on expiry it must pass the threshold and must be executed by the Foundation multisig
    function executeProposal(uint256 id) external nonReentrant {
        require(id < proposals.length, "Bad id");
        Proposal storage p = proposals[id];
        require(!p.executed && !p.rejected && !p.closed, "Closed");
        if (p.isFoundationProposal) {
            require(block.timestamp >= p.voteEnd, "Window not over"); // executable once the notice period/window expires
        } else {
            require(msg.sender == foundation, "Only foundation");
            require(_isPassed(id), "Not passed");
        }

        p.executed = true;
        hasActiveProposal[p.proposer] = false;
        _applyChanges(p);
        emit ProposalExecuted(id, msg.sender);
    }

    function _applyChanges(Proposal storage p) internal {
        // V11: mint-parameter proposal → only calls the protocol setMintParams (all other state such as dividend splits is left untouched)
        if (p.isMintProposal) {
            require(twoProtocol != address(0), "No protocol");
            (bool okMint, ) = twoProtocol.call(abi.encodeWithSignature(
                "setMintParams(uint256,uint256)",
                p.mintBnbCap, p.mintPerAddressCap));
            require(okMint, "Mint params failed");
            emit MintParamsSet(p.mintBnbCap, p.mintPerAddressCap);
            return;
        }
        if (twoProtocol != address(0)) {
            (bool ok1, ) = twoProtocol.call(abi.encodeWithSignature("setVaultBurnSplit(uint256,uint256)", p.v2VaultBps, p.v2BurnBps));
            require(ok1, "Protocol vault/burn failed");
            (bool ok2, ) = twoProtocol.call(abi.encodeWithSignature("setV2DividendSplit(uint256)", p.v2LpShareBps));
            require(ok2, "Protocol apply failed");
        }
        if (twoSwap != address(0)) {
            // apply the fee switch first, then the dividend split (the split is only meaningful when the fee is enabled)
            (bool okFee, ) = twoSwap.call(abi.encodeWithSignature("setFeeEnabled(bool)", p.v10SwapFeeOn));
            require(okFee, "Swap fee switch failed");
            (bool ok, ) = twoSwap.call(abi.encodeWithSignature(
                "setDividendSplit(uint256,uint256)", p.swapDividendBps, p.swapLpShareBps));
            require(ok, "Swap apply failed");
        }
        if (twoLend != address(0)) {
            (bool ok, ) = twoLend.call(abi.encodeWithSignature(
                "setDividendSplit(uint256,uint256)", p.lendDividendBps, p.lendLpShareBps));
            require(ok, "Lend apply failed");
        }
        v2VaultBps = p.v2VaultBps;
        v2BurnBps = p.v2BurnBps;
        v2LpShareBps = p.v2LpShareBps;
        swapDividendBps = p.swapDividendBps;
        swapLpShareBps = p.swapLpShareBps;
        lendDividendBps = p.lendDividendBps;
        lendLpShareBps = p.lendLpShareBps;
        swapFeeOn = p.v10SwapFeeOn;
        emit VaultBurnSplitSet(p.v2VaultBps, p.v2BurnBps);
        emit V2SplitSet(p.v2LpShareBps);
        emit SwapSplitSet(p.swapDividendBps, p.swapLpShareBps);
        emit LendSplitSet(p.lendDividendBps, p.lendLpShareBps);
        emit SwapFeeOnSet(p.v10SwapFeeOn);
    }
}
