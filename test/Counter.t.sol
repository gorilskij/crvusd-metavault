// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {MetaVault} from "../src/MetaVault.sol";
import "../src/IVault.sol";

contract CounterTest is Test {
    MetaVault mv;

    function setUp() public {
        vm.createSelectFork("https://rpc.ankr.com/eth");

        address owner = makeAddr("owner");
        mv = new MetaVault(owner);
    }

    function test_call() public {
        IVault(0xCeA18a8752bb7e7817F9AE7565328FE415C0f2cA).collateral_token();
    }

    // function testFuzz_SetNumber(uint256 x) public {
    //     // counter.setNumber(x);
    //     // assertEq(counter.number(), x);
    // }
}
