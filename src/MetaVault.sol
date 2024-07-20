// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IVault} from "./IVault.sol";
import {Ownable} from "@oz/access/Ownable.sol";
import {IERC20} from "@oz/interfaces/IERC20.sol";
import {Test, console} from "forge-std/Test.sol";
import {Math} from "@oz/utils/math/Math.sol";
import {MetaVaultBase} from "./MetaVaultBase.sol";

function floorSub(uint256 a, uint256 b) pure returns (uint256) {
    return a - Math.min(a, b);
}

contract MetaVault is MetaVaultBase {
    error TooManyDeposits();

    uint256 public maxDeviation;

    function setMaxDeviation(uint256 _maxDeviation) external onlyOwner {
        if (_maxDeviation < 100 || _maxDeviation > 5000) {
            revert InvalidArguments();
        }

        maxDeviation = _maxDeviation;
    }

    // TODO: override previewDeposit

    uint256 public maxTotalDeposits;

    function increaseMaxTotalDeposits(uint256 _delta) external onlyOwner {
        maxTotalDeposits += _delta;
    }

    function maxDeposit(
        address
    ) public view virtual override returns (uint256) {
        // WARNING: this is exact iff cachedSumAssets is exact
        return maxTotalDeposits - cachedSumAssets;
    }

    constructor(
        address _owner,
        address _CRVUSD,
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
        uint256 shares = vaults[vaultIndex].vault.deposit(assets);

        cachedCurrentAssets[vaultIndex] += assets;
        cachedSumAssets += assets;

        return shares;
    }

    function _withdrawFromVault(
        uint256 vaultIndex,
        uint256 assets
    ) internal returns (uint256) {
        uint256 shares = vaults[vaultIndex].vault.withdraw(assets);
        console.log("a");

        uint256 subtractFromCache = Math.min(
            cachedCurrentAssets[vaultIndex],
            assets
        );
        console.log("b");
        cachedCurrentAssets[vaultIndex] -= subtractFromCache;
        console.log("c");
        cachedSumAssets -= subtractFromCache;

        return shares;
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
        _allocate(assets);
    }

    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal override {
        console.log("withdrawing %e", assets);
        _deallocate(assets);
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    function _allocate(uint256 depositAmount) internal {
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
            // Maximum assets this vault should have after we do the deposit
            // to ensure that targets are respected. Adding 1 will overestimate
            // the amount of assets we can deposit ensuring we will be able
            // to spread the total deposit amount over all vaults in the worst
            // case
            uint256 maxAssetsAfterDeposit = ((vaults[i].target + maxDeviation) *
                totalAfterDepositing) /
                10_000 +
                1;

            // Again, adding 1 ensures that we will leave enough space to deposit
            // the full deposit amount in the worst case
            uint256 maxDepositAmount = floorSub(
                maxAssetsAfterDeposit,
                cachedCurrentAssets[i]
            ) + 1;

            // If we can deposit just into this vault without violating the
            // target constraints, we do that and exit early
            if (depositAmount <= maxDepositAmount) {
                console.log("!! early full deposit");
                _depositIntoVault(i, depositAmount);
                return;
            }

            maxDepositAssets[i] = maxDepositAmount;
            if (maxDepositAmount > maxMaxDeposit) {
                maxMaxDeposit = maxDepositAmount;
                maxMaxDepositIdx = i;
            }
        }

        console.log("$ depositing into vaults");

        uint8 touchedVaults = 1;

        // We already know that maxMaxDeposit < depositAmount
        uint256 depositIntoVault = maxMaxDeposit;
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

    function _deallocate(uint256 withdrawAmount) internal {
        if (withdrawAmount == 0) {
            revert InvalidArguments();
        }

        console.log("updating current assets");
        _updateCurrentAssets();
        uint256 totalAfterWithdrawing = cachedSumAssets -
            Math.min(cachedSumAssets, withdrawAmount);

        console.log("calculating max redeems");
        // uint256[] memory maxRedeemShares = new uint256[](vaults.length);
        uint256[] memory maxWithdrawAssets = new uint256[](vaults.length);
        uint256 maxMaxWithdraw = 0;
        uint256 maxMaxWithdrawIdx = 0;
        for (uint256 i = 0; i < numEnabledVaults; ++i) {
            Vault memory vault = vaults[i];

            // Minimum assets this vault should have after we do the withdrawal
            // to ensure that targets are respected. Flooring will overestimate
            // the amount of assets we can withdraw ensuring we will be able to
            // split the total withdrawal amount over all vaults in the worst
            // case
            uint256 minAssetsAfterWithdrawal = (floorSub(
                vault.target,
                maxDeviation
            ) * totalAfterWithdrawing) / 10_000;

            uint256 maxWithdrawal = floorSub(
                vault.vault.maxWithdraw(address(this)),
                minAssetsAfterWithdrawal
            );

            // If we can withdraw just from this vault without violating the
            // target constraints, we do that and exit early
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
        // We already know that maxMaxWithdraw < withdrawAmount
        uint256 withdrawFromVault = maxMaxWithdraw;
        console.log("- withdrawFromVault: %e", withdrawFromVault);
        uint256 shares = _withdrawFromVault(
            maxMaxWithdrawIdx,
            withdrawFromVault
        );
        console.log("- shares: %e", shares);
        withdrawAmount -= withdrawFromVault;
        console.log(
            "- remaining in vault: %e",
            vaults[maxMaxWithdrawIdx].vault.balanceOf(address(this))
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
                withdrawAmount -= withdrawFromVault;
                console.log(
                    "- remaining in vault: %e",
                    vaults[i].vault.balanceOf(address(this))
                );
                console.log("- remaining amount: %e", withdrawAmount);

                if (withdrawAmount == 0) {
                    break;
                }
            }
        }
    }
}
