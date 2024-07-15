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
        uint256 target;
        uint256 shares;
    }

    Vault[] public vaults;

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
        CRVUSD = _CRVUSD;
    }

    function addVault(address _addr) external onlyOwner {
        for (uint256 i = 0; i < vaults.length; i++) {
            require(_addr != vaults[i].addr, "address already exists");
        }
        vaults.push(Vault(_addr, 0, 0));
        CRVUSD.approve(_addr, type(uint256).max);
    }

    // targets must contain the same number of elements as there are
    // enabled vaults and its values must add up to 10_000
    function setTargets(uint256[] calldata targets) external onlyOwner {
        require(
            targets.length == vaults.length,
            "wrong number of targets provided"
        );

        uint256 totalPercentage = 0;
        for (uint256 i = 0; i < vaults.length; i++) {
            vaults[i].target = targets[i];
            totalPercentage += targets[i];
        }
        require(totalPercentage == 10_000, "targets do not add up to 10_000");
        rebalance();
    }

    function totalAssets() public view override returns (uint256) {
        uint256 total = 0;
        for (uint256 i = 0; i < vaults.length; i++) {
            if (vaults[i].target > 0) {
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
        for (uint256 i = 0; i < vaults.length; i++) {
            if (vaults[i].target > 0) {
                assets += IVault(vaults[i].addr).maxWithdraw(address(this));
            }
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
        return shares;
    }

    function _withdrawFromVault(
        uint256 vaultIndex,
        uint256 assets
    ) internal returns (uint256) {
        uint256 shares = IVault(vaults[vaultIndex].addr).withdraw(assets);
        vaults[vaultIndex].shares -= shares;
        return shares;
    }

    function _redeemFromVault(
        uint256 vaultIndex,
        uint256 shares
    ) internal returns (uint256) {
        uint256 assets = IVault(vaults[vaultIndex].addr).redeem(shares);
        vaults[vaultIndex].shares -= shares;
        return assets;
    }

    function _currentAssets()
        internal
        view
        returns (uint256[] memory, uint256)
    {
        uint256[] memory assets = new uint256[](vaults.length);
        uint256 sumAssets = 0;
        for (uint256 i = 0; i < vaults.length; i++) {
            uint256 vaultAssets = IVault(vaults[i].addr).convertToAssets(
                vaults[i].shares
            );
            assets[i] = vaultAssets;
            sumAssets += vaultAssets;
        }
        return (assets, sumAssets);
    }

    function _allocateDeposit(uint256 depositAmount) internal {
        require(depositAmount > 0);

        uint256[] memory assets;
        uint256 totalAfterDepositing;
        (assets, totalAfterDepositing) = _currentAssets();
        totalAfterDepositing += depositAmount;

        uint256[] memory maxDepositAssets = new uint256[](vaults.length);
        uint256 maxMaxDeposit = 0;
        uint256 maxMaxDepositIdx = 0;
        for (uint256 i = 0; i < vaults.length; i++) {
            if (vaults[i].target > 0) {
                // TODO: use rounding instead of +1
                uint256 maxAssetsAfterDeposit = ((vaults[i].target + EPSILON) *
                    totalAfterDepositing) /
                    10_000 +
                    1;

                // TODO: round up instead of +1
                uint256 maxDeposit = maxAssetsAfterDeposit -
                    Math.min(maxAssetsAfterDeposit, assets[i]) +
                    1;

                maxDepositAssets[i] = maxDeposit;
                if (maxDeposit > maxMaxDeposit) {
                    maxMaxDeposit = maxDeposit;
                    maxMaxDepositIdx = i;
                }
            }
        }

        uint256 depositIntoVault = Math.min(depositAmount, maxMaxDeposit);
        uint256 shares = _depositIntoVault(maxMaxDepositIdx, depositIntoVault);
        depositAmount -= depositIntoVault;

        if (depositAmount == 0) {
            return;
        }

        for (uint256 i = 0; i < vaults.length; i++) {
            if (i != maxMaxDepositIdx && vaults[i].target > 0) {
                depositIntoVault = Math.min(depositAmount, maxDepositAssets[i]);
                shares = _depositIntoVault(i, depositIntoVault);
                depositAmount -= depositIntoVault;

                if (depositAmount == 0) {
                    break;
                }
            }
        }
    }

    function _deallocateWithdrawal(uint256 withdrawAmount) internal {
        require(withdrawAmount > 0);

        uint256[] memory assets;
        uint256 totalAfterWithdrawing;
        (assets, totalAfterWithdrawing) = _currentAssets();

        if (withdrawAmount <= totalAfterWithdrawing) {
            totalAfterWithdrawing -= withdrawAmount;
        } else {
            revert(
                "exceeded max withdrawal amount, this should have been caught earlier"
            );
        }

        uint256[] memory maxRedeemShares = new uint256[](vaults.length);
        uint256[] memory maxWithdrawAssets = new uint256[](vaults.length);
        uint256 maxMaxWithdraw = 0;
        uint256 maxMaxWithdrawIdx = 0;
        for (uint256 i = 0; i < vaults.length; i++) {
            if (vaults[i].target > 0) {
                uint256 minAssetsAfterWithdrawal = ((vaults[i].target -
                    Math.min(vaults[i].target, EPSILON)) *
                    totalAfterWithdrawing) / 10_000;

                uint256 minSharesAfterWithdrawal = IVault(vaults[i].addr)
                    .convertToShares(minAssetsAfterWithdrawal);

                maxRedeemShares[i] =
                    vaults[i].shares -
                    Math.min(vaults[i].shares, minSharesAfterWithdrawal);

                uint256 maxWithdrawal = IVault(vaults[i].addr).maxWithdraw(
                    address(this)
                );

                maxWithdrawAssets[i] = maxWithdrawal;
                if (maxWithdrawal > maxMaxWithdraw) {
                    maxMaxWithdraw = maxWithdrawal;
                    maxMaxWithdrawIdx = i;
                }
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

        for (uint256 i = 0; i < vaults.length; i++) {
            if (i != maxMaxWithdrawIdx && vaults[i].target > 0) {
                redeemFromVault =
                    IVault(vaults[i].addr).convertToShares(withdrawAmount) +
                    1;
                redeemFromVault = Math.min(redeemFromVault, vaults[i].shares);
                redeemFromVault = Math.min(redeemFromVault, maxRedeemShares[i]);
                withdrawnAssets = _redeemFromVault(i, redeemFromVault);
                withdrawAmount -= withdrawnAssets;

                if (withdrawAmount == 0) {
                    break;
                }
            }
        }
    }

    function rebalance() public onlyOwner {
        uint256[] memory assets = new uint256[](vaults.length);
        uint256 sumAssets = 0;
        (assets, sumAssets) = _currentAssets();

        bool[] memory done = new bool[](vaults.length);
        uint256 totalTaken = 0;

        for (uint256 i = 0; i < vaults.length; i++) {
            uint256 targetAmount = (vaults[i].target * sumAssets) / 10_000;

            if (assets[i] > targetAmount) {
                uint256 take = Math.min(
                    assets[i] - targetAmount,
                    IVault(vaults[i].addr).maxWithdraw(address(this))
                );
                _withdrawFromVault(i, take);
                totalTaken += take;

                done[i] = true;
            }
        }

        uint256 lastGivenIdx = 0;
        for (uint256 i = 0; i < vaults.length; i++) {
            if (!done[i]) {
                uint256 targetAmount = (vaults[i].target * sumAssets) / 10_000;

                if (assets[i] < targetAmount) {
                    uint256 give = Math.min(
                        targetAmount - assets[i],
                        totalTaken
                    );
                    // IVault(vaults[i].addr).deposit(give);
                    _depositIntoVault(i, give);
                    totalTaken -= give;
                    lastGivenIdx = i;
                }
            }
        }

        if (totalTaken > 0) {
            // IVault(vaults[lastGivenIdx].addr).deposit(totalTaken);
            _depositIntoVault(lastGivenIdx, totalTaken);
        }
    }
}
