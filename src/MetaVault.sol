// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IVault} from "./IVault.sol";
import {Ownable} from "@oz/access/Ownable.sol";
import {ERC4626} from "@oz/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@oz/token/ERC20/ERC20.sol";
import {Test, console} from "forge-std/Test.sol";
import {Math} from "@oz/utils/math/Math.sol";

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

    // uint256 constant REBALANCE_EPSILON = 5; // 0.5pp tolerance

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

    function getEnabledVaults() external view returns (uint256[] memory) {
        uint256[] memory enabledVaults = new uint256[](vaults.length);
        uint256 count = 0;
        for (uint256 i = 0; i < vaults.length; i++) {
            if (vaults[i].enabled) {
                enabledVaults[count] = i;
                count++;
            }
        }
        uint256[] memory packed = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            packed[i] = enabledVaults[i];
        }
        return packed;
    }

    // targets must contain the same number of elements as there are
    // enabled vaults and its values must add up to 10_000
    function setTargets(
        uint256[] calldata targets,
        bool doRebalance
    ) external onlyOwner {
        uint256 ti = 0;
        uint256 total = 0;
        for (uint256 i = 0; i < vaults.length; i++) {
            if (vaults[i].enabled) {
                if (ti > targets.length) {
                    revert("too few targets provided");
                }

                vaults[i].target = targets[ti];
                total += targets[ti];
                ti++;
            }
        }
        if (ti < targets.length) {
            revert("too many targets provided");
        }
        if (total != 10_000) {
            revert("targets do not add up to 10_000");
        }

        if (doRebalance) {
            rebalance();
        }
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

    function _maxTotalWithdraw() public view returns (uint256) {
        uint256 assets = 0;
        for (uint256 i = 0; i < vaults.length; i++) {
            if (vaults[i].enabled) {
                assets += IVault(vaults[i].addr).maxWithdraw(address(this));
            }
        }
        return assets;
    }

    function maxWithdraw(address owner) public view override returns (uint256) {
        return Math.min(super.maxWithdraw(owner), _maxTotalWithdraw());
    }

    // function maxRedeem(address owner) public view override returns (uint256) {
    //     return
    //         Math.min(
    //             super.maxRedeem(owner),
    //             convertToShares(_maxTotalWithdraw())
    //         );
    // }

    function _getCurrentAmounts() internal view returns (uint256[] memory) {
        uint256[] memory amounts = new uint256[](vaults.length);
        for (uint256 i = 0; i < vaults.length; i++) {
            if (vaults[i].enabled) {
                IVault vault = IVault(vaults[i].addr);
                if (vaults[i].shares > 0) {
                    amounts[i] = vault.convertToAssets(vaults[i].shares);
                }
            }
        }
        return amounts;
    }

    function _depositIntoVault(
        uint256 vaultIndex,
        uint256 assets
    ) internal returns (uint256) {
        uint256 shares = IVault(vaults[vaultIndex].addr).deposit(assets);
        vaults[vaultIndex].shares += shares;
        console.log(
            "deposit assets %e (%e shares) into vault %d",
            assets,
            shares,
            vaultIndex
        );

        console.log("leftover: %e", CRVUSD.balanceOf(address(this)));

        // logs:
        uint256[] memory currentAmounts = _getCurrentAmounts();
        console.log();
        for (uint256 i = 0; i < vaults.length; i++) {
            console.log("current amount vault %d: %e", i, currentAmounts[i]);
        }
        console.log();

        return shares;
    }

    function _withdrawFromVault(
        uint256 vaultIndex,
        uint256 assets
    ) internal returns (uint256) {
        console.log("TRY WITHDRAW assets %e", assets);
        console.log(
            "BEFORE %e",
            IVault(vaults[vaultIndex].addr).maxWithdraw(address(this))
        );
        uint256 shares = IVault(vaults[vaultIndex].addr).withdraw(assets);
        console.log(
            "AFTER %e",
            IVault(vaults[vaultIndex].addr).maxWithdraw(address(this))
        );

        vaults[vaultIndex].shares -= shares;
        console.log(
            "withdraw assets %e (%e shares) from vault %d",
            assets,
            shares,
            vaultIndex
        );

        return shares;
    }

    function _redeemFromVault(
        uint256 vaultIndex,
        uint256 shares
    ) internal returns (uint256) {
        console.log("TRY REDEEM shares %e", shares);
        console.log(
            "BEFORE %e",
            IVault(vaults[vaultIndex].addr).maxWithdraw(address(this))
        );
        uint256 assets = IVault(vaults[vaultIndex].addr).redeem(shares);
        console.log(
            "AFTER %e",
            IVault(vaults[vaultIndex].addr).maxWithdraw(address(this))
        );

        vaults[vaultIndex].shares -= shares;
        console.log(
            "redeem shares %e (%e assets) from vault %d",
            shares,
            assets,
            vaultIndex
        );

        return assets;
    }

    // TODO: re-implement max first for the following two functions
    function _allocateDeposit(uint256 depositAmount) internal {
        require(depositAmount > 0);

        uint256[] memory assets = new uint256[](vaults.length);
        for (uint256 i = 0; i < vaults.length; i++) {
            assets[i] = IVault(vaults[i].addr).convertToAssets(
                vaults[i].shares
            );
        }

        uint256 totalAfterDepositing = 0;
        for (uint256 i = 0; i < vaults.length; i++) {
            // 0 for disabled vaults
            totalAfterDepositing += assets[i];
        }

        totalAfterDepositing += depositAmount;

        for (uint256 i = 0; i < vaults.length; i++) {
            if (vaults[i].enabled) {
                // TODO: use rounding instead of +1
                uint256 maxAssetsAfterDeposit = ((vaults[i].target + EPSILON) *
                    totalAfterDepositing) /
                    10_000 +
                    1;

                // TODO: round up instead of +1
                // uint256 maxSharesAfterDeposit = IVault(vaults[i].addr)
                //     .convertToShares(maxAssetsAfterDeposit) + 1;

                // TODO: round up instead of +1
                // uint256 maxDepositShares = maxSharesAfterDeposit -
                //     Math.min(maxSharesAfterDeposit, vaults[i].shares) + 1;

                // TODO: round up instead of +1
                uint256 maxDepositAssets = maxAssetsAfterDeposit -
                    Math.min(maxAssetsAfterDeposit, assets[i]) +
                    1;

                uint256 depositIntoVault = Math.min(
                    depositAmount,
                    maxDepositAssets
                );

                uint256 shares = _depositIntoVault(i, depositIntoVault);
                depositAmount -= depositIntoVault;

                if (depositAmount == 0) {
                    break;
                }
            }
        }
    }

    function _deallocateWithdrawal(uint256 withdrawAmount) internal {
        console.log("deallocating assets %e", withdrawAmount);

        require(withdrawAmount > 0);

        uint256[] memory assets = new uint256[](vaults.length);
        for (uint256 i = 0; i < vaults.length; i++) {
            assets[i] = IVault(vaults[i].addr).convertToAssets(
                vaults[i].shares
            );
        }

        uint256 totalAfterWithdrawing = 0;
        for (uint256 i = 0; i < vaults.length; i++) {
            // 0 for disabled vaults
            totalAfterWithdrawing += assets[i];
        }

        // TODO: revert if total < withdrawAmount
        totalAfterWithdrawing -= Math.min(
            totalAfterWithdrawing,
            withdrawAmount
        );

        for (uint256 i = 0; i < vaults.length; i++) {
            if (vaults[i].enabled) {
                uint256 minAssetsAfterWithdrawal = ((vaults[i].target -
                    Math.min(vaults[i].target, EPSILON)) *
                    totalAfterWithdrawing) / 10_000;

                uint256 minSharesAfterWithdrawal = IVault(vaults[i].addr)
                    .convertToShares(minAssetsAfterWithdrawal);

                uint256 maxRedeemShares = vaults[i].shares -
                    Math.min(vaults[i].shares, minSharesAfterWithdrawal);
                //
                //
                //
                uint256 maxWithdrawAssets = IVault(vaults[i].addr).maxWithdraw(
                    address(this)
                );
                // console.log("=begin");
                // uint256 tmp = IVault(vaults[i].addr).convertToShares(
                //     maxWithdrawAssets -
                //         Math.min(maxWithdrawAssets, withdrawAmount)
                // );
                // console.log("=tmp %e", tmp);
                // uint256 redeemFromVault = maxRedeemShares -
                //     Math.min(maxRedeemShares, tmp);
                // console.log("=end");

                // TODO: round up instead of +1
                uint256 redeemFromVault = IVault(vaults[i].addr)
                    .convertToShares(withdrawAmount) + 1;

                console.log("====");
                console.log("vault %d", i);
                console.log("-");
                console.log("want to withdraw assets %e", withdrawAmount);
                console.log("assets %e", assets[i]);
                console.log(
                    "canonical max withdraw assets %e",
                    IVault(vaults[i].addr).maxWithdraw(address(this))
                );
                console.log(
                    "canonical max withdraw assets through assets->shares->assets %e",
                    IVault(vaults[i].addr).convertToAssets(
                        IVault(vaults[i].addr).convertToShares(
                            IVault(vaults[i].addr).maxWithdraw(address(this))
                        )
                    )
                );
                console.log(
                    "min assets after withdrawal %e",
                    minAssetsAfterWithdrawal
                );
                // console.log("max withdrawal assets %e", maxWithdrawAssets);
                console.log("-");
                console.log("want to redeem shares %e", redeemFromVault);
                console.log("total shares %e", vaults[i].shares);
                console.log("max redeem shares %e", maxRedeemShares);
                console.log(
                    "canonical max redeem shares %e",
                    IVault(vaults[i].addr).maxRedeem(address(this))
                );

                redeemFromVault = Math.min(redeemFromVault, vaults[i].shares);
                redeemFromVault = Math.min(redeemFromVault, maxRedeemShares);
                // uint256 withdrawnAssets = IVault(vaults[i].addr).redeem(
                // withdrawFromVault
                // );
                uint256 withdrawnAssets = _redeemFromVault(i, redeemFromVault);
                withdrawAmount -= withdrawnAssets;

                console.log("withdrawn assets %e", withdrawnAssets);
                console.log("remaining to withdraw assets %e", withdrawAmount);

                if (withdrawAmount == 0) {
                    break;
                }
            }
        }

        console.log(
            "after deallocation, have: %e",
            ERC20(CRVUSD).balanceOf(address(this))
        );
    }

    function rebalance() public onlyOwner {
        uint256[] memory assets = new uint256[](vaults.length);
        uint256 sumAssets = 0;
        for (uint256 i = 0; i < vaults.length; i++) {
            // 0 for disabled vaults
            uint256 vaultAssets = IVault(vaults[i].addr).convertToAssets(
                vaults[i].shares
            );
            assets[i] = vaultAssets;
            sumAssets += vaultAssets;
        }

        bool[] memory done = new bool[](vaults.length);
        uint256 totalTaken = 0;

        console.log("=== TAKING ===");
        for (uint256 i = 0; i < vaults.length; i++) {
            if (vaults[i].enabled) {
                uint256 targetAmount = (vaults[i].target * sumAssets) / 10_000;

                console.log(
                    "target amount for vault %d is %e",
                    i,
                    targetAmount
                );

                if (assets[i] > targetAmount) {
                    uint256 take = Math.min(
                        assets[i] - targetAmount,
                        IVault(vaults[i].addr).maxWithdraw(address(this))
                    );
                    // IVault(vaults[i].addr).withdraw(take);
                    _withdrawFromVault(i, take);
                    totalTaken += take;

                    console.log("take %e assets from vault %d", take, i);
                    done[i] = true;
                }
            } else {
                done[i] = true;
            }
        }

        console.log("=== GIVING ===");
        uint256 lastGivenIdx = 0;
        for (uint256 i = 0; i < vaults.length; i++) {
            if (!done[i]) {
                uint256 targetAmount = (vaults[i].target * sumAssets) / 10_000;

                console.log(
                    "target amount for vault %d is %e",
                    i,
                    targetAmount
                );

                if (assets[i] < targetAmount) {
                    uint256 give = Math.min(
                        targetAmount - assets[i],
                        totalTaken
                    );
                    // IVault(vaults[i].addr).deposit(give);
                    _depositIntoVault(i, give);
                    totalTaken -= give;
                    lastGivenIdx = i;

                    console.log("give %e assets to vault %d", give, i);
                }
            }
        }

        if (totalTaken > 0) {
            // IVault(vaults[lastGivenIdx].addr).deposit(totalTaken);
            _depositIntoVault(lastGivenIdx, totalTaken);
            console.log(
                "give residual %e assets to vault %d",
                totalTaken,
                lastGivenIdx
            );
        }
    }
}
