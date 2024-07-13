// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IVault} from "./IVault.sol";
import {Ownable} from "@oz/access/Ownable.sol";
import {ERC4626} from "@oz/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@oz/token/ERC20/ERC20.sol";
import {Test, console} from "forge-std/Test.sol";

contract MetaVault is Ownable, ERC4626 {
    ERC20 CRVUSD;

    struct Vault {
        address addr;
        bool enabled;
        uint256 target;
        uint256 shares;
    }

    Vault[] vaults;
    uint256 numEnabled = 0;

    uint256 constant EPSILON = 200; // 2pp tolerance

    constructor(
        address _owner,
        ERC20 _CRVUSD
    )
        Ownable(_owner)
        ERC20("crvUSD Lending MetaVault", "metaCrvUSD")
        ERC4626(_CRVUSD)
    {
        console.log("mock crvUSD addr: %s", address(_CRVUSD));

        CRVUSD = _CRVUSD;
    }

    // TODO: rebalance when enabling or disabling a vault
    function enableVault(address _vault, uint256 _target) external onlyOwner {
        console.log("enable vault", _vault, _target);

        for (uint256 i = 0; i < vaults.length; i++) {
            if (vaults[i].addr == _vault) {
                if (!vaults[i].enabled) {
                    vaults[i].enabled = true;
                    vaults[i].target = _target;
                    numEnabled++;
                    CRVUSD.approve(_vault, type(uint256).max);
                }
                return;
            }
        }
        vaults.push(Vault(_vault, true, _target, 0));
        numEnabled++;
        CRVUSD.approve(_vault, type(uint256).max);
    }

    function disableVault(address _vault) external onlyOwner {
        for (uint256 i = 0; i < vaults.length; i++) {
            if (vaults[i].addr == _vault) {
                if (vaults[i].enabled) {
                    vaults[i].enabled = false;
                    numEnabled--;
                    CRVUSD.approve(_vault, 0);
                }
                return;
            }
        }

        revert("not found");
    }

    function totalAssets() public view override returns (uint256) {
        uint256 total = 0;
        for (uint256 i = 0; i < vaults.length; i++) {
            if (vaults[i].enabled) {
                total += IVault(vaults[i].addr).maxWithdraw(address(this));
            }
        }
        return total;
    }

    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    ) internal override {
        super._deposit(caller, receiver, assets, shares);
        console.log("got %e from deposit", CRVUSD.balanceOf(address(this)));
        _allocateDeposit(assets);
    }

    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal override {
        console.log("before withdrawal: %e", CRVUSD.balanceOf(address(this)));
        _deallocateWithdrawal(assets);
        console.log("after withdrawal: %e", CRVUSD.balanceOf(address(this)));

        super._withdraw(caller, receiver, owner, assets, shares);
    }

    function _depositIntoVault(uint256 vaultIndex, uint256 amount) internal {
        uint256 shares = IVault(vaults[vaultIndex].addr).deposit(amount);
        vaults[vaultIndex].shares += shares;
        console.log(
            "deposit %e (%e shares) into vault %d",
            amount,
            shares,
            vaultIndex
        );
    }

    function _withdrawFromVault(uint256 vaultIndex, uint256 amount) internal {
        console.log("TRY WITHDRAW %e", amount);
        console.log(
            "BEFORE %e",
            IVault(vaults[vaultIndex].addr).maxWithdraw(address(this))
        );
        uint256 shares = IVault(vaults[vaultIndex].addr).withdraw(amount);
        console.log(
            "AFTER %e",
            IVault(vaults[vaultIndex].addr).maxWithdraw(address(this))
        );

        vaults[vaultIndex].shares -= shares;
        console.log(
            "withdraw %e (%e shares) from vault %d",
            amount,
            shares,
            vaultIndex
        );
    }

    function _getCurrentAmounts() internal view returns (uint256[] memory) {
        uint256[] memory amounts = new uint256[](vaults.length);
        for (uint256 i = 0; i < vaults.length; i++) {
            if (vaults[i].enabled) {
                IVault vault = IVault(vaults[i].addr);
                uint256 balance = vault.balanceOf(address(this));
                if (balance > 0) {
                    amounts[i] = vault.convertToAssets(balance);
                }
            }
        }
        return amounts;
    }

    function _allocateDeposit(uint256 amount) internal {
        require(amount > 0);

        uint256[] memory currentAmounts = _getCurrentAmounts();

        // find the vault with the most space
        uint256 total = amount;
        uint256[] memory spaces = new uint256[](vaults.length);
        for (uint256 i = 0; i < vaults.length; i++) {
            if (vaults[i].enabled) {
                total += currentAmounts[i];
                spaces[i] = vaults[i].target + EPSILON;
            }
        }

        uint256 maxI = 0;
        uint256 maxV = 0;
        for (uint256 i = 0; i < vaults.length; i++) {
            if (vaults[i].enabled) {
                uint256 lhs = (spaces[i] * total) / 10_000;
                uint256 rhs = currentAmounts[i];
                if (lhs <= rhs) {
                    spaces[i] = 0;
                } else {
                    // overflow?
                    spaces[i] = lhs - rhs;

                    if (spaces[i] > maxV) {
                        maxI = i;
                        maxV = spaces[i];
                    }
                }
                console.log("space in vault %d: %e", i, spaces[i]);
            }
        }

        if (amount <= maxV) {
            _depositIntoVault(maxI, amount);
        } else {
            // deposit maxV into vault maxI
            _depositIntoVault(maxI, maxV);
            amount -= maxV;

            for (uint256 i = 0; i < vaults.length; i++) {
                if (i != maxI && vaults[i].enabled) {
                    if (amount <= spaces[i]) {
                        _depositIntoVault(i, amount);
                        break;
                    } else {
                        _depositIntoVault(i, spaces[i]);
                        amount -= spaces[i];
                    }
                }
            }
        }
    }

    function _deallocateWithdrawal(uint256 amount) internal {
        require(amount > 0);

        uint256[] memory currentAmounts = _getCurrentAmounts();

        uint256 total = 0;
        uint256[] memory spaces = new uint256[](vaults.length);
        for (uint256 i = 0; i < vaults.length; i++) {
            if (vaults[i].enabled) {
                total += currentAmounts[i];
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
                uint256 lhs = currentAmounts[i];
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
            _withdrawFromVault(maxI, amount);
        } else {
            _withdrawFromVault(maxI, maxV);
            amount -= maxV;
            for (uint256 i = 0; i < vaults.length; i++) {
                if (i != maxI && vaults[i].enabled) {
                    if (amount <= spaces[i]) {
                        _withdrawFromVault(i, amount);
                        break;
                    } else {
                        _withdrawFromVault(i, spaces[i]);
                        amount -= spaces[i];
                    }
                }
            }
        }
    }

    function rebalance() external onlyOwner {
        // // TODO: skip if the vault is empty?
        // uint256 total = 0;
        // for (uint256 i = 0; i < vaults.length; i++) {
        //     if (vaults[i].enabled) {
        //         total += vaults[i].amount;
        //     }
        // }
        // uint256[] memory targetAmounts = new uint256[](vaults.length);
        // // uint256[] memory diffs = new uint256[](vaults.length);
        // uint256[] memory posDiffs = new uint256[](vaults.length);
        // uint256[] memory negDiffs = new uint256[](vaults.length);
        // uint256 sumNegDiffs = 0;
        // for (uint256 i = 0; i < vaults.length; i++) {
        //     if (vaults[i].enabled) {
        //         targetAmounts[i] = (vaults[i].target * total) / 10_000;
        //         // diffs[i] = vaults[i].amount - targetAmounts[i];
        //         uint256 lhs = vaults[i].amount;
        //         uint256 rhs = targetAmounts[i];
        //         if (lhs >= rhs) {
        //             posDiffs[i] = lhs - rhs;
        //         } else {
        //             negDiffs[i] = rhs - lhs;
        //             sumNegDiffs += rhs - lhs;
        //         }
        //     }
        // }
        // for (uint256 i = 0; i < vaults.length; i++) {
        //     // implicitly vaults[i].enabled
        //     if (posDiffs[i] > 0) {
        //         uint256 transfer;
        //         if (posDiffs[i] < sumNegDiffs) {
        //             transfer = posDiffs[i];
        //         } else {
        //             transfer = sumNegDiffs;
        //         }
        //         // break if transfer == 0?
        //         for (uint256 j = 0; j < vaults.length; j++) {
        //             // implicitly vaults[j].enabled && i != j
        //             if (negDiffs[j] > 0) {
        //                 uint256 amount;
        //                 if (negDiffs[j] < transfer) {
        //                     amount = negDiffs[j];
        //                 } else {
        //                     amount = transfer;
        //                 }
        //                 // transfer amount from vault j to vault i
        //                 IVault(vaults[j].addr).withdraw(amount);
        //                 vaults[j].amount -= amount;
        //                 IVault(vaults[i].addr).deposit(amount);
        //                 vaults[i].amount += amount;
        //                 transfer -= amount;
        //                 negDiffs[j] -= amount;
        //                 sumNegDiffs -= amount;
        //                 if (transfer == 0) {
        //                     break;
        //                 }
        //             }
        //         }
        //     }
        // }
    }
}
