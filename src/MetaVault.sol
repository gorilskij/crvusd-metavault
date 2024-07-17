// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IVault} from "./IVault.sol";
import {Ownable} from "@oz/access/Ownable.sol";
import {ERC4626} from "@oz/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@oz/token/ERC20/ERC20.sol";
import {Test, console} from "forge-std/Test.sol";
import {Math} from "@oz/utils/math/Math.sol";

contract MetaVault is Ownable, ERC4626 {
    ERC20 public immutable CRVUSD;

    struct Vault {
        address addr;
        uint16 target; // [0, 10_000]
        uint256 shares;
    }

    Vault[] vaults; // all enabled vaults are stored at the front
    uint256 numEnabledVaults;

    // TODO: make variable public
    function getVaults() external view returns (Vault[] memory) {
        return vaults;
    }

    uint256 lastUpdatedVault = 0;
    uint256[] cachedCurrentAssets;
    uint256 cachedSumAssets;

    // uint256[] cachedMaxDeposit;
    // uint256 cachedMaxMaxDeposit;
    // uint256 cachedMaxMaxDepositIdx;

    // one vault is updated at a time to save gas
    // function _currentAssets()
    //     internal
    //     view
    //     returns (uint256[] memory, uint256)
    // {
    //     uint256[] memory assets = new uint256[](vaults.length);
    //     uint256 sumAssets = 0;
    //     for (uint256 i = 0; i < vaults.length; ++i) {
    //         Vault memory vault = vaults[i];
    //         uint256 vaultAssets = IVault(vault.addr).convertToAssets(
    //             vault.shares
    //         );
    //         assets[i] = vaultAssets;
    //         sumAssets += vaultAssets;
    //     }
    //     return (assets, sumAssets);
    // }

    function _currentAssets() internal returns (uint256[] memory, uint256) {
        lastUpdatedVault = (lastUpdatedVault + 1) % vaults.length;

        // console.log(
        //     "trying %e - %e",
        //     cachedSumAssets,
        //     cachedCurrentAssets[lastUpdatedVault]
        // );
        cachedSumAssets -= cachedCurrentAssets[lastUpdatedVault];
        uint256 vaultAssets = IVault(vaults[lastUpdatedVault].addr)
            .convertToAssets(vaults[lastUpdatedVault].shares);
        cachedCurrentAssets[lastUpdatedVault] = vaultAssets;
        cachedSumAssets += vaultAssets;

        return (cachedCurrentAssets, cachedSumAssets);
    }

    // function _calculateMaxDepositOf(uint256 vaultIdx, uint256 depositAmount,  uint256[] memory assets, uint256 sumAssets) {
    //     // we assume this is called after _currentAssets so we don't
    //     // update `lastUpdatedVault`

    //     uint256 totalAfterDepositing = sumAssets + depositAmount;

    //         Vault memory vault = vaults[vaultIdx];
    //         if (vault.target > 0) {
    //             // TODO: use rounding instead of +1
    //             uint256 maxAssetsAfterDeposit = ((vault.target + EPSILON) *
    //                 totalAfterDepositing) /
    //                 10_000 +
    //                 1;

    //             // TODO: round up instead of +1
    //             uint256 maxDeposit = maxAssetsAfterDeposit -
    //                 Math.min(maxAssetsAfterDeposit, assets[i]) +
    //                 1;
    // }

    // TODO: setter
    uint256 public EPSILON = 200;

    constructor(
        address _owner,
        ERC20 _CRVUSD,
        // must always have at least one enabled vault
        address _firstVaultAddr
    )
        Ownable(_owner)
        ERC20("crvUSD Lending MetaVault", "metaCrvUSD")
        ERC4626(_CRVUSD)
    {
        CRVUSD = _CRVUSD;
        vaults.push(Vault(_firstVaultAddr, 10_000, 0));
        // TODO: ad-hoc approvals?
        CRVUSD.approve(_firstVaultAddr, type(uint256).max);
        cachedCurrentAssets.push(0);
    }

    function addVault(address _addr) external onlyOwner {
        for (uint256 i = 0; i < vaults.length; ++i) {
            require(_addr != vaults[i].addr, "address already exists");
        }
        vaults.push(Vault(_addr, 0, 0));
        // TODO: ad-hoc approvals?
        CRVUSD.approve(_addr, type(uint256).max);
        cachedCurrentAssets.push(0);
    }

    function setTargets(uint16[] calldata targets) external onlyOwner {
        require(
            targets.length == vaults.length,
            "wrong number of targets provided"
        );

        numEnabledVaults = 0;
        uint256 totalPercentage = 0;
        for (uint256 i = 0; i < vaults.length; ++i) {
            vaults[i].target = targets[i];
            totalPercentage += targets[i];
            if (targets[i] > 0) {
                ++numEnabledVaults;
            }
        }
        require(totalPercentage == 10_000, "targets do not add up to 10_000");

        // move all enabled vaults to the front of `vaults`
        uint256 front = 0;
        uint256 back = vaults.length - 1;
        while (front != back) {
            if (vaults[front].target > 0) {
                ++front;
            } else if (vaults[back].target == 0) {
                --back;
            } else {
                // swap
                Vault memory tmp = vaults[front];
                vaults[front] = vaults[back];
                vaults[back] = tmp;

                ++front;
            }
        }

        rebalance();
    }

    function totalAssets() public view override returns (uint256) {
        uint256 total = 0;
        for (uint256 i = 0; i < numEnabledVaults; ++i) {
            total += IVault(vaults[i].addr).maxWithdraw(address(this));
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
        // console.log("depositing %e", assets);
        _allocateDeposit(assets);
    }

    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal override {
        _deallocateWithdrawal(assets);
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    function _maxTotalWithdraw() public view returns (uint256) {
        uint256 assets = 0;
        for (uint256 i = 0; i < numEnabledVaults; ++i) {
            assets += IVault(vaults[i].addr).maxWithdraw(address(this));
        }
        return assets;
    }

    function maxWithdraw(address owner) public view override returns (uint256) {
        return Math.min(super.maxWithdraw(owner), _maxTotalWithdraw());
    }

    function _depositIntoVault(
        uint256 vaultIndex,
        uint256 assets
    ) internal returns (uint256) {
        uint256 shares = IVault(vaults[vaultIndex].addr).deposit(assets);
        vaults[vaultIndex].shares += shares;

        cachedCurrentAssets[vaultIndex] += assets;
        cachedSumAssets += assets;

        return shares;
    }

    function _withdrawFromVault(
        uint256 vaultIndex,
        uint256 assets
    ) internal returns (uint256) {
        uint256 shares = IVault(vaults[vaultIndex].addr).withdraw(assets);
        vaults[vaultIndex].shares -= shares;

        uint256 subtractFromCache = Math.min(
            cachedCurrentAssets[vaultIndex],
            assets
        );
        cachedCurrentAssets[vaultIndex] -= subtractFromCache;
        cachedSumAssets -= subtractFromCache;

        return shares;
    }

    function _redeemFromVault(
        uint256 vaultIndex,
        uint256 shares
    ) internal returns (uint256) {
        uint256 assets = IVault(vaults[vaultIndex].addr).redeem(shares);
        vaults[vaultIndex].shares -= shares;

        uint256 subtractFromCache = Math.min(
            cachedCurrentAssets[vaultIndex],
            assets
        );
        cachedCurrentAssets[vaultIndex] -= subtractFromCache;
        cachedSumAssets -= subtractFromCache;

        return assets;
    }

    function _allocateDeposit(uint256 depositAmount) internal {
        require(depositAmount > 0);

        // console.log("$ getting assets");

        uint256[] memory assets;
        uint256 totalAfterDepositing;
        (assets, totalAfterDepositing) = _currentAssets();
        totalAfterDepositing += depositAmount;

        // console.log("$ calculating max deposits");

        uint256[] memory maxDepositAssets = new uint256[](vaults.length);
        uint256 maxMaxDeposit = 0;
        uint256 maxMaxDepositIdx = 0;
        for (uint256 i = 0; i < numEnabledVaults; ++i) {
            // TODO: use rounding instead of +1
            uint256 maxAssetsAfterDeposit = ((vaults[i].target + EPSILON) *
                totalAfterDepositing) /
                10_000 +
                1;

            // TODO: round up instead of +1
            uint256 maxDeposit = maxAssetsAfterDeposit -
                Math.min(maxAssetsAfterDeposit, assets[i]) +
                1;

            if (maxDeposit >= depositAmount) {
                console.log("!! early full deposit");
                _depositIntoVault(i, depositAmount);
                return;
            }

            console.log();
            console.log("| vault %d", i);
            console.log("| current %e", assets[i]);
            console.log("| max dep %e", maxDeposit);

            maxDepositAssets[i] = maxDeposit;
            if (maxDeposit > maxMaxDeposit) {
                maxMaxDeposit = maxDeposit;
                maxMaxDepositIdx = i;
            }
        }

        console.log("$ depositing into vaults");

        uint8 touchedVaults = 1;

        uint256 depositIntoVault = Math.min(depositAmount, maxMaxDeposit);
        _depositIntoVault(maxMaxDepositIdx, depositIntoVault);
        depositAmount -= depositIntoVault;

        if (depositAmount == 0) {
            console.log("touched vaults = %d", touchedVaults);
            return;
        }

        for (uint256 i = 0; i < numEnabledVaults; ++i) {
            if (i != maxMaxDepositIdx) {
                ++touchedVaults;

                depositIntoVault = Math.min(depositAmount, maxDepositAssets[i]);
                _depositIntoVault(i, depositIntoVault);
                depositAmount -= depositIntoVault;

                console.log("> remaining: %e", depositAmount);

                if (depositAmount == 0) {
                    break;
                }
            }
        }

        console.log("touched vaults = %d", touchedVaults);
    }

    function _deallocateWithdrawal(uint256 withdrawAmount) internal {
        require(withdrawAmount > 0);

        uint256[] memory assets;
        uint256 totalAfterWithdrawing;
        (assets, totalAfterWithdrawing) = _currentAssets();
        assert(withdrawAmount <= totalAfterWithdrawing);
        totalAfterWithdrawing -= withdrawAmount;

        uint256[] memory maxRedeemShares = new uint256[](vaults.length);
        uint256[] memory maxWithdrawAssets = new uint256[](vaults.length);
        uint256 maxMaxWithdraw = 0;
        uint256 maxMaxWithdrawIdx = 0;
        for (uint256 i = 0; i < numEnabledVaults; ++i) {
            Vault memory vault = vaults[i];

            uint256 minAssetsAfterWithdrawal = ((vault.target -
                Math.min(vault.target, EPSILON)) * totalAfterWithdrawing) /
                10_000;

            uint256 minSharesAfterWithdrawal = IVault(vault.addr)
                .convertToShares(minAssetsAfterWithdrawal);

            maxRedeemShares[i] =
                vault.shares -
                Math.min(vault.shares, minSharesAfterWithdrawal);

            uint256 maxWithdrawal = IVault(vault.addr).maxWithdraw(
                address(this)
            );

            maxWithdrawAssets[i] = maxWithdrawal;
            if (maxWithdrawal > maxMaxWithdraw) {
                maxMaxWithdraw = maxWithdrawal;
                maxMaxWithdrawIdx = i;
            }
        }

        uint256 redeemFromVault = IVault(vaults[maxMaxWithdrawIdx].addr)
            .convertToShares(withdrawAmount) + 1;
        redeemFromVault = Math.min(
            redeemFromVault,
            vaults[maxMaxWithdrawIdx].shares
        );
        redeemFromVault = Math.min(
            redeemFromVault,
            maxRedeemShares[maxMaxWithdrawIdx]
        );
        uint256 withdrawnAssets = _redeemFromVault(
            maxMaxWithdrawIdx,
            redeemFromVault
        );
        withdrawAmount -= withdrawnAssets;

        if (withdrawAmount == 0) {
            return;
        }

        for (uint256 i = 0; i < numEnabledVaults; ++i) {
            Vault memory vault = vaults[i];

            if (i != maxMaxWithdrawIdx) {
                redeemFromVault =
                    IVault(vault.addr).convertToShares(withdrawAmount) +
                    1;
                redeemFromVault = Math.min(redeemFromVault, vault.shares);
                redeemFromVault = Math.min(redeemFromVault, maxRedeemShares[i]);
                withdrawnAssets = _redeemFromVault(i, redeemFromVault);
                withdrawAmount -= withdrawnAssets;

                if (withdrawAmount == 0) {
                    break;
                }
            }
        }
    }

    // TODO: don't use _deposit utility functions, instead
    //       update the whole cache in this function
    //
    // does not skip disabled vaults (target == 0)
    // this is to ensure that assets are removed from those vaults
    // when their targets are set to 0, the extra cost is
    // ok because this function is called rarely and by the owner
    function rebalance() public onlyOwner {
        uint256[] memory assets = new uint256[](vaults.length);
        uint256 sumAssets = 0;
        (assets, sumAssets) = _currentAssets();

        bool[] memory done = new bool[](vaults.length);
        uint256 totalTaken = 0;

        for (uint256 i = 0; i < vaults.length; ++i) {
            Vault memory vault = vaults[i];

            uint256 targetAmount = (vault.target * sumAssets) / 10_000;

            if (assets[i] > targetAmount) {
                uint256 take = Math.min(
                    assets[i] - targetAmount,
                    IVault(vault.addr).maxWithdraw(address(this))
                );
                _withdrawFromVault(i, take);
                totalTaken += take;

                done[i] = true;
            }
        }

        uint256 lastGivenIdx = 0;
        for (uint256 i = 0; i < vaults.length; ++i) {
            if (!done[i]) {
                uint256 targetAmount = (vaults[i].target * sumAssets) / 10_000;

                if (assets[i] < targetAmount) {
                    uint256 give = Math.min(
                        targetAmount - assets[i],
                        totalTaken
                    );
                    _depositIntoVault(i, give);
                    totalTaken -= give;
                    lastGivenIdx = i;
                }
            }
        }

        if (totalTaken > 0) {
            _depositIntoVault(lastGivenIdx, totalTaken);
        }
    }
}
