// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

interface IVault {
  /// @dev Return the total ERC20 entitled to the token holders. Be careful of unaccrued interests.
  function totalToken() external view returns (uint256);

  /// @dev Add more ERC20 to the bank. Hope to get some good returns.
  function deposit(uint256 amountToken) external payable;

  /// @dev Withdraw ERC20 from the bank by burning the share tokens.
  function withdraw(uint256 share) external;

  /// @dev Request funds from user through Vault
  function requestFunds(address targetedToken, uint amount) external;
}

contract alpacaVault is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;
    
    address public asset;
    address public ibAsset;
    address public constSwap;

    // MODIFIERS
    modifier onlyConstSwap {
        require(_msgSender() == constSwap, "!constSwap");
        _;
    }

    // Constructor
    constructor(
        address _asset,
        address _ibAsset,
        address _constSwap
    ) public {
        require(_asset != address(0), "Invalid _asset address");
        require(_ibAsset != address(0), "Invalid _ibAsset address");
        require(_constSwap != address(0), "Invalid _constSwap address");
        asset = _asset;
        ibAsset = _ibAsset;
        constSwap = _constSwap;
    }
    
    // constSwap functions
    function deposit(uint256 _amount) external nonReentrant onlyConstSwap {
        require(_amount != 0, "amount = 0");
        
        IERC20 _asset = IERC20(asset);

        //step 1. transfer BUSD from constSwap to vault
        _asset.safeTransferFrom(msg.sender, address(this), _amount);
        uint256 depositAmount = _asset.balanceOf(address(this));
        
        //step 2. deposit BUSD to ibBUSD
        _asset.safeApprove(address(ibAsset), 0);
        _asset.safeApprove(address(ibAsset), depositAmount);
        IVault(ibAsset).deposit(depositAmount); // invest everything in ibVault

        emit Deposited(_amount);
    }

    function withdraw() external nonReentrant onlyConstSwap returns (uint256) {
        IERC20 _asset = IERC20(asset);
        IERC20 _ibAsset = IERC20(ibAsset);
 
        uint256 ibBalance = _ibAsset.balanceOf(address(this));
        
        //step 1. withdraw from ibBUSD to BUSD
        IVault(ibAsset).withdraw(ibBalance); //withdraw to BUSD
        uint256 withdrawnAmount = _asset.balanceOf(address(this)); //withdraw everything in vault
        
        //step 2. transfer BUSD back to constSwap
        _asset.safeTransfer(constSwap, withdrawnAmount);
        
        emit Withdrawn(withdrawnAmount);

        return withdrawnAmount;
    }

    function getIbAssetBalance() public view returns (uint256) {
        IERC20 _ibAsset = IERC20(ibAsset);

        return _ibAsset.balanceOf(address(this));
    }
    
    // events
    event Deposited(uint256 amount);
    event Withdrawn(uint256 amount);
}
