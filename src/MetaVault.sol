// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IVault} from "./IVault.sol";
import {Ownable} from "@oz/access/Ownable.sol";
import {ERC4626} from "@oz/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@oz/token/ERC20/ERC20.sol";
import {Test, console} from "forge-std/Test.sol";
import {Math} from "@oz/utils/math/Math.sol";
import {MetaVaultBase} from "./MetaVaultBase.sol";

contract MetaVault is MetaVaultBase {
    constructor(
        address _owner,
        ERC20 _CRVUSD,
        address _firstVaultAddr
    ) MetaVaultBase(_owner, _CRVUSD, _firstVaultAddr) {}

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

    function _allocateDeposit(uint256 depositAmount) internal {
        require(depositAmount > 0);

        // console.log("$ getting assets");

        _updateCurrentAssets();
        uint256 totalAfterDepositing = cachedSumAssets + depositAmount;

        // console.log("$ calculating max deposits");

        uint256[] memory maxDepositAssets = new uint256[](vaults.length);
        uint256 maxMaxDeposit = 0;
        uint256 maxMaxDepositIdx = 0;
        for (uint256 i = 0; i < numEnabledVaults; ++i) {
            uint256 maxAssetsAfterDeposit = ((vaults[i].target + EPSILON) *
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
        require(withdrawAmount > 0);

        _updateCurrentAssets();
        uint256 totalAfterWithdrawing = cachedSumAssets -
            Math.min(cachedSumAssets, withdrawAmount);

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
}
