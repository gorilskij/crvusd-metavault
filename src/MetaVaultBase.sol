// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IVault} from "./IVault.sol";
import {IGauge} from "./IGauge.sol";
import {Ownable} from "@oz/access/Ownable.sol";
import {Ownable2Step} from "@oz/access/Ownable2Step.sol";
import {ERC4626} from "@oz/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@oz/token/ERC20/ERC20.sol";
import {IERC20} from "@oz/interfaces/IERC20.sol";
import {Test, console} from "forge-std/Test.sol";
import {Math} from "@oz/utils/math/Math.sol";

contract MetaVaultBase is Ownable2Step, ERC4626 {
    IERC20 public immutable CRVUSD;

    error InvalidArguments();

    struct Vault {
        address addr;
        uint16 target; // [0, 10_000]
        uint256 shares;
    }

    Vault[] public vaults; // all enabled vaults are at the front
    uint256 numEnabledVaults;

    uint256 lastUpdatedVault = 0;
    uint256[] cachedCurrentAssets;
    uint256 cachedSumAssets;

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

    function _updateCurrentAssets() internal {
        lastUpdatedVault = (lastUpdatedVault + 1) % numEnabledVaults;

        cachedSumAssets -= cachedCurrentAssets[lastUpdatedVault];
        // uint256 vaultAssets = IVault(vaults[lastUpdatedVault].addr)
        // .convertToAssets(vaults[lastUpdatedVault].shares);
        uint256 vaultAssets = IVault(vaults[lastUpdatedVault].addr).maxWithdraw(
            address(this)
        );
        cachedCurrentAssets[lastUpdatedVault] = vaultAssets;
        cachedSumAssets += vaultAssets;
    }

    constructor(
        address _owner,
        address _CRVUSD,
        // must always have at least one enabled vault
        address _firstVaultAddr
    )
        Ownable(_owner)
        ERC20("crvUSD Lending MetaVault", "metaCrvUSD")
        ERC4626(ERC20(_CRVUSD))
    {
        CRVUSD = IERC20(_CRVUSD);

        vaults.push(Vault(_firstVaultAddr, 10_000, 0));
        // TODO: ad-hoc approvals?
        CRVUSD.approve(_firstVaultAddr, type(uint256).max);
        cachedCurrentAssets.push(0);
    }

    // TODO: add emergency approval revoke

    function addVault(address _addr) external onlyOwner {
        for (uint256 i = 0; i < vaults.length; ++i) {
            if (_addr == vaults[i].addr) {
                revert InvalidArguments();
            }
        }
        vaults.push(Vault(_addr, 0, 0));
        // TODO: ad-hoc approvals?
        CRVUSD.approve(_addr, type(uint256).max);
        cachedCurrentAssets.push(0);
    }

    function setTargets(uint16[] calldata targets) external onlyOwner {
        if (targets.length != vaults.length) {
            revert InvalidArguments();
        }

        numEnabledVaults = 0;
        uint256 totalPercentage = 0;
        for (uint256 i = 0; i < vaults.length; ++i) {
            vaults[i].target = targets[i];
            totalPercentage += targets[i];
            if (targets[i] > 0) {
                ++numEnabledVaults;
            }
        }
        if (totalPercentage != 10_000) {
            revert InvalidArguments();
        }

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

    function _maxTotalWithdraw() public view returns (uint256) {
        uint256 assets = 0;
        for (uint256 i = 0; i < numEnabledVaults; ++i) {
            assets += IVault(vaults[i].addr).maxWithdraw(address(this)) - 1;
        }
        return assets;
    }

    function maxWithdraw(address owner) public view override returns (uint256) {
        return Math.min(super.maxWithdraw(owner), _maxTotalWithdraw());
    }

    // does not skip disabled vaults (target == 0)
    // this is to ensure that assets are removed from those vaults
    // when their targets are set to 0, the extra cost is
    // ok because this function is called rarely and by the owner
    function rebalance() public onlyOwner {
        _updateCurrentAssets();

        bool[] memory done = new bool[](vaults.length);
        uint256 totalTaken = 0;

        for (uint256 i = 0; i < vaults.length; ++i) {
            Vault memory vault = vaults[i];

            uint256 targetAmount = (vault.target * cachedSumAssets) / 10_000;

            if (cachedCurrentAssets[i] > targetAmount) {
                uint256 take = Math.min(
                    cachedCurrentAssets[i] - targetAmount,
                    IVault(vault.addr).maxWithdraw(address(this))
                );

                uint256 shares = IVault(vaults[i].addr).withdraw(take);
                vaults[i].shares -= shares;

                totalTaken += take;
                done[i] = true;
            }
        }

        // clear cache
        cachedSumAssets = 0;

        uint256 lastGivenIdx = 0;
        for (uint256 i = 0; i < vaults.length; ++i) {
            if (!done[i]) {
                uint256 targetAmount = (vaults[i].target * cachedSumAssets) /
                    10_000;

                if (cachedCurrentAssets[i] < targetAmount) {
                    uint256 give = Math.min(
                        targetAmount - cachedCurrentAssets[i],
                        totalTaken
                    );

                    uint256 shares = IVault(vaults[i].addr).deposit(give);
                    vaults[i].shares += shares;

                    totalTaken -= give;
                    lastGivenIdx = i;
                }
            }

            // rebuild cache
            uint256 vaultAssets = IVault(vaults[i].addr).maxWithdraw(
                address(this)
            );
            cachedCurrentAssets[i] = vaultAssets;
            cachedSumAssets += vaultAssets;
        }

        // deposit whatever is remaining into the last vault
        if (totalTaken > 0) {
            uint256 shares = IVault(vaults[lastGivenIdx].addr).deposit(
                totalTaken
            );
            vaults[lastGivenIdx].shares += shares;
        }
    }
}
