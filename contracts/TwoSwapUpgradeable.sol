// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/**
 * TwoSwapUpgradeable — UUPS-upgradeable twin of TwoSwap. Deployed behind an ERC1967 proxy
 * (TwoSwapProxy) so the swap address stays permanent while the logic can be upgraded.
 *
 * Same trade semantics as TwoSwap:
 * - Trades execute against the 02-BNB V2 pair, so the token's 3% V2 tax keeps firing.
 * - MUST NOT be added to TwoProtocol.isExcluded — otherwise the 3% tax would be bypassed.
 * - Protocol fee (feeBps <= FEE_CAP) charged per swap; feeTo is owner-configurable.
 *
 * Constructor logic moved into initialize(); _disableInitializers() prevents direct init on
 * the implementation. router/token/wbnb are now regular storage (they were immutable before —
 * immutables cannot be upgraded, which is exactly why this variant exists).
 */
contract TwoSwapUpgradeable is Initializable, Ownable2StepUpgradeable, ReentrancyGuardUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    uint256 public constant FEE_DENOMINATOR = 10_000;
    /// @dev hard cap: 0.5% (50 bps) — the owner cannot set a higher fee
    uint256 public constant FEE_CAP = 50;

    uint256 public feeBps;              // default 25 = 0.25%
    address public feeTo;               // protocol fee recipient

    address public router;              // PancakeSwap V2 Router (was immutable)
    address public token;               // 02 (TwoProtocol) (was immutable)
    address public wbnb;                // WBNB (was immutable)

    // DAO governance (appended — storage MUST stay append-only across upgrades):
    // split a part of the protocol fee to staking dividends.
    uint256 public dividendBps;         // fee -> dividend pools ratio (default 0 = all to feeTo)
    uint256 public lpShareBps;          // dividend pool LP share — defaults to 0 when unset, and initialize() does NOT set it: it is only ever written by the DAO's setDividendSplit. With 0, raising dividendBps alone sends nothing to LP stakers.
    address public dao;                 // TwoDAO (onlyDAO setters)
    address public rewardDistributor;   // single-token staking pool
    address public lpReward;            // LP staking pool
    // DAO-controlled fee switch (appended — V10): fee applies only when enabled.
    bool public feeEnabled;             // DAO can propose enabling/disabling the protocol fee (the rate is still determined by feeBps)

    event FeeSet(uint256 oldBps, uint256 newBps);
    event FeeToSet(address indexed oldTo, address indexed newTo);
    event FeeEnabledChanged(address indexed by, bool enabled);
    event Swap(address indexed user, bool isBuy, uint256 amountIn, uint256 amountOut, uint256 fee);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _router, address _token, address _wbnb, address _feeTo, uint256 _feeBps) external initializer {
        __Ownable2Step_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        require(_router != address(0) && _token != address(0) && _wbnb != address(0) && _feeTo != address(0), "Zero address");
        require(_feeBps <= FEE_CAP, "Fee over cap");
        router = _router;
        token = _token;
        wbnb = _wbnb;
        feeTo = _feeTo;
        feeBps = _feeBps;
    }

    /// Only the owner may upgrade the implementation (UUPS).
    function _authorizeUpgrade(address /*newImplementation*/) internal override onlyOwner {}

    /// Accept BNB returned by the router (supporting fee-on-transfer variants pay out to this contract).
    receive() external payable {}

    /* ============ Buy: BNB -> 02 ============ */
    function buy(uint256 minOut, uint256 deadline) external payable nonReentrant {
        require(block.timestamp < deadline, "Expired");
        require(msg.value > 0, "Zero input");

        uint256 fee = feeEnabled ? (msg.value * feeBps) / FEE_DENOMINATOR : 0;
        uint256 swapAmount = msg.value - fee;
        if (fee > 0) _handleFee(fee);

        address[] memory path = new address[](2);
        path[0] = wbnb;
        path[1] = token;
        IRouter(router).swapExactETHForTokensSupportingFeeOnTransferTokens{value: swapAmount}(minOut, path, msg.sender, deadline);

        emit Swap(msg.sender, true, msg.value, 0, fee);
    }

    /* ============ Sell: 02 -> BNB ============ */
    function sell(uint256 amountIn, uint256 minOut, uint256 deadline) external nonReentrant {
        require(block.timestamp < deadline, "Expired");
        require(amountIn > 0, "Zero input");

        IERC20(token).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(token).safeApprove(router, amountIn);

        uint256 balBefore = address(this).balance;
        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = wbnb;
        IRouter(router).swapExactTokensForETHSupportingFeeOnTransferTokens(amountIn, 0, path, address(this), deadline);

        uint256 bnbReceived = address(this).balance - balBefore;

        uint256 fee = feeEnabled ? (bnbReceived * feeBps) / FEE_DENOMINATOR : 0;
        uint256 toUser = bnbReceived - fee;
        // minOut is the floor for what the CALLER receives, so it has to be checked against the net
        // amount: checking the gross (as this used to) let the protocol fee eat into the guard, so a
        // swap could hand back less than the caller's own minimum and still pass.
        require(toUser >= minOut, "Slippage");
        if (fee > 0) _handleFee(fee);
        _sendBNB(msg.sender, toUser);

        emit Swap(msg.sender, false, amountIn, toUser, fee);
    }

    /* ============ Generic: BNB -> any token ============ */
    function buyToken(address tokenOut, uint256 minOut, uint256 deadline) external payable nonReentrant {
        require(block.timestamp < deadline, "Expired");
        require(msg.value > 0, "Zero input");
        require(tokenOut != address(0), "Zero address");

        uint256 fee = feeEnabled ? (msg.value * feeBps) / FEE_DENOMINATOR : 0;
        uint256 swapAmount = msg.value - fee;
        if (fee > 0) _handleFee(fee);

        address[] memory path = new address[](2);
        path[0] = wbnb;
        path[1] = tokenOut;
        IRouter(router).swapExactETHForTokensSupportingFeeOnTransferTokens{value: swapAmount}(minOut, path, msg.sender, deadline);

        emit Swap(msg.sender, true, msg.value, 0, fee);
    }

    /* ============ Generic: any token -> BNB ============ */
    function sellToken(address tokenIn, uint256 amountIn, uint256 minOut, uint256 deadline) external nonReentrant {
        require(block.timestamp < deadline, "Expired");
        require(amountIn > 0, "Zero input");
        require(tokenIn != address(0), "Zero address");

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenIn).safeApprove(router, amountIn);

        uint256 balBefore = address(this).balance;
        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = wbnb;
        IRouter(router).swapExactTokensForETHSupportingFeeOnTransferTokens(amountIn, 0, path, address(this), deadline);

        uint256 bnbReceived = address(this).balance - balBefore;

        uint256 fee = feeEnabled ? (bnbReceived * feeBps) / FEE_DENOMINATOR : 0;
        uint256 toUser = bnbReceived - fee;
        // minOut is the floor for what the CALLER receives, so it has to be checked against the net
        // amount: checking the gross (as this used to) let the protocol fee eat into the guard, so a
        // swap could hand back less than the caller's own minimum and still pass.
        require(toUser >= minOut, "Slippage");
        if (fee > 0) _handleFee(fee);
        _sendBNB(msg.sender, toUser);

        emit Swap(msg.sender, false, amountIn, toUser, fee);
    }

    /* ============ Generic: token -> token (path from the frontend) ============ */
    function swapTokens(address[] calldata path, uint256 amountIn, uint256 minOut, uint256 deadline) external nonReentrant {
        require(block.timestamp < deadline, "Expired");
        require(amountIn > 0, "Zero input");
        require(path.length >= 2, "Bad path");
        address tokenIn = path[0];
        address tokenOut = path[path.length - 1];
        require(tokenIn != address(0) && tokenOut != address(0), "Zero address");
        require(tokenIn != tokenOut, "Same token");

        uint256 fee = feeEnabled ? (amountIn * feeBps) / FEE_DENOMINATOR : 0;
        uint256 swapAmount = amountIn - fee;

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        if (fee > 0) IERC20(tokenIn).safeTransfer(feeTo, fee);
        IERC20(tokenIn).safeApprove(router, swapAmount);

        uint256 balBefore = IERC20(tokenOut).balanceOf(msg.sender);
        IRouter(router).swapExactTokensForTokensSupportingFeeOnTransferTokens(swapAmount, minOut, path, msg.sender, deadline);
        uint256 received = IERC20(tokenOut).balanceOf(msg.sender) - balBefore;
        require(received >= minOut, "Slippage");

        emit Swap(msg.sender, false, amountIn, received, fee);
    }

    /* ============ Owner ============ */
    function setFeeBps(uint256 _bps) external onlyOwner {
        require(_bps <= FEE_CAP, "Fee over cap");
        emit FeeSet(feeBps, _bps);
        feeBps = _bps;
    }

    function setFeeTo(address _to) external onlyOwner {
        require(_to != address(0), "Zero address");
        emit FeeToSet(feeTo, _to);
        feeTo = _to;
    }

    /// Rescue accidentally sent BNB (protocol fees are routed to feeTo on every swap).
    function rescueBNB() external onlyOwner {
        uint256 bal = address(this).balance;
        if (bal > 0) _sendBNB(msg.sender, bal);
    }

    /// Rescue accidentally sent tokens.
    function rescueToken(address t) external onlyOwner {
        uint256 bal = IERC20(t).balanceOf(address(this));
        if (bal > 0) IERC20(t).safeTransfer(msg.sender, bal);
    }

    /* ============ Internal ============ */
    function _sendBNB(address to, uint256 amount) internal {
        (bool s, ) = payable(to).call{value: amount}("");
        require(s, "BNB transfer failed");
    }

    /// Protocol fee routing: dividendBps goes to the staking dividend pools (LP/single),
    /// the rest to feeTo. Fails on individual legs degrade to feeTo so no fee is lost.
    function _handleFee(uint256 fee) internal {
        uint256 toStake = (fee * dividendBps) / 10000;
        uint256 toFeeTo = fee - toStake;
        if (toStake > 0) _distributeDividend(toStake);
        if (toFeeTo > 0) _sendBNB(feeTo, toFeeTo);
    }

    function _distributeDividend(uint256 amount) internal {
        uint256 toLp = (amount * lpShareBps) / 10000;
        uint256 toSingle = amount - toLp;
        if (toLp > 0 && lpReward != address(0)) {
            (bool s, ) = payable(lpReward).call{value: toLp}("");
            if (!s) _sendBNB(feeTo, toLp);
        } else if (toLp > 0) {
            _sendBNB(feeTo, toLp);
        }
        if (toSingle > 0 && rewardDistributor != address(0)) {
            (bool s, ) = payable(rewardDistributor).call{value: toSingle}(
                abi.encodeWithSignature("addV2Reward()")
            );
            if (!s) _sendBNB(feeTo, toSingle);
        } else if (toSingle > 0) {
            _sendBNB(feeTo, toSingle);
        }
    }

    /* ============ DAO governance ============ */
    function setDao(address _dao) external onlyOwner {
        require(_dao != address(0), "Zero address");
        dao = _dao;
    }

    function setRewardTargets(address _rd, address _lpReward) external onlyOwner {
        rewardDistributor = _rd;
        lpReward = _lpReward;
    }

    /// DAO adjusts the protocol fee dividend split: dividendBps = share entering the dividend pools, lpShareBps = LP share within the dividend pool
    function setDividendSplit(uint256 _dividendBps, uint256 _lpShareBps) external {
        require(msg.sender == dao, "Only dao");
        require(_dividendBps <= 10000 && _lpShareBps <= 10000, "Bad bps");
        dividendBps = _dividendBps;
        lpShareBps = _lpShareBps;
    }

    /// DAO (or owner) proposes enabling/disabling protocol fee collection; once enabled it is charged at the feeBps rate
    function setFeeEnabled(bool _enabled) external {
        require(msg.sender == dao || msg.sender == owner(), "Not authorized");
        feeEnabled = _enabled;
        emit FeeEnabledChanged(msg.sender, _enabled);
    }
}

interface IRouter {
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable;
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}
