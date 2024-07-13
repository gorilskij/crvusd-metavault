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

    uint256 constant EPSILON = 200; // 2pp tolerance

    constructor(
        address _owner
    )
        Ownable(_owner)
        ERC20("crvUSD Lending MetaVault", "metaCrvUSD")
        ERC4626(ERC20(CRVUSD))
    {}

    // TODO: rebalance when enabling or disabling a vault
    function enableVault(address _vault, uint256 _target) external onlyOwner {
        for (uint256 i = 0; i < vaults.length; i++) {
            if (vaults[i].addr == _vault) {
                if (!vaults[i].enabled) {
                    vaults[i].enabled = true;
                    vaults[i].target = _target;
                    numEnabled++;
                    ERC20(CRVUSD).approve(_vault, type(uint256).max);
                }
                return;
            }
        }
        vaults.push(Vault(_vault, true, _target, 0));
        numEnabled++;
        ERC20(CRVUSD).approve(_vault, type(uint256).max);
    }

    function disableVault(address _vault) external onlyOwner {
        for (uint i = 0; i < vaults.length; i++) {
            if (vaults[i].addr == _vault) {
                if (vaults[i].enabled) {
                    vaults[i].enabled = false;
                    numEnabled--;
                    ERC20(CRVUSD).approve(_vault, 0);
                }
                return;
            }
        }

        revert("not found");
    }

    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    ) internal override {
        super._deposit(caller, receiver, assets, shares);
        _allocateDeposit(assets);
    }

    function _withdraw(
        address caller,
        address receiver,
        uint256 shares,
        uint256 assets
    ) internal override {
        super._withdraw(caller, receiver, shares, assets);
        _deallocateWithdrawal(assets);
    }

    function _allocateDeposit(uint256 amount) internal {
        require(amount > 0);

        // find the vault with the most space
        uint256 total = amount;
        uint256[] memory spaces = new uint256[](vaults.length);
        for (uint256 i = 0; i < vaults.length; i++) {
            if (vaults[i].enabled) {
                total += vaults[i].amount;
                spaces[i] = vaults[i].target + EPSILON;
            }
        }

        uint256 maxI = 0;
        uint256 maxV = 0;
        for (uint256 i = 0; i < vaults.length; i++) {
            if (vaults[i].enabled) {
                uint256 a = spaces[i] * total;
                uint256 b = vaults[i].amount;
                if (a <= b) {
                    spaces[i] = 0;
                } else {
                    // overflow?
                    spaces[i] = (spaces[i] * total) / 10_000 - vaults[i].amount;

                    if (spaces[i] > maxV) {
                        maxI = i;
                        maxV = spaces[i];
                    }
                }
            }
        }

        ERC20(CRVUSD).transferFrom(msg.sender, address(this), amount);
        if (amount <= maxV) {
            // deposit amount into vault maxI
            IVault(vaults[maxI].addr).deposit(amount);
            vaults[maxI].amount += amount;
        } else {
            // deposit maxV into vault maxI
            for (uint256 i = 0; i < vaults.length; i++) {
                if (i != maxI && vaults[i].enabled) {
                    if (amount <= spaces[i]) {
                        // deposit amount into vault i
                        IVault(vaults[i].addr).deposit(amount);
                        vaults[i].amount += amount;
                        break;
                    } else {
                        // deposit spaces[i] into vault i
                        IVault(vaults[maxI].addr).deposit(spaces[i]);
                        vaults[maxI].amount += spaces[i];
                        amount -= spaces[i];
                    }
                }
            }
        }
    }

    function _deallocateWithdrawal(uint256 amount) internal {
        require(amount > 0);

        uint256 total = 0;
        uint256[] memory spaces = new uint256[](vaults.length);
        for (uint256 i = 0; i < vaults.length; i++) {
            if (vaults[i].enabled) {
                total += vaults[i].amount;
                // TODO: overflow?
                spaces[i] = vaults[i].target - EPSILON;
            }
        }
        if (amount > total) {
            revert("bad amount");
        } else if (amount == total) {
            // drain all vaults
        } else {
            total -= amount;
        }

        uint256 maxI = 0;
        uint256 maxV = 0;
        for (uint256 i = 0; i < vaults.length; i++) {
            if (vaults[i].enabled) {
                uint256 lhs = vaults[i].amount;
                uint256 rhs = (spaces[i] * total) / 10_000;
                if (rhs >= lhs) {
                    spaces[i] = 0;
                } else {
                    spaces[i] = lhs - rhs;

                    if (spaces[i] > maxV) {
                        maxI = i;
                        maxV = spaces[i];
                    }
                }
            }
        }

        if (amount <= maxV) {
            // withdraw amount from vault maxI
            IVault(vaults[maxI].addr).withdraw(amount);
            vaults[maxI].amount -= amount;
        } else {
            // withdraw maxV from vault maxI
            IVault(vaults[maxI].addr).withdraw(maxV);
            vaults[maxI].amount -= maxV;
            amount -= maxV;

            for (uint256 i = 0; i < vaults.length; i++) {
                if (i != maxI && vaults[i].enabled) {
                    if (amount <= spaces[i]) {
                        // withdraw amount from vault i
                        IVault(vaults[i].addr).withdraw(amount);
                        vaults[i].amount -= amount;
                        break;
                    } else {
                        // withdraw spaces[i] from vault i
                        IVault(vaults[i].addr).withdraw(spaces[i]);
                        vaults[i].amount -= spaces[i];
                        amount -= spaces[i];
                    }
                }
            }
        }
    }

    function rebalance() external onlyOwner {
        // TODO: skip if the vault is empty?

        uint256 total = 0;
        for (uint256 i = 0; i < vaults.length; i++) {
            if (vaults[i].enabled) {
                total += vaults[i].amount;
            }
        }

        uint256[] memory targetAmounts = new uint256[](vaults.length);
        // uint256[] memory diffs = new uint256[](vaults.length);
        uint256[] memory posDiffs = new uint256[](vaults.length);
        uint256[] memory negDiffs = new uint256[](vaults.length);
        uint256 sumNegDiffs = 0;

        for (uint256 i = 0; i < vaults.length; i++) {
            if (vaults[i].enabled) {
                targetAmounts[i] = (vaults[i].target * total) / 10_000;
                // diffs[i] = vaults[i].amount - targetAmounts[i];
                uint256 lhs = vaults[i].amount;
                uint256 rhs = targetAmounts[i];
                if (lhs >= rhs) {
                    posDiffs[i] = lhs - rhs;
                } else {
                    negDiffs[i] = rhs - lhs;
                    sumNegDiffs += rhs - lhs;
                }
            }
        }

        for (uint256 i = 0; i < vaults.length; i++) {
            // implicitly vaults[i].enabled
            if (posDiffs[i] > 0) {
                uint256 transfer;
                if (posDiffs[i] < sumNegDiffs) {
                    transfer = posDiffs[i];
                } else {
                    transfer = sumNegDiffs;
                }

                // break if transfer == 0?

                for (uint256 j = 0; j < vaults.length; j++) {
                    // implicitly vaults[j].enabled && i != j
                    if (negDiffs[j] > 0) {
                        uint256 amount;
                        if (negDiffs[j] < transfer) {
                            amount = negDiffs[j];
                        } else {
                            amount = transfer;
                        }

                        // transfer amount from vault j to vault i
                        IVault(vaults[j].addr).withdraw(amount);
                        vaults[j].amount -= amount;
                        IVault(vaults[i].addr).deposit(amount);
                        vaults[i].amount += amount;

                        transfer -= amount;
                        negDiffs[j] -= amount;
                        sumNegDiffs -= amount;
                        if (transfer == 0) {
                            break;
                        }
                    }
                }
            }
        }
    }
}
