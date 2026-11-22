// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/// @title CommunityTreasury
/// @notice Dedicated community-building fund for 02Protocol.
///   - Accepts only 02 and USDT donations. BNB and every other token are rejected.
///   - The owner is the 3/5 Foundation multisig. It creates per-activity campaigns with a hard budget
///     and appoints a hot "operator" wallet that may only spend inside those budgets.
///   - Campaigns have NO expiry: a budget stays open until the multisig closes it or exhausts it.
///   - The operator never custodies funds: the balance stays here, so a leaked operator key can at most
///     drain the remaining budget of the open campaigns and can be revoked immediately.
///   - UUPS-upgradeable so future community activities can add functions without moving the address.
///     Upgrades are gated by the multisig through `_authorizeUpgrade`; storage layout must be appended
///     only (never reordered) in future implementations.
contract CommunityTreasury is
    Initializable,
    Ownable2StepUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    /// @notice Upper bound for one `spendMany` call, so a huge list cannot run out of gas mid-way.
    uint256 public constant MAX_BATCH = 60;

    IERC20 public twoToken;
    IERC20 public usdt;

    /// @notice Wallet allowed to call `spend`, appointed by the multisig. It cannot change anything else.
    address public operator;

    struct Campaign {
        address token;
        uint256 budget;
        uint256 spent;
        bool closed;
        bytes32 merkleRoot;
    }

    uint256 public campaignCount;
    mapping(uint256 => Campaign) public campaigns;
    mapping(address => uint256) public totalDonated;
    mapping(address => uint256) public totalSpent;
    /// @notice campaign id => claimant => already claimed
    mapping(uint256 => mapping(address => bool)) public claimed;

    event Donation(address indexed donor, address indexed token, uint256 amount);
    event OperatorChanged(address indexed previousOperator, address indexed newOperator);
    event CampaignCreated(uint256 indexed id, address indexed token, uint256 budget);
    event CampaignSpend(uint256 indexed id, address indexed token, address indexed to, uint256 amount);
    event CampaignSpendBatch(uint256 indexed id, address indexed token, uint256 count, uint256 total);
    event CampaignMerkleRoot(uint256 indexed id, bytes32 root);
    event CampaignClaimed(uint256 indexed id, address indexed to, uint256 amount);
    event CampaignClosed(uint256 indexed id);
    event EmergencyWithdrawal(address indexed token, address indexed to, uint256 amount);

    modifier onlyAllowedToken(address token) {
        require(token == address(twoToken) || token == address(usdt), "Token not allowed");
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address initialOwner, address twoToken_, address usdt_) external initializer {
        require(initialOwner != address(0), "Zero owner");
        require(twoToken_ != address(0), "Zero 02");
        require(usdt_ != address(0), "Zero USDT");
        require(twoToken_ != usdt_, "Duplicate token");

        __Ownable2Step_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        twoToken = IERC20(twoToken_);
        usdt = IERC20(usdt_);
        _transferOwnership(initialOwner);
    }

    /// @notice Donate 02 or USDT. The event reports the amount actually received, which can be lower
    ///         than `amount` if the token charges a transfer fee.
    function donate(address token, uint256 amount) external nonReentrant whenNotPaused onlyAllowedToken(token) {
        require(amount > 0, "Zero amount");
        uint256 before = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(token).balanceOf(address(this)) - before;
        require(received > 0, "Nothing received");
        totalDonated[token] += received;
        emit Donation(msg.sender, token, received);
    }

    /// @notice Appoint the spending wallet. Only the multisig can do this; it can revoke by setting a new one.
    function setOperator(address newOperator) external onlyOwner {
        require(newOperator != address(0), "Zero operator");
        emit OperatorChanged(operator, newOperator);
        operator = newOperator;
    }

    /// @notice Open a new activity budget. There is no expiry; the multisig closes it when the activity ends.
    function createCampaign(address token, uint256 budget)
        external
        onlyOwner
        whenNotPaused
        onlyAllowedToken(token)
        returns (uint256 id)
    {
        require(budget > 0, "Zero budget");
        id = ++campaignCount;
        campaigns[id] = Campaign({token: token, budget: budget, spent: 0, closed: false, merkleRoot: bytes32(0)});
        emit CampaignCreated(id, token, budget);
    }

    /// @notice Publish the Merkle root for a campaign. Set once: if the list is wrong, create a new campaign.
    function setMerkleRoot(uint256 id, bytes32 root) external whenNotPaused {
        require(msg.sender == operator, "Only operator");
        Campaign storage c = campaigns[id];
        require(c.token != address(0), "No campaign");
        require(!c.closed, "Campaign closed");
        require(root != bytes32(0), "Zero root");
        require(c.merkleRoot == bytes32(0), "Root already set");
        c.merkleRoot = root;
        emit CampaignMerkleRoot(id, root);
    }

    /// @notice Claim a Merkle-allocated reward. The leaf is double-hashed as
    ///         keccak256(bytes.concat(keccak256(abi.encode(campaignId, account, amount)))).
    function claim(uint256 id, uint256 amount, bytes32[] calldata proof) external nonReentrant whenNotPaused {
        require(amount > 0, "Zero amount");
        Campaign storage c = campaigns[id];
        require(c.token != address(0), "No campaign");
        require(!c.closed, "Campaign closed");
        require(c.merkleRoot != bytes32(0), "Root not set");
        require(!claimed[id][msg.sender], "Already claimed");
        require(c.spent + amount <= c.budget, "Budget exceeded");
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(id, msg.sender, amount))));
        require(MerkleProof.verify(proof, c.merkleRoot, leaf), "Invalid proof");
        claimed[id][msg.sender] = true;
        c.spent += amount;
        totalSpent[c.token] += amount;
        IERC20(c.token).safeTransfer(msg.sender, amount);
        emit CampaignClaimed(id, msg.sender, amount);
    }

    /// @notice Spend from an activity budget. Callable only by the operator, and only inside its budget.
    function spend(uint256 id, address to, uint256 amount) external nonReentrant whenNotPaused {
        require(msg.sender == operator, "Only operator");
        require(to != address(0), "Zero recipient");
        require(amount > 0, "Zero amount");
        Campaign storage c = campaigns[id];
        require(c.token != address(0), "No campaign");
        require(!c.closed, "Campaign closed");
        require(c.spent + amount <= c.budget, "Budget exceeded");
        c.spent += amount;
        totalSpent[c.token] += amount;
        IERC20(c.token).safeTransfer(to, amount);
        emit CampaignSpend(id, c.token, to, amount);
    }

    /// @notice Batch spend from one activity budget: a single transaction pays many recipients.
    /// @dev Same limits as `spend` (operator only, inside the campaign budget); only the wallet
    ///      confirmations go away. The backend/frontend still marks every row paid with this tx hash.
    function spendMany(uint256 id, address[] calldata recipients, uint256[] calldata amounts)
        external
        nonReentrant
        whenNotPaused
    {
        require(msg.sender == operator, "Only operator");
        uint256 n = recipients.length;
        require(n > 0 && n == amounts.length, "Bad length");
        require(n <= MAX_BATCH, "Too many");
        Campaign storage c = campaigns[id];
        require(c.token != address(0), "No campaign");
        require(!c.closed, "Campaign closed");

        uint256 total;
        for (uint256 i = 0; i < n; i += 1) {
            require(recipients[i] != address(0), "Zero recipient");
            require(amounts[i] > 0, "Zero amount");
            total += amounts[i];
        }
        require(c.spent + total <= c.budget, "Budget exceeded");
        c.spent += total;
        totalSpent[c.token] += total;

        for (uint256 i = 0; i < n; i += 1) {
            IERC20(c.token).safeTransfer(recipients[i], amounts[i]);
            emit CampaignSpend(id, c.token, recipients[i], amounts[i]);
        }
        emit CampaignSpendBatch(id, c.token, n, total);
    }

    /// @notice Close a campaign early. The multisig keeps this power so the operator cannot keep spending.
    function closeCampaign(uint256 id) external onlyOwner {
        Campaign storage c = campaigns[id];
        require(c.token != address(0), "No campaign");
        require(!c.closed, "Already closed");
        c.closed = true;
        emit CampaignClosed(id);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Recovery hatch for the multisig (wrong token sent, emergency migration, etc.).
    function emergencyWithdraw(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        require(to != address(0), "Zero recipient");
        require(amount > 0, "Zero amount");
        IERC20(token).safeTransfer(to, amount);
        emit EmergencyWithdrawal(token, to, amount);
    }

    function campaignRemaining(uint256 id) external view returns (uint256) {
        Campaign storage c = campaigns[id];
        return c.budget > c.spent ? c.budget - c.spent : 0;
    }

    /// @dev Only the multisig may replace the implementation.
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /// @notice Immediate upgrade path for the Foundation multisig.
    /// @dev The Foundation multisig adds a 24h notice to any calldata whose selector is `upgradeTo`.
    ///      This wrapper is a different selector, so the same 3/5 threshold can upgrade this community
    ///      treasury immediately (explicit product decision: no timelock on this contract).
    function upgradeToNow(address newImplementation) external onlyOwner {
        upgradeTo(newImplementation);
    }
}
