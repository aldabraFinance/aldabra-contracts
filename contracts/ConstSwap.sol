// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

interface IBVAULT {
    function deposit(uint256 _amount) external;

    function withdraw() external returns (uint256);
}

contract ConstSwap is ERC20, ReentrancyGuard, Pausable, Ownable {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;
    using Address for address;

    // Constants for various precisions
    uint256 private constant PRICE_PRECISION = 1e18;

    uint256 public constant SWAP_FEE_MAX = 1e16; // 1%
    uint256 public constant MINTING_FEE_MAX = 1e16; // 1%
    uint256 public constant REDEMPTION_FEE_MAX = 1e16; // 1%
    uint256 public constant ADMIN_FEE_MAX = 50; // 50%
    uint256 public constant RESERVE_RATIO_MAX = 100; // 100%
    uint256 public constant REBALANCE_PERIOD_MAX = 86400; // 24 hours

    /// @dev Fee collector of the contract
    address public _feeCollector;
    address public _theVault;

    // Maps token address to an index in the pool. Used to prevent duplicate tokens in the pool.
    // getTokenIndex function also relies on this mapping to retrieve token index.
    mapping(address => uint256) private _tokenIndexes;
    mapping(uint256 => address) private _pooledTokens;
    mapping(uint256 => address) private _ibTokens;
    mapping(uint256 => bool) private _enableIbToken;
    mapping(uint256 => uint256) private _tokenDecimals;
    mapping(uint256 => uint256) private _ibTokenBalances;
    mapping(uint256 => uint256) private _minWeight;
    mapping(uint256 => uint256) private _maxWeight;

    mapping(address => uint256) private _tokenExist;
    mapping(uint256 => uint256) public _lastRebalance;
    
    // Fee calculation
    uint256 public _swapFee = 2e14; //0.02%
    uint256 public _adminFee = 50; // 50%
    uint256 public _adminInterestFee = 20; // 20%
    uint256 public _mintingFee = 2e14; //0.02%
    uint256 public _redemptionFee = 4e14; //0.04%

    uint256 public _reserveRatio = 20; // 20% of total pooled token amounts
    uint256 public _maxRatio = 30; // 30% of total pooled token amounts
    uint256 public _rebalancePeriod = 21600; // 6 hours

    uint256 public _nTokens;

    event Swap(
        address indexed buyer,
        address tokenAddrIn,
        address tokenAddrOut,
        uint256 inAmounts,
        uint256 outAmounts,
        uint256 tradeVolume
    );

    event MintFee(
        address theVault,
        uint256 feeToTheVault,
        address feeCollector,
        uint256 adminFee
    );

    event Mint(
        address indexed provider,
        address token,
        uint256 inAmounts,
        uint256 stalMinted
    );

    event Redeem(
        address indexed provider,
        address token,
        uint256 stalBurned,
        uint256 outAmounts
    );

    event Rebalance(
        uint256 tokenIndex,
        uint256 depositAmount
    );

    event AddToken(
        uint256 tokenIndex,
        address token,
        address ibToken
    );

    event SetIbToken(
        uint256 tokenIndex,
        address oldIbToken,
        address newIbToken
    );

    constructor(
        address feeCollector,
        address theVault,
        address[] memory tokenAddr,
        address[] memory ibTokenAddr,
        uint256[] memory minWeight,
        uint256[] memory maxWeight
    )
        public
        ERC20("Stal Stablecoin", "STAL")
    {
        require(feeCollector != address(0), "feeCollector = address(0)");
        require(theVault != address(0), "theVault = address(0)");

        require(tokenAddr.length == ibTokenAddr.length, "must have the same length");
        require(tokenAddr.length == minWeight.length, "incorrect minWeight length");
        require(tokenAddr.length == maxWeight.length, "incorrect maxWeight length");

        _feeCollector = feeCollector;
        _theVault = theVault;

        uint256 nTokens = tokenAddr.length;

        for (uint256 i = 0; i < nTokens; i++) {
            require(tokenAddr[i] != address(0), "The 0 address isn't an ERC-20");
            require(minWeight[i] <= maxWeight[i], "Min weight must <= Max weight");
            require(maxWeight[i] <= PRICE_PRECISION, "Max weight must <= 1e18");

            bool enableIbToken = false;
            if (ibTokenAddr[i] != address(0)) {
                enableIbToken = true;
            }

            _tokenIndexes[tokenAddr[i]] = i;

            _pooledTokens[i] = tokenAddr[i];
            _ibTokens[i] = ibTokenAddr[i];
            _enableIbToken[i] = enableIbToken;
            _tokenDecimals[i] = IERC20Metadata(tokenAddr[i]).decimals();
            _ibTokenBalances[i] = 0;
            _minWeight[i] = minWeight[i];
            _maxWeight[i] = maxWeight[i];

            _tokenExist[tokenAddr[i]] = 1;
        }

        _nTokens = nTokens;

        _pause();
    }

    /****************************************
     * Owner methods
     ****************************************/
    function addToken(
        address tokenAddr,
        address ibTokenAddr,
        uint256 minWeight,
        uint256 maxWeight
    )
        external
        onlyOwner
    {
        require(tokenAddr != address(0), "The 0 address isn't an ERC-20");

        // Check if index is already used.
        require(_tokenExist[tokenAddr] != 1, "Token already added");

        require(minWeight <= maxWeight, "Min weight must <= Max weight");
        require(maxWeight <= PRICE_PRECISION, "Max weight must <= 1e18");

        bool enableIbToken = false;
        if (ibTokenAddr != address(0)) {
            enableIbToken = true;
        }

        uint256 newIndex = _nTokens;

        _tokenIndexes[tokenAddr] = newIndex;

        _pooledTokens[newIndex] = tokenAddr;
        _ibTokens[newIndex] = ibTokenAddr;
        _enableIbToken[newIndex] = enableIbToken;
        _tokenDecimals[newIndex] = IERC20Metadata(tokenAddr).decimals();
        _ibTokenBalances[newIndex] = 0;
        _minWeight[newIndex] = minWeight;
        _maxWeight[newIndex] = maxWeight;

        _tokenExist[tokenAddr] = 1;
        _nTokens = _nTokens + 1;
        
        emit AddToken(newIndex, tokenAddr, ibTokenAddr);
    }

    function adjustReserveRatio(
        uint256 newReserveRatio,
        uint256 newMaxRatio
    )
        external
        onlyOwner
    {
        require(newReserveRatio <= newMaxRatio, "ReserveRatio > MaxRatio");
        require(newMaxRatio <= RESERVE_RATIO_MAX, "MaxRatio > RESERVE_RATIO_MAX");

        _reserveRatio = newReserveRatio;
        _maxRatio = newMaxRatio;
    }

    function adjustWeights(
        uint256 tokenIndex,
        uint256 newMinWeight,
        uint256 newMaxWeight
    )
        external
        onlyOwner
    {
        require(newMinWeight <= newMaxWeight, "Min weight must <= Max weight");
        require(newMaxWeight <= PRICE_PRECISION, "Max weight must <= 1");
        require(tokenIndex < _nTokens, "Token not exists");

        _minWeight[tokenIndex] = newMinWeight;
        _maxWeight[tokenIndex] = newMaxWeight;
    }

    function setEnableIbToken(uint256 tokenIndex, address newIbToken) external onlyOwner {
        require(tokenIndex < _nTokens, "Token not exists");
        address oldIbToken = _ibTokens[tokenIndex];
        require(newIbToken != oldIbToken, "newIbToken = oldIbToken");

        if (_enableIbToken[tokenIndex]) {
            // Withdraw from ibToken
            _withdrawIbtoken(tokenIndex);
        }

        _ibTokens[tokenIndex] = newIbToken;
        _enableIbToken[tokenIndex] = newIbToken != address(0);

        emit SetIbToken(tokenIndex, oldIbToken, newIbToken);
    }

    function setFeeCollector(address feeCollector) external onlyOwner {
        require(feeCollector != address(0), "The 0 address isn't an contract");
        _feeCollector = feeCollector;
    }

    function setTheVault(address theVault) external onlyOwner {
        require(theVault != address(0), "The 0 address isn't an contract");
        _theVault = theVault;
    }

    function setSwapFee(uint256 swapFee) external onlyOwner {
        require(swapFee <= SWAP_FEE_MAX, "Swap fee > SWAP_FEE_MAX");
        _swapFee = swapFee;
    }

    function setMintingFee(uint256 mintingFee) external onlyOwner {
        require(mintingFee <= MINTING_FEE_MAX, "Mint fee > MINTING_FEE_MAX");
        _mintingFee = mintingFee;
    }

    function setRedemptionFee(uint256 redemptionFee) external onlyOwner {
        require(redemptionFee <= REDEMPTION_FEE_MAX, "Redeem fee > REDEMPTION_FEE_MAX");
        _redemptionFee = redemptionFee;
    }

    function setAdminFee(uint256 adminFee) external onlyOwner {
        require (adminFee <= ADMIN_FEE_MAX, "Admin fee > ADMIN_FEE_MAX");
        _adminFee = adminFee;
    }

    function setAdminInterestFee(uint256 adminInterestFee) external onlyOwner {
        require (adminInterestFee <= ADMIN_FEE_MAX, "Interest fee > ADMIN_FEE_MAX");
        _adminInterestFee = adminInterestFee;
    }

    function setRebalancePeriod(uint256 rebalancePeriod) external onlyOwner {
        require (rebalancePeriod <= REBALANCE_PERIOD_MAX, "Period > REBALANCE_PERIOD_MAX");
        _rebalancePeriod = rebalancePeriod;
    }

    function _getPooledBalances(uint256 tokenIndex) public view returns (uint256) {
        require(tokenIndex < _nTokens, "Token not exists");
        IERC20 pooledToken = IERC20(_pooledTokens[tokenIndex]);
        uint256 reserveAmount = pooledToken.balanceOf(address(this));
        uint256 ibTokenBalances = _ibTokenBalances[tokenIndex];

        uint256 pooledBalances = reserveAmount.add(ibTokenBalances);
        return pooledBalances;
    }

    function _totalBalance() public view returns (uint256) {
        uint256 totalBalance;
        for (uint256 i = 0; i < _nTokens; i++) {
            uint256 amountNormalized =
                _getPooledBalances(i)
                .mul(_normalizeBalance(i));
            totalBalance = totalBalance.add(amountNormalized);
        }
        return totalBalance;
    }

    function _getTokenIndex(address tokenAddr) public view returns (uint256) {
        require(tokenAddr != address(0), "The 0 address isn't an ERC-20");
        // Check if index is already used.
        require(_tokenExist[tokenAddr] == 1, "Token not exists");

        uint256 tokenIndex = _tokenIndexes[tokenAddr];
        return tokenIndex;
    }

    function _getTokenInfo(address tokenAddr) external view returns (
        uint256 tokenIndex,
        address pooledToken,
        address ibToken,
        bool enableIbToken,
        uint256 tokenDecimals,
        uint256 pooledBalance,
        uint256 ibTokenBalance,
        uint256 minWeight,
        uint256 maxWeight
    ) {
        tokenIndex = _getTokenIndex(tokenAddr);
        pooledToken = _pooledTokens[tokenIndex];
        ibToken = _ibTokens[tokenIndex];
        enableIbToken = _enableIbToken[tokenIndex];
        tokenDecimals = _tokenDecimals[tokenIndex];
        pooledBalance = _getPooledBalances(tokenIndex);
        ibTokenBalance = _ibTokenBalances[tokenIndex];
        minWeight = _minWeight[tokenIndex];
        maxWeight = _maxWeight[tokenIndex];
    }

    function _normalizeBalance(uint256 tokenIndex) internal view returns (uint256) {
        uint256 decm = 18 - _tokenDecimals[tokenIndex];
        return 10 ** decm;
    }

    /**************************************************************************************
     * Methods for rebalance reserve
     * After rebalancing, we will have reserve equaling to 20% of total balance
     *************************************************************************************/

    function _rebalanceReserve(
        uint256 tokenIndex
    ) internal {
        IERC20 pooledToken = IERC20(_pooledTokens[tokenIndex]);
        uint256 pooledBalance = _getPooledBalances(tokenIndex);
        uint256 reserveAmount = pooledToken.balanceOf(address(this));
        uint256 targetReserve = pooledBalance.mul(_reserveRatio).div(100);

        uint256 depositAmount;
        if (reserveAmount > targetReserve) {
            depositAmount = reserveAmount.sub(targetReserve);

            // Deposit to ibToken
            _depositIbtoken(tokenIndex, depositAmount);
        } else {
            uint256 expectedWithdraw = targetReserve.sub(reserveAmount);
            if (expectedWithdraw == 0) {
                return;
            }

            // Withdraw from ibToken
            _withdrawIbtoken(tokenIndex);
            uint256 pooledAmount = pooledToken.balanceOf(address(this));
            depositAmount = pooledAmount.sub(targetReserve);

            // Deposit back to ibToken
            _depositIbtoken(tokenIndex, depositAmount);
        }

        emit Rebalance(tokenIndex, depositAmount);
    }

    function _rebalanceReserveSubstract(
        uint256 tokenIndex,
        uint256 amountUnnormalized
    ) internal {
        uint256 newPooledBalance = _getPooledBalances(tokenIndex).sub(amountUnnormalized);
        uint256 targetReserve = newPooledBalance.mul(_reserveRatio).div(100);

        // Withdraw from ibToken
        _withdrawIbtoken(tokenIndex);

        uint256 depositAmount = newPooledBalance.sub(targetReserve);
        if (depositAmount != 0) {
            // Deposit back to ibToken
            _depositIbtoken(tokenIndex, depositAmount);
        }

        emit Rebalance(tokenIndex, depositAmount);
    }

    function _depositIbtoken(
        uint256 tokenIndex,
        uint256 toIbTokenAmount
    ) internal {
        uint256 ibTokenBalances = _ibTokenBalances[tokenIndex];
        IERC20 pooledToken = IERC20(_pooledTokens[tokenIndex]);
        IBVAULT ibToken = IBVAULT(_ibTokens[tokenIndex]);

        pooledToken.safeApprove(address(ibToken), 0);
        pooledToken.safeApprove(address(ibToken), toIbTokenAmount);

        _ibTokenBalances[tokenIndex] = ibTokenBalances.add(toIbTokenAmount);
        ibToken.deposit(toIbTokenAmount);
    }

    function _withdrawIbtoken(
        uint256 tokenIndex
    ) internal {
        uint256 ibTokenBalances = _ibTokenBalances[tokenIndex];
        IBVAULT ibToken = IBVAULT(_ibTokens[tokenIndex]);

        _ibTokenBalances[tokenIndex] = 0;
        uint256 withdrawAmounts = ibToken.withdraw();

        if (withdrawAmounts > ibTokenBalances) {
            uint256 interest = withdrawAmounts.sub(ibTokenBalances);
            uint256 interestNormalized = interest.mul(_normalizeBalance(tokenIndex));
            uint256 adminInterestFee = interestNormalized.mul(_adminInterestFee).div(100);
            uint256 interestToTheVault = interestNormalized.sub(adminInterestFee);

            if (adminInterestFee > 0) _mint(_feeCollector, adminInterestFee);
            _mint(_theVault, interestToTheVault);

            emit MintFee(_theVault, interestToTheVault, _feeCollector, adminInterestFee);
        } 
    }

    /// @dev Forcibly rebalance so that reserve is about 20% of total.
    function rebalanceReserve(
        uint256 tokenIndex
    )
        external
        nonReentrant
        whenNotPaused
    {
        require(tokenIndex < _nTokens, "Token not exists");

        uint256 blockTimestamp = block.timestamp;
        uint256 timeElapsed = blockTimestamp.sub(_lastRebalance[tokenIndex]);
        
        if (timeElapsed >= _rebalancePeriod && _enableIbToken[tokenIndex]) {
            _rebalanceReserveSubstract(tokenIndex, 0);
            _lastRebalance[tokenIndex] = blockTimestamp;
        }
    }

    /// @dev Mint with out fee for sent to the Vault.
    function _mintFee(
        uint256 tokenIndex,
        uint256 fee
    ) internal {
        uint256 stalAmount = fee.mul(_normalizeBalance(tokenIndex));

        // Fee calculation
        if (stalAmount > 0) {
            uint256 adminFee = stalAmount.mul(_adminFee).div(100);
            uint256 feeToTheVault = stalAmount.sub(adminFee);

            if (adminFee > 0) _mint(_feeCollector, adminFee);
            _mint(_theVault, feeToTheVault);

            emit MintFee(_theVault, feeToTheVault, _feeCollector, adminFee);
        }  
    }

    /// @dev Transfer the amount of token out. Rebalance the reserve if needed
    function _transferOut(
        uint256 tokenIndex,
        uint256 amountUnnormalized,
        uint256 feeUnnormalized
    )
        internal
    {
        IERC20 pooledToken = IERC20(_pooledTokens[tokenIndex]);
        uint256 reserveAmount = pooledToken.balanceOf(address(this));

        if (_enableIbToken[tokenIndex]) {
            // Check rebalance if needed
            if (amountUnnormalized > reserveAmount) {
                _rebalanceReserveSubstract(tokenIndex, amountUnnormalized);
            }
        }

        _mintFee(tokenIndex, feeUnnormalized);

        pooledToken.safeTransfer(
            msg.sender,
            amountUnnormalized
        );
    }

    /// @dev Transfer the amount of token in. Rebalance the reserve if needed
    function _transferIn(
        uint256 tokenIndex,
        uint256 amountUnnormalized
    )
        internal
    {
        IERC20 pooledToken = IERC20(_pooledTokens[tokenIndex]);

        pooledToken.safeTransferFrom(
            msg.sender,
            address(this),
            amountUnnormalized
        );

        if (_enableIbToken[tokenIndex]) {
            // Check rebalance if needed
            uint256 reserveAmount = pooledToken.balanceOf(address(this));
            uint256 maxReserveAmount = _getPooledBalances(tokenIndex).mul(_maxRatio).div(100);
            if (reserveAmount > maxReserveAmount) {
                _rebalanceReserve(tokenIndex);
            }
        }
    }

    /**************************************************************************************
     * Methods for minting
     *************************************************************************************/

    /// @dev Given the token address and the amount to be deposited, return the amount of Stal Stablecoin
    function getMintAmount(
        address tokenAddr,
        uint256 tokenAmountIn
    )
        internal
        view
        returns (uint256 stalAmountOut, uint256 fee)
    {
        uint256 tokenIndex = _getTokenIndex(tokenAddr);

        // Obtain normalized balances
        uint256 tokenAmountInNormalized = tokenAmountIn.mul(_normalizeBalance(tokenIndex));

        // Gas saving: Use cached totalBalance from _totalBalance().
        uint256 totalBalance = _totalBalance();
        uint256 pooledBalanceNormalized = _getPooledBalances(tokenIndex).mul(_normalizeBalance(tokenIndex));
        uint256 currentWeight = getRatioOf(pooledBalanceNormalized, totalBalance);
        uint256 minWeight = _minWeight[tokenIndex];
        uint256 maxWeight = _maxWeight[tokenIndex];

        // Fee calculation
        uint256 mintingfee = _mintingFee;
        if (currentWeight < minWeight) {
            mintingfee = mintingfee.div(2);
        } else if (currentWeight > maxWeight) {
            mintingfee = mintingfee.mul(2);
        }

        fee = getProductOf(tokenAmountInNormalized, mintingfee);
        stalAmountOut = tokenAmountInNormalized.sub(fee);
    }

    function getMintAmountOut(
        address tokenAddr,
        uint256 tokenAmountIn
    )
        external
        view
        returns (uint256 stalAmountOut, uint256 fee)
    {
        (stalAmountOut, fee) = getMintAmount(
            tokenAddr,
            tokenAmountIn
        );
    }

    function getMintAmountIn(
        address tokenAddr,
        uint256 stalAmountOut
    )
        external
        view
        returns (uint256 tokenAmountIn, uint256 fee)
    {
        uint256 tokenIndex = _getTokenIndex(tokenAddr);

        // Gas saving: Use cached totalBalance from _totalBalance().
        uint256 totalBalance = _totalBalance();
        uint256 pooledBalanceNormalized = _getPooledBalances(tokenIndex).mul(_normalizeBalance(tokenIndex));
        uint256 currentWeight = getRatioOf(pooledBalanceNormalized, totalBalance);
        uint256 minWeight = _minWeight[tokenIndex];
        uint256 maxWeight = _maxWeight[tokenIndex];

        // Fee calculation
        uint256 mintingfee = _mintingFee;
        if (currentWeight < minWeight) {
            mintingfee = mintingfee.div(2);
        } else if (currentWeight > maxWeight) {
            mintingfee = mintingfee.mul(2);
        }

        uint256 tokenAmountInNormalized =
        getRatioOf(
            getProductOf(
                stalAmountOut,
                PRICE_PRECISION
            ),
            PRICE_PRECISION.sub(mintingfee)
        );

        uint256 tokenAmountInUnnormalized = tokenAmountInNormalized.div(_normalizeBalance(tokenIndex));

        (, fee) = getMintAmount(
            tokenAddr,
            tokenAmountInUnnormalized
        );
        tokenAmountIn = tokenAmountInUnnormalized;
    }

    /// @dev Given the token address and the amount to be deposited, mint Stal Stablecoin
    function mint(
        address tokenAddr,
        uint256 tokenAmountIn,
        uint256 stalMintedMin
    )
        external
        nonReentrant
        whenNotPaused
        returns (uint256)
    {
        uint256 tokenIndex = _getTokenIndex(tokenAddr);
        require(tokenAmountIn > 0, "Amount must be greater than 0");
        (uint256 stalAmountOut, uint256 fee) = getMintAmount(tokenAddr, tokenAmountIn);

        require(stalAmountOut >= stalMintedMin, "STAL minted < minimum");
        
        _transferIn(tokenIndex, tokenAmountIn);

        // Fee calculation
        if (fee > 0) {
            uint256 adminFee = fee.mul(_adminFee).div(100);
            uint256 feeToTheVault = fee.sub(adminFee);

            if (adminFee > 0) _mint(_feeCollector, adminFee);
            _mint(_theVault, feeToTheVault);

            emit MintFee(_theVault, feeToTheVault, _feeCollector, adminFee);
        }

        _mint(msg.sender, stalAmountOut);

        emit Mint(msg.sender, _pooledTokens[tokenIndex], tokenAmountIn, stalAmountOut);

        return stalAmountOut;
    }

    /**************************************************************************************
     * Methods for redeeming
     *************************************************************************************/

    /// @dev Given token address and STAL amount, return the max amount of token can be withdrawn
    function getRedeemAmount(
        address tokenAddr,
        uint256 stalAmountIn
    )
        internal
        view
        returns (uint256 tokenAmountOut, uint256 fee)
    {
        uint256 tokenIndex = _getTokenIndex(tokenAddr);

        // Obtain normalized balances
        uint256 stalAmountInNormalized = stalAmountIn;

        // Gas saving: Use cached totalBalance from _totalBalance().
        uint256 totalBalance = _totalBalance();
        uint256 pooledBalanceNormalized = _getPooledBalances(tokenIndex).mul(_normalizeBalance(tokenIndex));
        uint256 currentWeight = getRatioOf(pooledBalanceNormalized, totalBalance);
        uint256 minWeight = _minWeight[tokenIndex];
        uint256 maxWeight = _maxWeight[tokenIndex];

        // Fee calculation
        uint256 redemptionfee = _redemptionFee;
        if (currentWeight < minWeight) {
            redemptionfee = redemptionfee.mul(2);
        } else if (currentWeight > maxWeight) {
            redemptionfee = redemptionfee.div(2);
        }
        uint256 feeNormalized = getProductOf(stalAmountInNormalized, redemptionfee);
        uint256 tokenAmountOutNormalized = stalAmountInNormalized.sub(feeNormalized);

        fee = feeNormalized.div(_normalizeBalance(tokenIndex));
        tokenAmountOut = tokenAmountOutNormalized.div(_normalizeBalance(tokenIndex));
    }

    function getRedeemAmountOut(
        address tokenAddr,
        uint256 stalAmountIn
    )
        external
        view
        returns (uint256 tokenAmountOut, uint256 fee)
    {
        (tokenAmountOut, fee) = getRedeemAmount(
            tokenAddr,
            stalAmountIn
        );
    }

    function getRedeemAmountIn(
        address tokenAddr,
        uint256 tokenAmountOut
    )
        external
        view
        returns (uint256 stalAmountIn, uint256 fee)
    {
        uint256 tokenIndex = _getTokenIndex(tokenAddr);

        // Obtain normalized balances
        uint256 tokenAmountOutNormalized = tokenAmountOut.mul(_normalizeBalance(tokenIndex));

        // Gas saving: Use cached totalBalance from _totalBalance().
        uint256 totalBalance = _totalBalance();
        uint256 pooledBalanceNormalized = _getPooledBalances(tokenIndex).mul(_normalizeBalance(tokenIndex));
        uint256 currentWeight = getRatioOf(pooledBalanceNormalized, totalBalance);
        uint256 minWeight = _minWeight[tokenIndex];
        uint256 maxWeight = _maxWeight[tokenIndex];

        // Fee calculation
        uint256 redemptionfee = _redemptionFee;
        if (currentWeight < minWeight) {
            redemptionfee = redemptionfee.mul(2);
        } else if (currentWeight > maxWeight) {
            redemptionfee = redemptionfee.div(2);
        }

        uint256 stalAmountInNormalized =
        getRatioOf(
            getProductOf(
                tokenAmountOutNormalized,
                PRICE_PRECISION
            ),
            PRICE_PRECISION.sub(redemptionfee)
        );

        (, fee) = getRedeemAmount(
            tokenAddr,
            stalAmountInNormalized
        );
        stalAmountIn = stalAmountInNormalized;
    }

    /// @dev Given the token address and Stal amount to be redeemed, burn Stal Stablecoin
    function redeem(
        address tokenAddr,
        uint256 stalAmountIn,
        uint256 tokenAmountOutMin
    )
        external
        nonReentrant
        whenNotPaused
        returns (uint256)
    {
        uint256 tokenIndex = _getTokenIndex(tokenAddr);
        require(stalAmountIn > 0, "Amount must be greater than 0");
        (uint256 tokenAmountOut, uint256 fee) = getRedeemAmount(tokenAddr, stalAmountIn);

        uint256 pooledBalances = _getPooledBalances(tokenIndex);
        require(tokenAmountOut <= pooledBalances, "Token amount > pool balances");
        require(tokenAmountOut >= tokenAmountOutMin, "Token amount < minimum");

        _burn(msg.sender, stalAmountIn);

        _transferOut(tokenIndex, tokenAmountOut, fee);

        emit Redeem(msg.sender, _pooledTokens[tokenIndex], stalAmountIn, tokenAmountOut);

        return tokenAmountOut;
    }

    /**************************************************************************************
     * Methods for swapping tokens
     *************************************************************************************/

    /// @dev Return the maximum amount of token can be withdrawn after depositing another token.
    function getSwapAmount(
        address tokenAddrIn,
        address tokenAddrOut,
        uint256 tokenAmountIn
    )
        internal
        view
        returns (uint256 tokenAmountOut, uint256 fee)
    {
        uint256 tokenIndexIn = _getTokenIndex(tokenAddrIn);
        uint256 tokenIndexOut = _getTokenIndex(tokenAddrOut);
        require(tokenIndexIn != tokenIndexOut, "Tokens must be different!");

        uint256 tokenAmountInNormalized = tokenAmountIn.mul(_normalizeBalance(tokenIndexIn));

        uint256 feeNormalized = getProductOf(tokenAmountInNormalized, _swapFee);
        uint256 tokenAmountOutNormalized = tokenAmountInNormalized.sub(feeNormalized);

        fee = feeNormalized.div(_normalizeBalance(tokenIndexOut));
        tokenAmountOut = tokenAmountOutNormalized.div(_normalizeBalance(tokenIndexOut));
    }

    function getSwapAmountOut(
        address tokenAddrIn,
        address tokenAddrOut,
        uint256 tokenAmountIn
    )
        external
        view
        returns (uint256 tokenAmountOut, uint256 fee)
    {
        (tokenAmountOut, fee) = getSwapAmount(
            tokenAddrIn,
            tokenAddrOut,
            tokenAmountIn
        );
    }

    function getSwapAmountIn(
        address tokenAddrIn,
        address tokenAddrOut,
        uint256 tokenAmountOut
    )
        external
        view
        returns (uint256 tokenAmountIn, uint256 fee)
    {
        uint256 tokenIndexIn = _getTokenIndex(tokenAddrIn);
        uint256 tokenIndexOut = _getTokenIndex(tokenAddrOut);
        require(tokenIndexIn != tokenIndexOut, "Tokens must be different!");

        uint256 tokenAmountOutNormalized = tokenAmountOut.mul(_normalizeBalance(tokenIndexOut));

        uint256 tokenAmountInNormalized =
        getRatioOf(
            getProductOf(
                tokenAmountOutNormalized,
                PRICE_PRECISION
            ),
            PRICE_PRECISION.sub(_swapFee)
        );

        uint256 tokenAmountIUnnormalized = tokenAmountInNormalized.div(_normalizeBalance(tokenIndexIn));

        (, fee) = getSwapAmount(
            tokenAddrIn,
            tokenAddrOut,
            tokenAmountIUnnormalized
        );
        tokenAmountIn = tokenAmountInNormalized.div(_normalizeBalance(tokenIndexIn));
    }

    /**
     * @dev Swap a token to another.
     * @param tokenAddrIn - the token address to be deposited
     * @param tokenAddrOut - the token address to be withdrawn
     * @param tokenAmountIn - the amount (unnormalized) of the token to be deposited
     * @param tokenAmountOutMin - the mininum amount (unnormalized) token that is expected to be withdrawn
     */
    function swap(
        address tokenAddrIn,
        address tokenAddrOut,
        uint256 tokenAmountIn,
        uint256 tokenAmountOutMin
    )
        external
        nonReentrant
        whenNotPaused
    {
        uint256 tokenIndexIn = _getTokenIndex(tokenAddrIn);
        uint256 tokenIndexOut = _getTokenIndex(tokenAddrOut);
        (uint256 tokenAmountOut, uint256 fee) = getSwapAmount(tokenAddrIn, tokenAddrOut, tokenAmountIn);
        require(tokenAmountOut >= tokenAmountOutMin, "Returned tokenAmountOut < asked");
        
        uint256 pooledBalances = _getPooledBalances(tokenIndexOut);
        require(tokenAmountOut <= pooledBalances, "Token amount > pool balances");

        _transferIn(tokenIndexIn, tokenAmountIn);

        _transferOut(tokenIndexOut, tokenAmountOut, fee);

        uint256 tokenAmountInNormalized = tokenAmountIn.mul(_normalizeBalance(tokenIndexIn));

        emit Swap(
            msg.sender,
            tokenAddrIn,
            tokenAddrOut,
            tokenAmountIn,
            tokenAmountOut,
            tokenAmountInNormalized
        );
    }

    function getProductOf(uint256 _amount, uint256 _multiplier)
        public
        pure
        returns (uint256)
    {
        return (_amount.mul(_multiplier)).div(PRICE_PRECISION);
    }

    function getRatioOf(uint256 _amount, uint256 _divider)
        public
        pure
        returns (uint256)
    {
        if (_divider == 0) _divider = PRICE_PRECISION;
        return
            (
                ((_amount.mul(PRICE_PRECISION)).div(_divider)).mul(
                    PRICE_PRECISION
                )
            )
                .div(PRICE_PRECISION);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }
}