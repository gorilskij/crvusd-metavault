// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {MetaVault} from "../src/MetaVault.sol";
import {ERC20} from "@oz/token/ERC20/ERC20.sol";
import "../src/IVault.sol";

contract CounterTest is Test {
    address constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;

    address constant CRV_vault = 0xCeA18a8752bb7e7817F9AE7565328FE415C0f2cA;
    address constant USDe_vault = 0xc687141c18F20f7Ba405e45328825579fDdD3195;
    address constant WBTC_vault = 0xccd37EB6374Ae5b1f0b85ac97eFf14770e0D0063;
    address constant WETH_vault = 0x8fb1c7AEDcbBc1222325C39dd5c1D2d23420CAe3;
    address constant pufETH_vault = 0xff467c6E827ebbEa64DA1ab0425021E6c89Fbe0d;
    address constant sFRAX_vault = 0xd0c183C9339e73D7c9146D48E1111d1FBEe2D6f9;

    MetaVault mv;
    IVault[] vaults;
    address alice;
    address owner;

    function setUp() public {
        vm.createSelectFork("https://rpc.ankr.com/eth");
        vm.label(CRV_vault, "CRV_vault");
        vm.label(USDe_vault, "USDe_vault");
        vm.label(WBTC_vault, "WBTC_vault");
        vm.label(WETH_vault, "WETH_vault");
        vm.label(pufETH_vault, "pufETH_vault");
        vm.label(sFRAX_vault, "sFRAX_vault");
        vm.label(CRVUSD, "CRVUSD");

        alice = makeAddr("alice");
        owner = makeAddr("owner");
        mv = new MetaVault(owner);
        deal(CRVUSD, alice, type(uint256).max);

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

        uint256 shares = mv.deposit(1e23, alice);
        mv.redeem(shares, alice, alice);

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
}
