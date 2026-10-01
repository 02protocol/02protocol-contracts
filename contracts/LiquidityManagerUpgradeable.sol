// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/**
 * LiquidityManagerUpgradeable — UUPS-upgradeable variant of LiquidityManager, deployed behind an
 * ERC1967 proxy so the address stays fixed while the implementation can be upgraded locally.
 * One-step "add 02-BNB liquidity + auto-stake the LP into LPReward".
 *
 * The user approves 02 to this contract and sends BNB with the call; the manager:
 *   1) pulls the 02 and calls PancakeSwap Router.addLiquidityETHSupportingFeeOnTransferTokens
 *      (the supporting variant is required: 02 carries a 3% transfer tax),
 *   2) receives the minted LP tokens,
 *   3) calls LPReward.stakeLpFor(user, lpAmount, lockDays) so the LP is staked under the user
 *      and starts earning BNB dividends.
 *
 * The 3% tax applies when the transfer hits the pair while isV2Open; amountTokenMin must leave
 * room for it (frontend passes ~94% of the desired amount).
 *
 * NOTE: the former `immutable` router/token/wbnb/pair are now regular state vars set in
 * initialize() (immutables read the implementation's code, which is meaningless behind a proxy).
 */
contract LiquidityManagerUpgradeable is
    Initializable,
    Ownable2StepUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    address public router;
    address public token;   // 02 (TwoProtocol)
    address public wbnb;
    address public pair;    // 02-BNB V2 pair (= the LP token)
    address public lpReward;          // LPReward contract

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// One-time initialization, called by the proxy right after deployment (delegatecall).
    function initialize(address _router, address _token, address _wbnb, address _pair) external initializer {
        require(_router != address(0) && _token != address(0) && _wbnb != address(0) && _pair != address(0), "Zero address");
        __Ownable2Step_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        router = _router;
        token  = _token;
        wbnb   = _wbnb;
        pair   = _pair;
    }

    /// Only the owner may upgrade the implementation (UUPS).
    function _authorizeUpgrade(address /*newImplementation*/) internal override onlyOwner {}

    receive() external payable {}

    function setLpReward(address _r) external onlyOwner {
        require(_r != address(0), "Zero address");
        lpReward = _r;
    }

    /// @param amountTwo 02 amount to add (user must approve LiquidityManager)
    /// @param minTwo    minimum 02 the pair must receive (slippage)
    /// @param minBnb    minimum BNB accepted (slippage)
    /// @param lockDays  30/60/90 days lock for the LP stake
    function addLiquidityAndStake(uint256 amountTwo, uint256 minTwo, uint256 minBnb, uint256 lockDays) external payable nonReentrant {
        require(amountTwo > 0 && msg.value > 0, "Zero input");
        require(lpReward != address(0), "LPReward not set");

        // Snapshots taken BEFORE anything is pulled in, so the unused input can be measured afterwards
        // as a delta. msg.value is already part of the balance on entry, hence the subtraction.
        uint256 tokBefore = IERC20(token).balanceOf(address(this));
        uint256 bnbBefore = address(this).balance - msg.value;

        IERC20(token).safeTransferFrom(msg.sender, address(this), amountTwo);
        // reset to 0 first: the router may consume less than the approved amount (off-ratio
        // input), and safeApprove reverts on a non-zero -> non-zero approval
        IERC20(token).safeApprove(router, 0);
        IERC20(token).safeApprove(router, amountTwo);

        uint256 lpBefore = IERC20(pair).balanceOf(address(this));
        IRouter(router).addLiquidityETHSupportingFeeOnTransferTokens{value: msg.value}(
            token, amountTwo, minTwo, minBnb, address(this), block.timestamp + 1200
        );
        uint256 lpGot = IERC20(pair).balanceOf(address(this)) - lpBefore;
        require(lpGot > 0, "No LP minted");

        // Hand back whatever the router did not take. PancakeSwap's _addLiquidity uses the amounts that
        // match the pool ratio and refunds the rest: the unspent BNB comes back to this contract, and the
        // 02 that was approved but never pulled simply stays here. Leaving either in place would strand
        // the caller's money — the 02 has no rescue path at all, and the BNB would sit where any later
        // removeLiquidity() caller could pick it up.
        _refundUnused(msg.sender, tokBefore, bnbBefore);

        IERC20(pair).safeApprove(lpReward, lpGot);
        // lockDays is expressed in days (30/60/90); LPReward expects seconds
        ILPReward(lpReward).stakeLpFor(msg.sender, lpGot, lockDays * 1 days);
    }

    /// Returns to `to` whatever came in on top of the two snapshots: unspent 02 and an unspent BNB
    /// refund. Shared by the two liquidity-adding paths so neither can quietly keep a caller's money.
    function _refundUnused(address to, uint256 tokBefore, uint256 bnbBefore) internal {
        uint256 tokLeft = IERC20(token).balanceOf(address(this));
        tokLeft = tokLeft > tokBefore ? tokLeft - tokBefore : 0;
        if (tokLeft > 0) IERC20(token).safeTransfer(to, tokLeft);

        uint256 bnbLeft = address(this).balance;
        bnbLeft = bnbLeft > bnbBefore ? bnbLeft - bnbBefore : 0;
        if (bnbLeft > 0) {
            (bool s, ) = payable(to).call{value: bnbLeft}("");
            require(s, "Refund failed");
        }
    }

    /// Pool-setup window only: inject 02 + BNB into the pair WITHOUT staking — the minted LP is
    /// sent straight back to the caller (so it can be verified and burned).
    ///
    /// This is the ONLY way to add liquidity while `liquidityOpen` is true: the token only lets
    /// 02 enter the pair when `from == LiquidityManager`, which is what blocks "selling into the
    /// pool" (a router swap or a custom contract calling pair.swap() directly) in that window.
    ///
    /// @param amountTwo 02 amount to add (caller must approve this manager)
    /// @param minTwo    minimum 02 the pair must receive (slippage)
    /// @param minBnb    minimum BNB accepted (slippage)
    function seedLiquidity(uint256 amountTwo, uint256 minTwo, uint256 minBnb)
        external
        payable
        nonReentrant
        returns (uint256 lpGot)
    {
        require(amountTwo > 0 && msg.value > 0, "Zero input");
        require(IProtocolLite(token).liquidityOpen(), "Pool setup not open");

        // See addLiquidityAndStake: snapshots first, so the unused input can be refunded rather than
        // stranded in this contract.
        uint256 tokBefore = IERC20(token).balanceOf(address(this));
        uint256 bnbBefore = address(this).balance - msg.value;

        IERC20(token).safeTransferFrom(msg.sender, address(this), amountTwo);
        // reset to 0 first: the router may consume less than the approved amount (off-ratio
        // input), and safeApprove reverts on a non-zero -> non-zero approval
        IERC20(token).safeApprove(router, 0);
        IERC20(token).safeApprove(router, amountTwo);

        uint256 lpBefore = IERC20(pair).balanceOf(address(this));
        IRouter(router).addLiquidityETHSupportingFeeOnTransferTokens{value: msg.value}(
            token, amountTwo, minTwo, minBnb, address(this), block.timestamp + 1200
        );
        lpGot = IERC20(pair).balanceOf(address(this)) - lpBefore;
        require(lpGot > 0, "No LP minted");

        _refundUnused(msg.sender, tokBefore, bnbBefore);

        // hand the LP back — during the window the caller is expected to burn it
        IERC20(pair).safeTransfer(msg.sender, lpGot);
    }

    /// Remove liquidity tax-free: the LP is withdrawn to this manager first, then the
    /// 02/BNB are forwarded to the user. Both 02 legs are exempt because the protocol
    /// exempts transfers from/to the LiquidityManager (swap-only tax).
    /// @param lpAmount  LP tokens to remove (user must approve LiquidityManager)
    /// @param minToken  minimum 02 accepted (slippage)
    /// @param minBnb    minimum BNB accepted (slippage)
    function removeLiquidity(uint256 lpAmount, uint256 minToken, uint256 minBnb) external nonReentrant {
        require(lpAmount > 0, "Zero LP");

        IERC20(pair).safeTransferFrom(msg.sender, address(this), lpAmount);
        // Reset first, like the add/seed paths: some LP tokens refuse a non-zero -> non-zero approval,
        // and a router that leaves part of the allowance behind would otherwise revert the next call.
        IERC20(pair).safeApprove(router, 0);
        IERC20(pair).safeApprove(router, lpAmount);

        // Only what THIS call produced may leave. Paying out the contract's whole balance — which is what
        // this used to do — handed any other user's unspent input, plus any BNB merely sitting here, to
        // whoever called with the smallest possible LP amount first.
        uint256 tokBefore = IERC20(token).balanceOf(address(this));
        uint256 bnbBefore = address(this).balance;

        IRouter(router).removeLiquidityETHSupportingFeeOnTransferTokens(
            token, lpAmount, minToken, minBnb, address(this), block.timestamp + 1200
        );

        uint256 tokGot = IERC20(token).balanceOf(address(this)) - tokBefore;
        if (tokGot > 0) IERC20(token).safeTransfer(msg.sender, tokGot);

        uint256 bnbGot = address(this).balance - bnbBefore;
        if (bnbGot > 0) {
            (bool s, ) = payable(msg.sender).call{value: bnbGot}("");
            require(s, "BNB failed");
        }
    }

    /// Rescue accidentally sent BNB.
    function rescueBNB() external onlyOwner {
        uint256 bal = address(this).balance;
        if (bal > 0) {
            (bool s, ) = payable(msg.sender).call{value: bal}("");
            require(s, "BNB failed");
        }
    }
}

interface IRouter {
    function addLiquidityETHSupportingFeeOnTransferTokens(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external payable;
    function removeLiquidityETHSupportingFeeOnTransferTokens(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountToken, uint256 amountETH);
}

interface ILPReward {
    function stakeLpFor(address user, uint256 amount, uint256 lockDays) external;
}

interface IProtocolLite {
    /// true while the pool-setup window is open (02 only enters the pair via this manager)
    function liquidityOpen() external view returns (bool);
}
