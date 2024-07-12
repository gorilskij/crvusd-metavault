// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IVault} from "./IVault.sol";
import {Ownable} from "@oz/access/Ownable.sol";
import {ERC4626} from "@oz/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@oz/token/ERC20/ERC20.sol";

contract MetaVault is Ownable, ERC4626 {
    address constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;

    struct Vault {
        address addr;
        bool enabled;
        uint256 target;
        uint256 amount;
    }

    Vault[] vaults;
    uint256 numEnabled = 0;

    uint256 constant EPSILON = ;

    constructor(
        address _owner
    )
        Ownable(_owner)
        ERC20("crvUSD Lending MetaVault", "metaCrvUSD")
        ERC4626(ERC20(CRVUSD))
    {}

    function enableVault(address _vault) external onlyOwner {
        for (uint i = 0; i < vaults.length; i++) {
            if (vaults[i].addr == _vault) {
                if (!vaults[i].enabled) {
                    vaults[i].enabled = true;
                    numEnabled++;
                }
                return;
            }
        }
        vaults.push(Vault(_vault, true));
        numEnabled++;
        ERC20(CRVUSD).approve(_vault, type(uint256).max);
    }

    function disableVault(address _vault) external onlyOwner {
        for (uint i = 0; i < vaults.length; i++) {
            if (vaults[i].addr == _vault) {
                if (vaults[i].enabled) {
                    vaults[i].enabled = false;
                    numEnabled--;
                }
                return;
            }
        }
    }
}
