// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {MetaVault} from "../src/MetaVault.sol";
import {ERC20} from "@oz/token/ERC20/ERC20.sol";
import {ERC4626} from "@oz/token/ERC20/extensions/ERC4626.sol";
import "../src/IVault.sol";

contract MetaVaultHarness is MetaVault {
    constructor(address _owner, ERC20 _CRVUSD) MetaVault(_owner, _CRVUSD) {}

    function __depositIntoVault(uint256 vaultIdx, uint256 assets) external {
        ERC20(CRVUSD).transferFrom(msg.sender, address(this), assets);
        _depositIntoVault(vaultIdx, assets);
    }

    function __assets() external view returns (uint256[] memory) {
        uint256[] memory assets = new uint256[](vaults.length);
        for (uint256 i = 0; i < vaults.length; i++) {
            uint256 vaultAssets = IVault(vaults[i].addr).convertToAssets(
                vaults[i].shares
            );
            assets[i] = vaultAssets;
        }
        return assets;
    }

    function __percentages() external view returns (uint256[] memory) {
        uint256[] memory assets = new uint256[](vaults.length);
        uint256 sumAssets = 0;
        for (uint256 i = 0; i < vaults.length; i++) {
            uint256 vaultAssets = IVault(vaults[i].addr).convertToAssets(
                vaults[i].shares
            );
            assets[i] = vaultAssets;
            sumAssets += vaultAssets;
        }

        // reuse the array
        uint256 sumPercentages = 0;
        for (uint256 i = 0; i < vaults.length - 1; i++) {
            uint256 percentage = (assets[i] * 10_000) / sumAssets;
            assets[i] = percentage;
            sumPercentages += percentage;
        }
        assets[vaults.length - 1] = 10_000 - sumPercentages;

        return assets;
    }
}

contract CounterTest is Test {
    address constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;

    address constant CRV_vault = 0xCeA18a8752bb7e7817F9AE7565328FE415C0f2cA;
    address constant USDe_vault = 0xc687141c18F20f7Ba405e45328825579fDdD3195;
    address constant WBTC_vault = 0xccd37EB6374Ae5b1f0b85ac97eFf14770e0D0063;
    address constant WETH_vault = 0x8fb1c7AEDcbBc1222325C39dd5c1D2d23420CAe3;
    address constant pufETH_vault = 0xff467c6E827ebbEa64DA1ab0425021E6c89Fbe0d;
    address constant sFRAX_vault = 0xd0c183C9339e73D7c9146D48E1111d1FBEe2D6f9;

    MetaVaultHarness mv;
    IVault[] vaults;

    address owner;
    address alice;
    address bob;
    address charlie;

    function setUp() public {
        // vm.createSelectFork("https://eth.llamarpc.com");
        vm.createSelectFork("wss://ethereum-rpc.publicnode.com");

        vm.label(CRV_vault, "CRV_vault");
        vm.label(USDe_vault, "USDe_vault");
        vm.label(WBTC_vault, "WBTC_vault");
        vm.label(WETH_vault, "WETH_vault");
        vm.label(pufETH_vault, "pufETH_vault");
        vm.label(sFRAX_vault, "sFRAX_vault");
        vm.label(CRVUSD, "CRVUSD");

        owner = makeAddr("owner");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        charlie = makeAddr("charlie");

        mv = new MetaVaultHarness(owner, ERC20(CRVUSD));
        deal(CRVUSD, alice, type(uint256).max);
        deal(CRVUSD, bob, type(uint256).max);
        deal(CRVUSD, charlie, type(uint256).max);

        // vaults.push(new MockVault(1e20, mockCrvUSD));
        // vaults.push(new MockVault(1e20, mockCrvUSD));
        // vaults.push(new MockVault(1e20, mockCrvUSD));

        vaults.push(IVault(CRV_vault));
        vaults.push(IVault(USDe_vault));
        vaults.push(IVault(WBTC_vault));
        // vaults.push(IVault(pufETH_vault));
        // vaults.push(IVault(WETH_vault));
        // vaults.push(IVault(sFRAX_vault));

        uint256[3] memory weights = [uint256(2000), 3000, 5000];
        for (uint256 i = 0; i < vaults.length; i++) {
            vm.prank(owner);
            mv.enableVault(address(vaults[i]), weights[i]);
        }
    }

    function test_deposit() public {
        vm.startPrank(alice);
        assertEq(ERC20(CRVUSD).balanceOf(address(mv)), 0);

        ERC20(CRVUSD).approve(address(mv), type(uint256).max);

        console.log(" pre-dep %e", ERC20(CRVUSD).balanceOf(address(mv)));
        mv.deposit(1e18, alice);
        console.log("post-dep %e", ERC20(CRVUSD).balanceOf(address(mv)));

        for (uint256 i = 0; i < vaults.length; i++) {
            console.log(vaults[i].maxWithdraw(address(mv)));
        }

        console.log("=====");

        for (uint256 i = 0; i < vaults.length; i++) {
            console.log(vaults[i].balanceOf(alice));
        }

        assertEq(mv.totalAssets(), 1e18 - vaults.length);

        assertEq(ERC20(CRVUSD).balanceOf(address(mv)), 0);
    }

    function test_withdraw() public {
        vm.startPrank(alice);
        assertEq(ERC20(CRVUSD).balanceOf(address(mv)), 0);

        ERC20(CRVUSD).approve(address(mv), type(uint256).max);

        uint256 shares = mv.deposit(1e5, alice);

        console.log("==== deposit done ====");
        console.log("total assets: %e", mv.totalAssets());
        uint256 maxWithdraw = mv.maxWithdraw(alice);
        uint256 maxRedeem = mv.maxRedeem(alice);
        console.log("max withdraw assets %e", maxWithdraw);
        console.log("max redeem shares %e", maxRedeem);
        console.log("==== withdrawing ====");

        mv.withdraw(maxWithdraw, alice, alice);

        for (uint256 i = 0; i < vaults.length; i++) {
            console.log("%e", vaults[i].maxWithdraw(address(mv)));
        }

        console.log("=====");

        for (uint256 i = 0; i < vaults.length; i++) {
            console.log(vaults[i].balanceOf(alice));
        }

        assertEq(mv.totalAssets(), 0);
        assertEq(ERC20(CRVUSD).balanceOf(address(mv)), 0);
    }

    function test_redeem() public {
        vm.startPrank(alice);
        assertEq(ERC20(CRVUSD).balanceOf(address(mv)), 0);

        ERC20(CRVUSD).approve(address(mv), type(uint256).max);

        uint256 shares = mv.deposit(1e5, alice);

        console.log("==== deposit done ====");
        console.log("total assets: %e", mv.totalAssets());
        uint256 maxWithdraw = mv.maxWithdraw(alice);
        uint256 maxRedeem = mv.maxRedeem(alice);
        console.log("max withdraw assets %e", maxWithdraw);
        console.log("max redeem shares %e", maxRedeem);
        console.log("==== withdrawing ====");

        mv.redeem(maxRedeem, alice, alice);

        for (uint256 i = 0; i < vaults.length; i++) {
            console.log("%e", vaults[i].maxWithdraw(address(mv)));
        }

        console.log("=====");

        for (uint256 i = 0; i < vaults.length; i++) {
            console.log(vaults[i].balanceOf(alice));
        }

        assertEq(mv.totalAssets(), 0);
        assertEq(ERC20(CRVUSD).balanceOf(address(mv)), 0);
    }

    function test_rebalance() public {
        vm.startPrank(alice);
        assertEq(ERC20(CRVUSD).balanceOf(address(mv)), 0);

        ERC20(CRVUSD).approve(address(mv), type(uint256).max);

        mv.__depositIntoVault(0, 1e5);

        console.log("before rebalance");
        uint256[] memory assets = mv.__assets();
        uint256[] memory percentages = mv.__percentages();
        for (uint256 i = 0; i < percentages.length; i++) {
            console.log(
                "vault %d assets: %e percentage: %d",
                i,
                assets[i],
                percentages[i]
            );
        }

        console.log();
        vm.startPrank(owner);
        mv.rebalance();
        console.log();

        console.log("after rebalance");
        assets = mv.__assets();
        percentages = mv.__percentages();
        for (uint256 i = 0; i < percentages.length; i++) {
            console.log(
                "vault %d assets: %e percentage: %d",
                i,
                assets[i],
                percentages[i]
            );
        }

        // TODO: add assertions
    }

    function test_multiDepositWithdraw() public {
        assertEq(ERC20(CRVUSD).balanceOf(address(mv)), 0);

        uint256 aliceDeposit = 1e5;
        uint256 bobDeposit = 2e5;
        uint256 charlieDeposit = 3e5;

        console.log("# alice deposits");
        vm.startPrank(alice);
        ERC20(CRVUSD).approve(address(mv), aliceDeposit);
        mv.deposit(aliceDeposit, alice);

        console.log("# bob deposits");
        vm.startPrank(bob);
        ERC20(CRVUSD).approve(address(mv), bobDeposit);
        mv.deposit(bobDeposit, bob);

        console.log("# charlie deposits");
        vm.startPrank(charlie);
        ERC20(CRVUSD).approve(address(mv), charlieDeposit);
        mv.deposit(charlieDeposit, charlie);

        console.log("# deposits are done");
        // TODO: assertions

        console.log("# alice withdraws");
        vm.startPrank(alice);
        uint256 aliceWithdrawal = mv.maxWithdraw(alice);
        console.log("> withdrawal amount (assets) %e", aliceWithdrawal);
        mv.withdraw(aliceWithdrawal, alice, alice);

        console.log("# bob withdraws");
        vm.startPrank(bob);
        uint256 bobWithdrawal = mv.maxWithdraw(bob);
        console.log("> withdrawal amount (assets) %e", bobWithdrawal);
        mv.withdraw(bobWithdrawal, bob, bob);

        console.log("# charlie withdraws");
        vm.startPrank(charlie);
        uint256 charlieWithdrawal = mv.maxWithdraw(charlie);
        console.log("> withdrawal amount (assets) %e", charlieWithdrawal);
        mv.withdraw(charlieWithdrawal, charlie, charlie);

        console.log("# withdrawals done");

        // TODO: assertions
    }

    // function test_multiDepositRedeem() public {
    //     assertEq(ERC20(CRVUSD).balanceOf(address(mv)), 0);

    //     uint256 aliceDeposit = 1e5;
    //     uint256 bobDeposit = 2e5;
    //     uint256 charlieDeposit = 3e5;

    //     console.log("# alice deposits");
    //     vm.startPrank(alice);
    //     ERC20(CRVUSD).approve(address(mv), aliceDeposit);
    //     mv.deposit(aliceDeposit, alice);

    //     console.log("# bob deposits");
    //     vm.startPrank(bob);
    //     ERC20(CRVUSD).approve(address(mv), bobDeposit);
    //     mv.deposit(bobDeposit, bob);

    //     console.log("# charlie deposits");
    //     vm.startPrank(charlie);
    //     ERC20(CRVUSD).approve(address(mv), charlieDeposit);
    //     mv.deposit(charlieDeposit, charlie);

    //     console.log("# deposits are done");
    //     // TODO: assertions

    //     console.log("# alice redeems");
    //     vm.startPrank(alice);
    //     uint256 aliceRedemption = mv.maxRedeem(alice);
    //     console.log("> redemption amount (shares) %e", aliceRedemption);
    //     mv.withdraw(aliceRedemption, alice, alice);

    //     console.log("# bob redeems");
    //     vm.startPrank(bob);
    //     uint256 bobRedemption = mv.maxRedeem(bob);
    //     console.log("> redemption amount (shares) %e", bobRedemption);
    //     mv.withdraw(bobRedemption, bob, bob);

    //     console.log("# charlie redeems");
    //     vm.startPrank(charlie);
    //     uint256 charlieRedemption = mv.maxRedeem(charlie);
    //     console.log("> redemption amount (shares) %e", charlieRedemption);
    //     mv.withdraw(charlieRedemption, charlie, charlie);

    //     console.log("# withdrawals done");

    //     // TODO: assertions
    // }
}
