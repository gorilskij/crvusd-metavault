// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IVault} from "./IVault.sol";
import {Ownable} from "@oz/access/Ownable.sol";
import {ERC20} from "@oz/token/ERC20/ERC20.sol";
import {Test, console} from "forge-std/Test.sol";
import {Math} from "@oz/utils/math/Math.sol";
import {MetaVaultBase} from "./MetaVaultBase.sol";

contract MetaVault is MetaVaultBase {
    error TooManyDeposits();

    uint256 public maxDeviation;

    function setMaxDeviation(uint256 _maxDeviation) external onlyOwner {
        if (_maxDeviation < 100 || _maxDeviation > 5000) {
            revert InvalidArguments();
        }

        maxDeviation = _maxDeviation;
    }

    uint256 public maxTotalDeposits;

    function increaseMaxTotalDeposits(uint256 _delta) external onlyOwner {
        maxTotalDeposits += _delta;
    }

    constructor(
        address _owner,
        ERC20 _CRVUSD,
        address _firstVaultAddr,
        uint256 _maxDeviation,
        uint256 _maxDeposits
    ) MetaVaultBase(_owner, _CRVUSD, _firstVaultAddr) {
        maxDeviation = _maxDeviation;
        maxTotalDeposits = _maxDeposits;
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

    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    ) internal override {
        if (cachedSumAssets + assets > maxTotalDeposits) {
            revert TooManyDeposits();
        }

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
        console.log("withdrawing %e", assets);
        _deallocateWithdrawal(assets);
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    function _allocateDeposit(uint256 depositAmount) internal {
        if (depositAmount == 0) {
            revert InvalidArguments();
        }

        // console.log("$ getting assets");

        _updateCurrentAssets();
        uint256 totalAfterDepositing = cachedSumAssets + depositAmount;

        // console.log("$ calculating max deposits");

        uint256[] memory maxDepositAssets = new uint256[](vaults.length);
        uint256 maxMaxDeposit = 0;
        uint256 maxMaxDepositIdx = 0;
        for (uint256 i = 0; i < numEnabledVaults; ++i) {
            uint256 maxAssetsAfterDeposit = ((vaults[i].target + maxDeviation) *
                totalAfterDepositing) /
                10_000 +
                1;

            uint256 maxDeposit = maxAssetsAfterDeposit -
                Math.min(maxAssetsAfterDeposit, cachedCurrentAssets[i]) +
                1;

            if (maxDeposit >= depositAmount) {
                console.log("!! early full deposit");
                _depositIntoVault(i, depositAmount);
                return;
            }

            console.log();
            console.log("| vault %d", i);
            console.log("| current %e", cachedCurrentAssets[i]);
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
        if (withdrawAmount == 0) {
            revert InvalidArguments();
        }

        console.log("updating current assets");
        _updateCurrentAssets();
        uint256 totalAfterWithdrawing = cachedSumAssets -
            Math.min(cachedSumAssets, withdrawAmount);

        console.log("calculating max redeems");
        uint256[] memory maxRedeemShares = new uint256[](vaults.length);
        uint256[] memory maxWithdrawAssets = new uint256[](vaults.length);
        uint256 maxMaxWithdraw = 0;
        uint256 maxMaxWithdrawIdx = 0;
        for (uint256 i = 0; i < numEnabledVaults; ++i) {
            Vault memory vault = vaults[i];

            uint256 minAssetsAfterWithdrawal = ((vault.target -
                Math.min(vault.target, maxDeviation)) * totalAfterWithdrawing) /
                10_000;

            // uint256 minSharesAfterWithdrawal = IVault(vault.addr)
            //     .convertToShares(minAssetsAfterWithdrawal);

            // uint256 maxRedemption = vault.shares -
            //     Math.min(vault.shares, minSharesAfterWithdrawal);
            // maxRedeemShares[i] = maxRedemption;

            // uint256 maxWithdrawal = IVault(vault.addr).maxWithdraw(
            // address(this)
            // );
            // uint256 maxWithdrawal = IVault(vault.addr).convertToAssets(
            //     maxRedemption
            // );

            // TODO: how to safely use cache here?
            uint256 currentAssets = IVault(vault.addr).maxWithdraw(
                address(this)
            );
            uint256 maxWithdrawal = currentAssets -
                Math.min(currentAssets, minAssetsAfterWithdrawal);

            if (withdrawAmount <= maxWithdrawal) {
                _withdrawFromVault(i, withdrawAmount);
                return;
            }

            maxWithdrawAssets[i] = maxWithdrawal;
            if (maxWithdrawal > maxMaxWithdraw) {
                maxMaxWithdraw = maxWithdrawal;
                maxMaxWithdrawIdx = i;
            }
        }

        console.log("withdrawing max (vault %d)", maxMaxWithdrawIdx);
        console.log("- withdrawAmount: %e", withdrawAmount);
        uint256 withdrawFromVault = Math.min(withdrawAmount, maxMaxWithdraw);
        console.log("- withdrawFromVault: %e", withdrawFromVault);
        uint256 shares = _withdrawFromVault(
            maxMaxWithdrawIdx,
            withdrawFromVault
        );
        console.log("- shares: %e", shares);
        vaults[maxMaxWithdrawIdx].shares -= Math.min(
            vaults[maxMaxWithdrawIdx].shares,
            shares
        );
        console.log("- remaining shares: %e", vaults[maxMaxWithdrawIdx].shares);
        withdrawAmount -= withdrawFromVault;
        console.log(
            "- remaining in vault: %e",
            IVault(vaults[maxMaxWithdrawIdx].addr).balanceOf(address(this))
        );
        console.log("- remaining amount: %e", withdrawAmount);

        // uint256 redeemFromVault = IVault(vaults[maxMaxWithdrawIdx].addr)
        //     .convertToShares(withdrawAmount) + 1;
        // redeemFromVault = Math.min(
        //     redeemFromVault,
        //     vaults[maxMaxWithdrawIdx].shares
        // );
        // redeemFromVault = Math.min(
        //     redeemFromVault,
        //     maxRedeemShares[maxMaxWithdrawIdx]
        // );
        // uint256 withdrawnAssets = _redeemFromVault(
        //     maxMaxWithdrawIdx,
        //     redeemFromVault
        // );
        // withdrawAmount -= withdrawnAssets;

        if (withdrawAmount == 0) {
            return;
        }

        for (uint256 i = 0; i < numEnabledVaults; ++i) {
            if (i != maxMaxWithdrawIdx) {
                console.log("withdrawing vault %d", i);

                // redeemFromVault =
                //     IVault(vault.addr).convertToShares(withdrawAmount) +
                //     1;
                // redeemFromVault = Math.min(redeemFromVault, vault.shares);
                // redeemFromVault = Math.min(
                //     redeemFromVault,
                //     maxRedeemShares[i]
                // );
                // withdrawnAssets = _redeemFromVault(i, redeemFromVault);
                // withdrawAmount -= withdrawnAssets;

                console.log("- withdrawAmount: %e", withdrawAmount);
                withdrawFromVault = Math.min(
                    withdrawAmount,
                    maxWithdrawAssets[i]
                );
                console.log("- withdrawFromVault: %e", withdrawFromVault);
                shares = _withdrawFromVault(i, withdrawFromVault);
                console.log("- shares: %e", shares);
                vaults[i].shares -= Math.min(vaults[i].shares, shares);
                console.log(
                    "- remaining shares: %e",
                    vaults[maxMaxWithdrawIdx].shares
                );
                withdrawAmount -= withdrawFromVault;
                console.log(
                    "- remaining in vault: %e",
                    IVault(vaults[i].addr).balanceOf(address(this))
                );
                console.log("- remaining amount: %e", withdrawAmount);

                if (withdrawAmount == 0) {
                    break;
                }
            }
        }
    }
}
