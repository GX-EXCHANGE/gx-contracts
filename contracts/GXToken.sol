// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract GXToken is ERC20, ERC20Burnable, ERC20Permit, Ownable {
    constructor()
        ERC20("GX Exchange", "GX")
        ERC20Permit("GX Exchange")
        Ownable(msg.sender)
    {
        _mint(msg.sender, 1_000_000_000 * 10 ** 18);
    }
}
