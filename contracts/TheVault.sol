// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "./interfaces/IUniswapV2Pair.sol";
import "./interfaces/IUniswapV2Router02.sol";

interface ICONSTSWAP {
    function getMintAmountOut(address tokenAddr, uint256 tokenAmountIn) external view returns (uint256, uint256);

    function getMintAmountIn(address tokenAddr, uint256 stalAmountOut) external view returns (uint256, uint256);

    function mint(address tokenAddr, uint256 tokenAmountIn, uint256 stalMintedMin) external returns (uint256);

    function getRedeemAmountOut(address tokenAddr, uint256 stalAmountIn) external view returns (uint256, uint256);

    function getRedeemAmountIn(address tokenAddr, uint256 tokenAmountOut) external view returns (uint256, uint256);

    function redeem(address tokenAddr, uint256 stalAmountIn, uint256 tokenAmountOutMin) external returns (uint256);
}

contract TheVault is ERC20, ReentrancyGuard, Pausable, Ownable {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;
    using Address for address;

    address public _aldabra;
    address public _feeCollector;

    address public _stal;
    address public _pairToken;
    address public _pairContract;
    address public _router;

    uint256 public _arbitrageFee = 10e18; // 10 ALDABRA
    uint256 public _arbitrageShare = 20; // 20%

    mapping(address => uint256) public _lastInteraction;

    uint256 public constant INTERACTION_DELAY = 1; // block;
    uint256 public constant ARBITRAGE_FEE_MAX = 200e18; // 200 ALDABRA
    uint256 public constant ARBITRAGE_SHARE_MAX = 50; // 50%
    uint256 public constant ARBITRAGE_LEVERAGE_MAX = 5; // x5

    bool public _enableArbitrage = false;
    modifier whenEnableArbitrage() {
        require(_enableArbitrage, "DISABLED");
        _;
    }
    
    event Deposited(
        address indexed provider,
        uint256 amountIn,
        uint256 ibTokenSupply
    );

    event Withdrawn(
        address indexed provider,
        uint256 amountOut,
        uint256 ibTokenSupply
    );

    event Arbitrage(
        address indexed user,
        uint256 userProfit,
        uint256 profitShare
    );

    constructor(
        address stal,
        address router,
        address pairContract,
        address aldabra,
        address feeCollector
    )
        public
        ERC20("Interest Bearing STAL", "ibSTAL")
    {
        require(stal != address(0), "INVALID_STAL");
        require(aldabra != address(0), "INVALID_ALDABRA");

        _stal = stal;
        setRouterContract(router);
        setPairContract(pairContract);

        _aldabra = aldabra;
        setFeeCollector(feeCollector);
    }

    // set Fee Collector
    function setFeeCollector(address feeCollector) public onlyOwner {
        require(feeCollector != address(0), "INVALID_FEE_COLLECTOR");
        _feeCollector = feeCollector;
    }

    // set Arbitrage Fee
    function setArbitrageFee(uint256 arbitrageFee) public onlyOwner {
        require(arbitrageFee <= ARBITRAGE_FEE_MAX, "> ARBITRAGE_FEE_MAX");
        _arbitrageFee = arbitrageFee;
    }

    // set Arbitrage Share
    function setArbitrageShare(uint256 arbitrageShare) public onlyOwner {
        require(arbitrageShare <= ARBITRAGE_SHARE_MAX, "> ARBITRAGE_SHARE_MAX");
        _arbitrageShare = arbitrageShare;
    }

    // set Router Contract
    function setRouterContract(address routerContract) public onlyOwner {
        require(routerContract != address(0), "INVALID_ROUTER");
        _router = routerContract;
    }

    // set Pair Contract
    function setPairContract(address pairContract) public onlyOwner {
        require(pairContract != address(0), "INVALID_PAIRCONTRACT");

        IUniswapV2Pair pair = IUniswapV2Pair(pairContract);
        if (_stal == pair.token0()) {
            _pairToken = pair.token1();
        } else {
            require(_stal == pair.token1(), "INVALID_TOKEN");
            _pairToken = pair.token0();
        }

        _pairContract = pairContract;
    }

    function checkAvailability() private view {
        require(
            _lastInteraction[msg.sender] + INTERACTION_DELAY <= block.number,
            "< DELAY"
        );
    }

    function getTotalBalance() public view returns (uint256) {
        return IERC20(_stal).balanceOf(address(this));
    }

    function getIbSTALPrice(uint256 ibAmount) public view returns (uint256) {
        uint256 totalBalance = getTotalBalance();
        uint256 totalSupply = totalSupply();

        if (totalSupply == 0) return 0;

        return ibAmount.mul(totalBalance).div(totalSupply);
    }
    
    /// @dev Given the STAL amount to be deposited, return the amount of ibSTAL
    function getMintAmountByStal(
        uint256 amountIn
    ) public view returns (uint256 _toMint) {
        uint256 totalSupply = totalSupply();

        uint256 totalBalance = getTotalBalance();
        if (totalSupply == 0) {
            _toMint = amountIn;
        } else {
            _toMint = amountIn.mul(totalSupply).div(totalBalance);
        }
    }

    /// @dev Given the STAL amount to be deposited, mint ibSTAL
    function deposit(
        uint256 amountIn,
        uint256 minToMint
    ) external nonReentrant whenNotPaused returns (uint256 toMint) {
        require(amountIn > 0, "INSUFFICIENT_AMOUNT");
        uint256 _toMint = getMintAmountByStal(amountIn);

        require(_toMint > 0, "INSUFFICIENT_LIQUIDITY_MINTED");
        require(_toMint >= minToMint, "SLIPPAGE");
                    
        IERC20(_stal).safeTransferFrom(
            msg.sender,
            address(this),
            amountIn
        );

        // Mint the user's ibTokens
        toMint = _toMint;
        _mint(msg.sender, toMint);

        emit Deposited(
            msg.sender,
            amountIn,
            totalSupply()
        );
    }

    /// @dev Given the other token amount to be deposited, return the amount of ibSTAL
    function getMintAmountByOther(
        address tokenAddr,
        uint256 tokenAmountIn
    ) public view returns (uint256 _stalAmountMin, uint256 _toMint, uint256 _fee) {
        require(tokenAddr != address(0), "INVALID_TOKEN_ADDRESS");

        (_stalAmountMin, _fee) = ICONSTSWAP(_stal).getMintAmountOut(tokenAddr, tokenAmountIn);
        _toMint = getMintAmountByStal(_stalAmountMin);
    }

    /// @dev Given the other token amount to be deposited, mint ibSTAL
    function depositByOther(
        address tokenAddr,
        uint256 tokenAmountIn,
        uint256 minToMint
    ) external nonReentrant whenNotPaused returns (uint256 toMint, uint256 fee) {
        require(tokenAmountIn > 0, "INSUFFICIENT_AMOUNT");

        (uint256 _stalAmountMin, uint256 _toMint, uint256 _fee) = getMintAmountByOther(tokenAddr, tokenAmountIn);
        require(_stalAmountMin > 0, "INSUFFICIENT_STAL_AMOUNT");
        require(_toMint > 0, "INSUFFICIENT_LIQUIDITY_MINTED");
        require(_toMint >= minToMint, "SLIPPAGE");

        IERC20(tokenAddr).safeTransferFrom(
            msg.sender,
            address(this),
            tokenAmountIn
        );
        IERC20(tokenAddr).safeApprove(_stal, 0);
        IERC20(tokenAddr).safeApprove(_stal, tokenAmountIn);
        uint256 stalAmount = ICONSTSWAP(_stal).mint(tokenAddr, tokenAmountIn, _stalAmountMin);

        // Mint the user's ibTokens
        fee = _fee;
        toMint = _toMint;
        _mint(msg.sender, toMint);

        emit Deposited(
            msg.sender,
            stalAmount,
            totalSupply()
        );
    }

    /// @dev Given the ibSTAL amount to be burned, return the amount of STAL
    function getBurnAmountByStal(
        uint256 ibAmount
    ) public view returns (uint256 amountOut) {
        uint256 totalBalance = getTotalBalance();
        uint256 totalSupply = totalSupply();

        if (totalSupply != 0) amountOut = ibAmount.mul(totalBalance).div(totalSupply);
    }

    /// @dev Given the ibSTAL amount to be burned, Withdraw STAL
    function withdraw(
        uint256 ibAmount,
        uint256 amountOutMin
    ) external nonReentrant whenNotPaused returns (uint256 amountOut) {
        require(ibAmount > 0, "INSUFFICIENT_IBAMOUNT");

        amountOut = getBurnAmountByStal(ibAmount);
        require(amountOut > 0, "INSUFFICIENT_LIQUIDITY_BURNED");
        require(amountOut >= amountOutMin, "SLIPPAGE");

        // Burn the user's ibTokens
        _burn(msg.sender, ibAmount);
        IERC20(_stal).safeTransfer(msg.sender, amountOut);

        emit Withdrawn(
            msg.sender,
            amountOut,
            totalSupply()
        );
    }

    // given an input amount of an asset and pair reserves, returns the maximum output amount of the other asset
    function consult(address inputToken, uint256 amountIn) public view returns (uint256 amountOut) {
        require(inputToken == _stal || inputToken == _pairToken, "INVALID_INPUTTOKEN");
        require(amountIn > 0, "INSUFFICIENT_INPUT_AMOUNT");

        IUniswapV2Pair pair = IUniswapV2Pair(_pairContract);
        (uint256 reserve0, uint256 reserve1, ) = pair.getReserves();
        (uint256 reserveIn, uint256 reserveOut) = inputToken == pair.token0() ? (reserve0, reserve1) : (reserve1, reserve0);

        IUniswapV2Router02 router = IUniswapV2Router02(_router);
        amountOut = router.getAmountOut(amountIn, reserveIn, reserveOut);
    }

    function getArbitrageInfo(
        uint256 amountIn
    ) internal view returns (
        uint256 tokenRedeemAmount,
        uint256 stalSwapAmount,
        uint256 tokenSwapAmount,
        uint256 stalMintAmount
    ) {
        (tokenRedeemAmount, ) = ICONSTSWAP(_stal).getRedeemAmountOut(_pairToken, amountIn);
        stalSwapAmount = consult(_pairToken, tokenRedeemAmount);

        tokenSwapAmount = consult(_stal, amountIn);
        (stalMintAmount, ) = ICONSTSWAP(_stal).getMintAmountOut(_pairToken, tokenSwapAmount);
    }

    function arbitrageSwap(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] memory path
    ) internal returns (uint256 amountOut) {
        IUniswapV2Router02 router = IUniswapV2Router02(_router);
        
        IERC20(path[0]).safeApprove(_router, 0);
        IERC20(path[0]).safeApprove(_router, amountIn);
        // make the swap
        uint256[] memory amounts = new uint256[](2);
        amounts = router.swapExactTokensForTokens(
            amountIn,
            amountOutMin,
            path,
            address(this),
            block.timestamp
        );
        amountOut = amounts[1];
    }

    function getArbitrageProfit(
        uint256 amountIn
    ) external view returns (
        bool profitable,
        uint256 profit,
        uint256 userProfit,
        uint256 profitShare
    ) {
        profitable = false;
        profit = 0;
        profitShare = 0;
        (,uint256 stalSwapAmount,, uint256 stalMintAmount) = getArbitrageInfo(amountIn);

        if (stalSwapAmount > amountIn) {
            profit = stalSwapAmount.sub(amountIn);
        } else if (stalMintAmount > amountIn) {
            profit = stalMintAmount.sub(amountIn);
        }

        if (profit != 0) {
            profitable = true;
            profitShare = profit.mul(_arbitrageShare).div(100);
            userProfit = profit.sub(profitShare);
        }
    }

    function arbitrage(
        uint256 amountIn
    ) external nonReentrant whenNotPaused whenEnableArbitrage {
        checkAvailability();

        (   uint256 tokenRedeemAmount,
            uint256 stalSwapAmount,,
            uint256 stalMintAmount
        ) = getArbitrageInfo(amountIn);

        require(stalSwapAmount > amountIn || stalMintAmount > amountIn, "CAN_NOT_ARBITRAGE");

        if (_arbitrageFee != 0) {
            uint256 aldabraAmount = IERC20(_aldabra).balanceOf(msg.sender);
            require(aldabraAmount >= _arbitrageFee, "NOT_ENOUGH_ALDABRA");
            IERC20(_aldabra).safeTransferFrom(
                msg.sender,
                _feeCollector,
                _arbitrageFee
            );
        }

        uint256 ibStalAmount = balanceOf(msg.sender);
        uint256 ibStalValue = getIbSTALPrice(ibStalAmount);
        uint256 leverageValue = ibStalValue.mul(ARBITRAGE_LEVERAGE_MAX);
        require(amountIn <= leverageValue, "EXCEEDED_LIMIT");

        uint256 totalBalance = getTotalBalance();
        require(amountIn <= totalBalance, "INSUFFICIENT_BALANCE");

        _lastInteraction[msg.sender] = block.number;

        uint256 swapAmountIn;
        uint256 swapAmountOutMin;
        uint256 arbitrageAmountOut;
        // generate the uniswap pair path
        address[] memory path = new address[](2);
        if (stalSwapAmount > amountIn) {
            path[0] = _pairToken;
            path[1] = _stal;

            swapAmountOutMin = amountIn;

            IERC20(_stal).safeApprove(_stal, 0);
            IERC20(_stal).safeApprove(_stal, amountIn);
            swapAmountIn = ICONSTSWAP(_stal).redeem(_pairToken, amountIn, tokenRedeemAmount);

            arbitrageAmountOut = arbitrageSwap(swapAmountIn, swapAmountOutMin, path);
        } else if (stalMintAmount > amountIn) {
            path[0] = _stal;
            path[1] = _pairToken;
            
            (swapAmountOutMin, ) = ICONSTSWAP(_stal).getMintAmountIn(_pairToken, amountIn);
            swapAmountIn = amountIn;

            uint256 tokenAmount = arbitrageSwap(swapAmountIn, swapAmountOutMin, path);

            IERC20(_pairToken).safeApprove(_stal, 0);
            IERC20(_pairToken).safeApprove(_stal, tokenAmount);
            arbitrageAmountOut = ICONSTSWAP(_stal).mint(_pairToken, tokenAmount, swapAmountIn);
        }

        if (arbitrageAmountOut > amountIn) {
            uint256 profit = arbitrageAmountOut.sub(amountIn);
            uint256 profitShare = profit.mul(_arbitrageShare).div(100);
            uint256 userProfit = profit.sub(profitShare);

            if (userProfit != 0) {
                IERC20(_stal).safeTransfer(msg.sender, userProfit);
            }

            emit Arbitrage(
                msg.sender,
                userProfit,
                profitShare
            );
        }
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function enableArbitrage(bool isEnable) external onlyOwner {
        _enableArbitrage = isEnable;
    }
}