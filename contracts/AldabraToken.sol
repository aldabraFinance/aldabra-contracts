// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract AldabraToken is ERC20 {
    using SafeMath for uint256;

    string private constant name_ = "Aldabra Token";
    string private constant symbol_ = "ALDABRA";
    uint256 private constant total_supply = 100 * 10**6 * 10**18; // 100m will be mited at genesis.

    constructor() ERC20(name_, symbol_) public {
        _setupDecimals(18);
        _mint(msg.sender, total_supply);
    }
}