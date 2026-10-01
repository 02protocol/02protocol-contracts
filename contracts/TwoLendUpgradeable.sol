// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

interface ITwoProtocol {
    function getCurrentPrice() external view returns (uint256);
    function vaultBNB() external view returns (uint256);
    function withdrawForLend(uint256) external;
    function addLendingRepayment(uint256, uint256) external payable;
    function addLendingVaultShare() external payable;
    function routerAddress() external view returns (address);
    function wbnbAddress() external view returns (address);
    function pairAddress() external view returns (address);
}
interface IRouter {
    function swapExactTokensForETHSupportingFeeOnTransferTokens(uint,uint,address[] calldata,address,uint) external;
}

/// @title TwoLendUpgradeable
/// @notice UUPS-upgradeable variant of TwoLend, deployed behind an ERC1967 proxy so the address
///         stays fixed while the implementation can be upgraded locally. Business logic is
///         identical to TwoLend — only the skeleton changed (constructor -> initialize,
///         Ownable2Step/ReentrancyGuard -> their *Upgradeable twins, plus UUPSUpgradeable).
///         NOTE: the former `uint256 public borrowDuration = 7 days;` state initializer is
///         meaningless under a proxy (storage starts zeroed), so it is set in initialize().
contract TwoLendUpgradeable is
    Initializable,
    Ownable2StepUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    /* ============ Constants ============ */
    uint256 public constant MAX_BORROW_RATIO      = 2000;  // 20% of the vault capacity
    uint256 public constant INTEREST_RATE_DAILY   = 150;   // daily rate 1.5% (bps /10000) — only for short-term borrowers
    uint256 public constant MIN_BORROW_TIME       = 1 days; // earliest repayment time: repay allowed after 24h (interest has no grace period, accrues from the borrow moment)
    uint256 public constant KEEPER_BPS            = 100;   // surplus liquidation BNB -> keeper 1% gas compensation (not a user penalty)
    uint256 private constant ONE_ETHER            = 1e18;
    uint256 private constant BPS                  = 10_000;

    /* ============ Config (owner can enable/adjust in phases) ============ */
    address public twoProtocolAddress;
    address public rewardDistributorAddress;
    address public lpRewardAddress;               // lending interest 50% -> LP staking pool
    address public twoTokenAddress;
    address public router;
    address public wbnb;
    bool    public lendingEnabled;                // default false: closed during mint, opened manually by owner after V2
    uint256 public borrowDuration;                // fixed borrow period (default 7 days): overdue -> liquidation

    /* ============ Loan state ============ */
    struct Loan {
        uint256 collateralAmount;   // collateral TWO amount
        uint256 borrowAmount;       // borrowed BNB principal
        uint256 startTime;          // borrow start time
        uint256 deadline;           // maturity (startTime + borrowDuration)
        bool    isActive;
        bool    isLiquidated;
    }
    mapping(address => Loan) public userLoan;
    uint256 public totalBorrowed;         // currently outstanding BNB (used for the 20% basis)
    uint256 public pendingInterestTwo;    // accumulated interest TWO not yet swapped to BNB

    // After expired liquidation: the user's unclaimed remaining TWO (collateral - sold to cover principal + interest)
    mapping(address => uint256) public pendingCollateral;

    // DAO governance (appended — storage MUST stay append-only across upgrades):
    // Lending interest is split three ways: vaultShareBps to the backing vault, lendDividendBps to the
    // staking dividend pools (split further by lpShareBps), and the remainder to the buyback sink,
    // which buys 02 on V2 and burns it in burn mode.
    uint256 public lendDividendBps;   // interest -> staking dividend pools
    uint256 public lpShareBps;        // LP share within the dividend pool (6667 = LP 2 : single-token 1)
    address public dao;               // TwoDAO (onlyDAO setters)
    uint256 public vaultShareBps;     // interest -> backing vault (appended in V2; initLendV2 sets 10000)

    // Collateral the contract actually OWES to users: active loans plus unclaimed post-liquidation
    // remainders. Appended (V3) purely so setTwoToken can tell "collateral is outstanding" apart from
    // "someone dusted this contract with 1 wei of the token". A raw balanceOf() test can be tripped by
    // anyone for 1 wei, and since emergencyWithdrawTokens refuses to move the collateral token the owner
    // could never clear it — setTwoToken would be permanently bricked.
    uint256 public collateralLockedTwo;

    /* ============ Events ============ */
    event Borrowed(address indexed user, uint256 collateralTwo, uint256 borrowBNB, uint256 deadline, uint256 price);
    event Repaid(address indexed user, uint256 principalBNB, uint256 interestTwo, uint256 returnedTwo);
    event InterestDistributed(uint256 total, uint256 toVault, uint256 toStake, uint256 toBuyback);
    event ExpiredLiquidated(
        address indexed user,
        address indexed keeper,
        uint256 collateralTotalTwo,
        uint256 soldTwo,              // TWO actually sold on V2 to cover principal + interest
        uint256 remainingTwoToUser,   // TWO left for the user to claim
        uint256 bnbReceived,
        uint256 principalToVault,
        uint256 interestPaid,
        uint256 keeperReward,
        uint256 toRewardPool
    );
    event CollateralClaimed(address indexed user, uint256 twoAmount);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// One-time initialization, called by the proxy right after deployment (delegatecall).
    function initialize(address _twoProtocol, address _twoToken, address _rewardDistributor) external initializer {
        __Ownable2Step_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        twoProtocolAddress       = _twoProtocol;
        twoTokenAddress          = _twoToken;
        rewardDistributorAddress = _rewardDistributor;
        borrowDuration           = 7 days; // was a state initializer in the non-upgradeable version
        // router / wbnb are pulled when setTwoProtocol is called; owner can also override manually
    }

    /// Only the owner may upgrade the implementation (UUPS).
    function _authorizeUpgrade(address /*newImplementation*/) internal override onlyOwner {}

    /// V2 upgrade hook — run once through upgradeToAndCall. It does two things:
    ///
    ///  · turns the vault leg on at 100% of lending interest. That is the launch configuration: the vault
    ///    raises the backing price from the first block and needs no V2 depth, whereas the buyback has to
    ///    buy 02 at a market price above the backing price and cannot even execute while the anchor pool
    ///    holds ~1 token. The DAO can shift the split later through setVaultShareBps.
    ///  · writes lpShareBps = 6667, the value the previous implementation's comment claimed but that no
    ///    code ever set — the slot shipped as 0, so raising lendDividendBps alone would have sent LP
    ///    stakers nothing and the lendLpShareBps mirror in TwoDAO (already 6667) would have disagreed with
    ///    the contract.
    function initLendV2() external onlyOwner reinitializer(2) {
        vaultShareBps = 10000;
        lpShareBps = 6667;
    }

    // Accepts vault withdrawForLend / liquidation V2 swap BNB
    receive() external payable {}

    /* ============ Owner setters ============ */
    /// Only the zero address is rejected. Deliberately NO "no loans outstanding" gate: repay() and
    /// liquidateExpired() both route BNB through `_addr`, so a value that does not accept the call makes
    /// BOTH revert — and repointing again is then the only way out. A gate here would therefore turn one
    /// mistaken call into a permanent deadlock (the loan could never be cleared, so the gate could never
    /// open). Keeping the setter usable is what makes that mistake recoverable.
    function setTwoProtocol(address _addr) external onlyOwner {
        require(_addr != address(0), "Zero address");
        twoProtocolAddress = _addr;
        // Pull router / wbnb along the way
        (bool s1, bytes memory r1) = _addr.staticcall(abi.encodeWithSignature("routerAddress()"));
        (bool s2, bytes memory r2) = _addr.staticcall(abi.encodeWithSignature("wbnbAddress()"));
        if (s1 && r1.length == 32) router = abi.decode(r1, (address));
        if (s2 && r2.length == 32) wbnb   = abi.decode(r2, (address));
    }
    function setRewardDistributor(address _addr) external onlyOwner { rewardDistributorAddress = _addr; }
    function setLpReward(address _addr)         external onlyOwner { lpRewardAddress = _addr; }
    /// The collateral protection in emergencyWithdrawTokens works by comparing against this slot, so
    /// repointing it while collateral is actually held would silently unlock the collateral. Gated on the
    /// contract's own accounting (collateralLockedTwo), not on balanceOf(): the balance can be inflated by
    /// anyone with 1 wei, and emergencyWithdrawTokens refuses the collateral token, so a dust-based gate
    /// would brick this setter permanently.
    function setTwoToken(address _addr)          external onlyOwner {
        require(_addr != address(0), "Zero address");
        require(collateralLockedTwo == 0, "Collateral outstanding");
        twoTokenAddress = _addr;
    }
    /// Left ungated on purpose, and a zero router stays legal: liquidateExpired already degrades to
    /// "Liquidation: router unset" for that, and the borrower can always repay without a router, so a
    /// "no loans outstanding" gate would only remove the owner's ability to repair a bad router while
    /// loans are open (see setTwoProtocol above).
    function setRouter(address _router, address _wbnb) external onlyOwner { router = _router; wbnb = _wbnb; }

    // ===== Phase switch =====
    function setLendingEnabled(bool _flag) external onlyOwner { lendingEnabled = _flag; }
    /// A maturity shorter than the minimum repayment lock would let anyone liquidate a fresh loan in
    /// the next block while repay() is still rejected by MIN_BORROW_TIME — the borrower could not act.
    function setBorrowDuration(uint256 _duration) external onlyOwner {
        require(_duration >= MIN_BORROW_TIME, "Too short");
        require(_duration <= 365 days, "Too long");
        borrowDuration = _duration;
    }

    /* ============ Query helpers ============ */
    function getVaultBNB() internal view returns (uint256 v) {
        (bool s, bytes memory r) = twoProtocolAddress.staticcall(abi.encodeWithSignature("vaultBNB()"));
        v = s && r.length == 32 ? abi.decode(r, (uint256)) : 0;
    }
    function getCurrentPrice() internal view returns (uint256 p) {
        (bool s, bytes memory r) = twoProtocolAddress.staticcall(abi.encodeWithSignature("getCurrentPrice()"));
        p = s && r.length == 32 ? abi.decode(r, (uint256)) : 0;
        require(p > 0, "Price uninitialized");
    }
    function getMaxBorrow() public view returns (uint256) {
        // = (current backing vault + outstanding) * 20% (the "total assets" basis of the backing vault)
        return (getVaultBNB() + totalBorrowed) * MAX_BORROW_RATIO / BPS;
    }
    function getAvailableBorrow() public view returns (uint256) {
        uint256 m = getMaxBorrow();
        return m > totalBorrowed ? m - totalBorrowed : 0;
    }

    /// Interest calculation (BNB dimension: principal × 1.5% / day × seconds / 86400)
    /// Second-linear simple interest: accrues from the borrow moment by actual seconds (no 24h
    /// grace period — repay requires >=24h and liquidation requires >=deadline(7 days), so the
    /// entry points already guarantee this function is never triggered within 24h).
    /// After maturity, if still unliquidated, interest keeps accruing by actual days
    /// (fair for short-term borrowers, no cap).
    function calculateInterest(address user) public view returns (uint256 interestBNB) {
        Loan memory L = userLoan[user];
        if (!L.isActive) return 0;
        uint256 elapsed = block.timestamp - L.startTime;
        interestBNB = L.borrowAmount * INTEREST_RATE_DAILY * elapsed / (BPS * 1 days);
    }

    /* ============ Borrow & repay ============ */
    function borrow(uint256 collateralTwo, uint256 borrowBNB) external nonReentrant {
        require(lendingEnabled, "Lending closed");
        require(collateralTwo > 0 && borrowBNB > 0, "Zero input");
        Loan storage L = userLoan[msg.sender];
        require(!L.isActive, "Existing active loan");

        uint256 price = getCurrentPrice();
        uint256 valuation = (collateralTwo * price) / ONE_ETHER;
        // LTV ≤ 80% (1.25x collateral buffer at the backing price): the backing floor can only
        // rise, so even a liquidation at the floor with 85% slippage recovers principal + interest.
        require(valuation * 100 >= borrowBNB * 125, "Collateral insufficient");
        require(borrowBNB <= getAvailableBorrow(), "Borrow cap exceeded");

        // Transfer in the TWO and confirm the FULL amount arrived before booking it. During the mint
        // phase a 02 transfer between two non-whitelisted addresses is burned, so booking
        // `collateralTwo` blindly would record collateral the vault never received — the borrower
        // would walk away with the BNB and the loan could never be repaid or liquidated. Requiring an
        // exact arrival also keeps the LTV check above honest for any fee-on-transfer collateral token.
        IERC20 twoTok = IERC20(twoTokenAddress);
        uint256 collateralBefore = twoTok.balanceOf(address(this));
        twoTok.safeTransferFrom(msg.sender, address(this), collateralTwo);
        require(twoTok.balanceOf(address(this)) - collateralBefore == collateralTwo, "Collateral shortfall");

        L.collateralAmount = collateralTwo;
        collateralLockedTwo += collateralTwo;
        L.borrowAmount     = borrowBNB;
        L.startTime        = block.timestamp;
        L.deadline         = block.timestamp + borrowDuration;
        L.isActive         = true;
        totalBorrowed     += borrowBNB;

        // Withdraw BNB from the backing vault and send it to the user
        ITwoProtocol(twoProtocolAddress).withdrawForLend(borrowBNB);
        (bool s1, ) = payable(msg.sender).call{value: borrowBNB}("");
        require(s1, "BNB to user failed");

        // Best-effort swap of historical interest TWO before repay (reduces backlog)
        _trySwapInterestNoRevert();

        emit Borrowed(msg.sender, collateralTwo, borrowBNB, L.deadline, price);
    }

    function repay() external payable nonReentrant {
        Loan storage L = userLoan[msg.sender];
        require(L.isActive, "No active loan");
        uint256 elapsed = block.timestamp - L.startTime;
        require(elapsed >= MIN_BORROW_TIME, "Locked 24h");

        uint256 principal = L.borrowAmount;
        uint256 interestBNB = calculateInterest(msg.sender);
        // Repay principal + interest (BNB) in one go; the interest then splits three ways — vault / dividend / buyback
        uint256 totalDue = principal + interestBNB;
        require(msg.value >= totalDue, "Repay principal + interest BNB");
        if (msg.value > totalDue) {
            (bool s0, ) = payable(msg.sender).call{value: msg.value - totalDue}("");
            require(s0, "Refund failed");
        }

        uint256 collateral = L.collateralAmount;

        totalBorrowed     -= principal;
        L.collateralAmount = 0;
        collateralLockedTwo -= collateral;
        L.borrowAmount     = 0;
        L.isActive         = false;

        // 1) Principal -> vault
        ITwoProtocol(twoProtocolAddress).addLendingRepayment{value: principal}(principal, 0);

        // 2) Interest -> three-way split (vault / staking dividend pools / buyback sink)
        if (interestBNB > 0) {
            _distributeInterest(interestBNB);
        }

        // 3) Collateral 02 fully returned (interest is no longer deducted from the collateral)
        if (collateral > 0) {
            IERC20(twoTokenAddress).safeTransfer(msg.sender, collateral);
        }

        emit Repaid(msg.sender, principal, interestBNB, collateral);
    }

    /* ============ User manually claims the remaining TWO after expired liquidation ============ */
    function withdrawRemainingCollateral() external nonReentrant {
        uint256 amt = pendingCollateral[msg.sender];
        require(amt > 0, "Nothing to claim");
        pendingCollateral[msg.sender] = 0;
        collateralLockedTwo -= amt;
        IERC20(twoTokenAddress).safeTransfer(msg.sender, amt);
        emit CollateralClaimed(msg.sender, amt);
    }

    /* ============ Interest TWO V2 swap (50% vault + 50% staking) ============ */
    function swapPendingInterest() external nonReentrant { _doSwapInterest(); }

    function _trySwapInterestNoRevert() internal {
        // Call the internal function directly instead of this.swapPendingInterest()
        // (that one is nonReentrant; calling it inside the nonReentrant borrow/repay context
        // would always be blocked by the lock — Bug5 fix)
        _doSwapInterest();
    }

    function _doSwapInterest() internal {
        if (pendingInterestTwo == 0) return;
        if (router == address(0) || wbnb == address(0)) return;
        uint256 amount = pendingInterestTwo;

        uint256 price = getCurrentPrice();
        uint256 minOut = (amount * price * 90) / (ONE_ETHER * 100);
        address[] memory path = new address[](2);
        path[0] = twoTokenAddress;
        path[1] = wbnb;

        IERC20(twoTokenAddress).approve(router, amount);
        uint256 balBefore = address(this).balance;

        try IRouter(router).swapExactTokensForETHSupportingFeeOnTransferTokens(
            amount, minOut, path, address(this), block.timestamp
        ) {
            uint256 received = address(this).balance - balBefore;
            if (received > 0) {
                // Same three-way split as every other interest path; _distributeInterest reports it.
                _distributeInterest(received);

                pendingInterestTwo = 0;
                return;
            }
        } catch {
            // Failed: keep the amount, retry next time
        }
    }

    /// Uniformly credit BNB into the TwoProtocol backing vault
    /// (prefers addLendingVaultShare, degrades to a plain transfer on failure)
    function _sendToVault(uint256 amount) internal {
        if (amount == 0) return;
        (bool s, ) = twoProtocolAddress.call{value: amount}(
            abi.encodeWithSignature("addLendingVaultShare()")
        );
        if (!s) {
            (bool s2, ) = payable(twoProtocolAddress).call{value: amount}("");
            s2;
        }
    }

    /// Split one lump of BNB three ways: the backing vault, the staking dividend pools, and the buyback
    /// sink (which buys 02 on V2 and burns it in burn mode).
    ///
    /// Why the vault leg exists: routing BNB into the vault raises the backing price by growing the
    /// numerator, and it works from the first block — no V2 depth required. The buyback raises the same
    /// price by shrinking the denominator, but it has to buy 02 at the market price, which sits above the
    /// backing price, so a BNB spent that way removes less backing-value than a BNB added to the vault.
    /// The launch configuration therefore sends everything to the vault; the DAO can move the split
    /// towards the buyback once the pool is deep enough for it to execute at a reasonable price.
    ///
    /// Every leg degrades to the backing vault on failure, so no BNB is ever lost.
    function _distributeInterest(uint256 amount) internal {
        if (amount == 0) return;
        uint256 toVault   = (amount * vaultShareBps)   / 10000;
        uint256 toStake   = (amount * lendDividendBps) / 10000;
        // Both setters (setDividendSplit / setVaultShareBps) keep vaultShareBps + lendDividendBps <= 10000,
        // but initLendV2 writes vaultShareBps without re-checking lendDividendBps, so a mis-ordered
        // upgrade can push the sum past 10000. Clamp BOTH legs to what actually came in: otherwise the
        // legs would pay out more than the interest received (the buyback clamp alone does not stop that),
        // and an unclamped subtraction would instead revert every repay/liquidation and lock the ledger.
        if (toVault > amount) toVault = amount;
        if (toStake > amount - toVault) toStake = amount - toVault;
        uint256 toBuyback = amount - toVault - toStake;

        if (toVault > 0) _sendToVault(toVault);
        if (toStake > 0) _distributeDividend(toStake);
        if (toBuyback > 0) {
            (bool s, ) = twoProtocolAddress.call{value: toBuyback}(
                abi.encodeWithSignature("addBuyback()")
            );
            if (!s) _sendToVault(toBuyback);
        }
        emit InterestDistributed(amount, toVault, toStake, toBuyback);
    }

    /// Lending interest dividend -> LP staking pool / single-token staking pool
    /// (LP share governed by lpShareBps; failures degrade to the backing vault).
    function _distributeDividend(uint256 amount) internal {
        uint256 toLp = (amount * lpShareBps) / 10000;
        uint256 toSingle = amount - toLp;
        if (toLp > 0 && lpRewardAddress != address(0)) {
            (bool s, ) = payable(lpRewardAddress).call{value: toLp}("");
            if (!s) _sendToVault(toLp);
        } else if (toLp > 0) {
            _sendToVault(toLp);
        }
        if (toSingle > 0 && rewardDistributorAddress != address(0)) {
            (bool s, ) = payable(rewardDistributorAddress).call{value: toSingle}(
                abi.encodeWithSignature("addV2Reward()")
            );
            if (!s) _sendToVault(toSingle);
        } else if (toSingle > 0) {
            _sendToVault(toSingle);
        }
    }

    /* ============ DAO governance ============ */
    function setDao(address _dao) external onlyOwner {
        require(_dao != address(0), "Zero address");
        dao = _dao;
    }

    /// DAO adjusts the lending interest dividend split: dividendBps = share entering the dividend pools, lpShareBps = LP share within the dividend pool.
    /// The signature is deliberately unchanged: TwoDAO encodes this call by name, so a third parameter
    /// would make every dividend proposal fail at execution. The vault leg has its own setter below.
    function setDividendSplit(uint256 _dividendBps, uint256 _lpShareBps) external {
        require(msg.sender == dao, "Only dao");
        require(_dividendBps <= 10000 && _lpShareBps <= 10000, "Bad bps");
        require(_dividendBps + vaultShareBps <= 10000, "Split exceeds 100%");
        lendDividendBps = _dividendBps;
        lpShareBps = _lpShareBps;
    }

    /// The third leg: the share of lending interest that deepens the backing vault instead of being
    /// spent on the buyback. Raising it is the direct way to lift the backing price; the buyback only
    /// becomes the better leg once the V2 pool is deep enough to buy 02 near the backing price.
    /// Kept to dao || owner because TwoDAO does not carry this parameter yet — once it does, this
    /// same function is what a proposal will call.
    function setVaultShareBps(uint256 _vaultBps) external {
        require(msg.sender == dao || msg.sender == owner(), "Only dao or owner");
        require(_vaultBps + lendDividendBps <= 10000, "Split exceeds 100%");
        vaultShareBps = _vaultBps;
    }

    /* ============ Expired liquidation (deadline reached & not repaid) — anyone can trigger as keeper ============
       Rules (no penalty):
       - Compute the owed principal + interest = principal + interestBNB
       - Sell only the portion of TWO on V2 that "exactly covers principal + interest" (more in,
         less out)
       - The *unsold* collateral TWO: written into pendingCollateral[user], claimed by the user
         via withdrawRemainingCollateral
       - The BNB received from the sale: principal first -> interest 50/50 -> surplus 1% keeper
         + rest to the staking pool
    */
    function liquidateExpired(address user) external nonReentrant {
        Loan storage L = userLoan[user];
        require(L.isActive, "No active loan");
        require(block.timestamp >= L.deadline, "Not expired"); // must be expired

        uint256 principal    = L.borrowAmount;
        uint256 interestBNB  = calculateInterest(user);
        uint256 totalOwedBNB = principal + interestBNB;
        uint256 collateral   = L.collateralAmount;
        require(collateral > 0, "No collateral");

        // Minimum TWO to sell to cover principal + interest (at the backing price, rounded up
        // so slippage never leaves us short)
        uint256 price = getCurrentPrice();
        uint256 needTwo = (totalOwedBNB * ONE_ETHER + price - 1) / price; // ceil
        uint256 sellTwo = needTwo > collateral ? collateral : needTwo;

        uint256 received = 0;
        if (router != address(0) && wbnb != address(0) && sellTwo > 0) {
            // Slippage floor. When the collateral covers the whole debt, the sale must return at
            // least the principal, so a "successful" liquidation can never leave the vault short
            // (the old flat 85% floor of the backing price could return only ~94% of principal).
            // If the collateral cannot cover the debt, fall back to 85% of the backing price.
            uint256 minOut = sellTwo >= needTwo
                ? principal
                : (sellTwo * price * 85) / (ONE_ETHER * 100);
            address[] memory path = new address[](2);
            path[0] = twoTokenAddress;
            path[1] = wbnb;

            IERC20(twoTokenAddress).approve(router, sellTwo);
            uint256 balBefore = address(this).balance;
            try IRouter(router).swapExactTokensForETHSupportingFeeOnTransferTokens(
                sellTwo, minOut, path, address(this), block.timestamp
            ) {
                received = address(this).balance - balBefore;
            } catch {
                // The collateral could not be realized on V2 within the slippage floor. Do NOT fall
                // through to the ledger update: clearing the debt while handing the whole collateral
                // back would give the borrower a free loan at the vault's expense. Revert instead —
                // the loan stays active, the collateral keeps backing it, the borrower can still
                // repay() to release it, and liquidation can be retried once the pool has depth.
                revert("Liquidation: no depth");
            }
        } else {
            // No router configured: liquidation is impossible, so never release the collateral.
            revert("Liquidation: router unset");
        }

        // ===== Ledger update =====
        totalBorrowed     -= principal;
        L.collateralAmount = 0;
        collateralLockedTwo -= collateral;
        L.borrowAmount     = 0;
        L.isActive         = false;
        L.isLiquidated     = true;

        // The TWO sold by liquidation: not interest TWO (does not enter pendingInterestTwo),
        // directly split the BNB received from the V2 sale
        uint256 remainingTwo = collateral - sellTwo;
        if (remainingTwo > 0) {
            // User claims it later via withdrawRemainingCollateral()
            pendingCollateral[user] += remainingTwo;
            // Still owed: the collateral moves from the active-loan ledger into the claim ledger, so the
            // locked total is unchanged here (the part that left is the TWO actually sold).
            collateralLockedTwo += remainingTwo;
        }

        uint256 principalToVault;
        uint256 interestPaid;
        uint256 keeperReward;
        uint256 toRewardPool;

        if (received > 0) {
            // (1) Principal back to the vault first
            if (received >= principal) {
                principalToVault = principal;
                ITwoProtocol(twoProtocolAddress).addLendingRepayment{value: principalToVault}(principalToVault, 0);

                uint256 leftover = received - principal;
                if (leftover > 0) {
                    // (2) Cover interestBNB: the interest then splits three ways (vault / dividends / buyback)
                    if (leftover >= interestBNB) {
                        interestPaid = interestBNB;
                    } else {
                        interestPaid = leftover;
                    }
                    _distributeInterest(interestPaid);

                    // (3) Surplus (leftover - interestPaid): keeper 1% + rest split the same three ways
                    //     (all penalty-free; the surplus comes from a better V2 price)
                    uint256 surplus = leftover - interestPaid;
                    if (surplus > 0) {
                        keeperReward = (surplus * KEEPER_BPS) / BPS;
                        toRewardPool = surplus - keeperReward;
                        if (keeperReward > 0) {
                            (bool s, ) = payable(msg.sender).call{value: keeperReward}("");
                            s;
                        }
                        _distributeInterest(toRewardPool);
                    }
                }
            } else {
                // Not even the principal is covered by the sale (poor V2 depth): treat all
                // received as principal repayment (the backing vault absorbs the bad debt)
                principalToVault = received;
                ITwoProtocol(twoProtocolAddress).addLendingRepayment{value: principalToVault}(principalToVault, 0);
            }
        }
        // received == 0 branch: all TWO enters pendingCollateral[user] (claimed later by the user),
        // no BNB received — the principal/interest are treated as uncollectable

        emit ExpiredLiquidated(
            user, msg.sender,
            collateral,
            sellTwo,
            remainingTwo,
            received,
            principalToVault,
            interestPaid,
            keeperReward,
            toRewardPool
        );
    }

    /* ============ Owner emergency ============ */
    /// Owner rescue of tokens accidentally sent to the contract. The collateral token is excluded:
    /// the contract's 02 balance backs active loans and unclaimed liquidation remainder, so the
    /// owner must never be able to move it.
    function emergencyWithdrawTokens(address token, uint256 amount) external onlyOwner {
        require(token != twoTokenAddress, "Collateral token");
        IERC20(token).safeTransfer(msg.sender, amount);
    }
    function emergencyWithdrawBNB(uint256 amount) external onlyOwner {
        (bool s, ) = payable(msg.sender).call{value: amount}("");
        require(s, "Transfer failed");
    }
}
