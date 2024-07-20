// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {MetaVault} from "../src/MetaVault.sol";
import {ERC20} from "@oz/token/ERC20/ERC20.sol";
import {ERC4626} from "@oz/token/ERC20/extensions/ERC4626.sol";
import {IVault} from "../src/IVault.sol";
import {IGauge} from "../src/IGauge.sol";

// TODO: mock vault with real vault

function absDiff(uint256 a, uint256 b) pure returns (uint256) {
    if (a < b) {
        return b - a;
    } else {
        return a - b;
    }
}

contract MetaVaultHarness is MetaVault {
    constructor(
        address _owner,
        address _CRVUSD,
        uint256 _maxDeviation,
        uint256 _maxDeposits,
        address _firstVaultAddr,
        address _firstGaugeAddr
    )
        MetaVault(
            _owner,
            _CRVUSD,
            _maxDeviation,
            _maxDeposits,
            _firstVaultAddr,
            _firstGaugeAddr
        )
    {}

    function __depositIntoVault(uint256 vaultIdx, uint256 assets) external {
        CRVUSD.transferFrom(msg.sender, address(this), assets);
        _depositIntoVault(vaultIdx, assets);
    }

    function __assets() external returns (uint256[] memory) {
        _updateCurrentAssets();
        return cachedCurrentAssets;
    }

    function __percentages() external returns (uint256[] memory) {
        _updateCurrentAssets();

        // reuse the array
        uint256[] memory percentages = new uint256[](vaults.length);
        uint256 sumPercentages = 0;
        for (uint256 i = 0; i < vaults.length - 1; i++) {
            uint256 percentage = (cachedCurrentAssets[i] * 10_000) /
                cachedSumAssets;
            percentages[i] = percentage;
            sumPercentages += percentage;
        }
        percentages[vaults.length - 1] = 10_000 - sumPercentages;

        return percentages;
    }
}

contract MetaVaultTest is Test {
    address constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;

    // address constant CRV_vault = 0xCeA18a8752bb7e7817F9AE7565328FE415C0f2cA;
    // address constant USDe_vault = 0xc687141c18F20f7Ba405e45328825579fDdD3195;
    // address constant WBTC_vault = 0xccd37EB6374Ae5b1f0b85ac97eFf14770e0D0063;
    // address constant WETH_vault = 0x8fb1c7AEDcbBc1222325C39dd5c1D2d23420CAe3;
    // address constant pufETH_vault = 0xff467c6E827ebbEa64DA1ab0425021E6c89Fbe0d;
    // address constant sFRAX_vault = 0xd0c183C9339e73D7c9146D48E1111d1FBEe2D6f9;

    address constant VAULT_CRV = 0xCeA18a8752bb7e7817F9AE7565328FE415C0f2cA;
    address constant GAUGE_CRV = 0x49887dF6fE905663CDB46c616BfBfBB50e85a265;
    address constant VAULT_USDe = 0xc687141c18F20f7Ba405e45328825579fDdD3195;
    address constant GAUGE_USDe = 0xEAED59025d6Cf575238A9B4905aCa11E000BaAD0;
    address constant VAULT_WBTC = 0xccd37EB6374Ae5b1f0b85ac97eFf14770e0D0063;
    address constant GAUGE_WBTC = 0x7dCB252f7Ea2B8dA6fA59C79EdF63f793C8b63b6;
    address constant VAULT_WETH = 0x8fb1c7AEDcbBc1222325C39dd5c1D2d23420CAe3;
    address constant GAUGE_WETH = 0xF3F6D6d412a77b680ec3a5E35EbB11BbEC319739;
    address constant VAULT_pufETH = 0xff467c6E827ebbEa64DA1ab0425021E6c89Fbe0d;
    address constant GAUGE_pufETH = 0x294280254e1c8BcF56F8618623Ec9235e8415633;
    address constant VAULT_sFRAX = 0xd0c183C9339e73D7c9146D48E1111d1FBEe2D6f9;
    address constant GAUGE_sFRAX = 0xDFF0ed66fdDCC440FB3aDFB2f12029925799979c;

    IVault[] vaults;
    IGauge[] gauges;

    uint16[] targets;

    MetaVaultHarness mv;
    MetaVaultHarness mvWithBallast;

    address owner;
    address alice;
    address bob;
    address charlie;

    function setUp() public {
        // vm.startPrank(owner);

        // vm.createSelectFork("https://eth.llamarpc.com");
        vm.createSelectFork("wss://ethereum-rpc.publicnode.com");
        // vm.createSelectFork("https://rpc.payload.de");
        // vm.createSelectFork("https://eth.api.onfinality.io/public");
        // vm.createSelectFork("http://10.95.33.126:8545/");
        // vm.createSelectFork("http://10.95.33.126:8545/");
        // https://rpc.ankr.com/eth

        vm.label(CRVUSD, "CRVUSD");

        vm.label(VAULT_CRV, "VAULT_CRV");
        vm.label(GAUGE_CRV, "GAUGE_CRV");
        vm.label(VAULT_USDe, "VAULT_USDe");
        vm.label(GAUGE_USDe, "GAUGE_USDe");
        vm.label(VAULT_WBTC, "VAULT_WBTC");
        vm.label(GAUGE_WBTC, "GAUGE_WBTC");
        vm.label(VAULT_WETH, "VAULT_WETH");
        vm.label(GAUGE_WETH, "GAUGE_WETH");
        vm.label(VAULT_pufETH, "VAULT_pufETH");
        vm.label(GAUGE_pufETH, "GAUGE_pufETH");
        vm.label(VAULT_sFRAX, "VAULT_sFRAX");
        vm.label(GAUGE_sFRAX, "GAUGE_sFRAX");

        owner = makeAddr("owner");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        charlie = makeAddr("charlie");

        deal(CRVUSD, owner, type(uint256).max);
        deal(CRVUSD, alice, type(uint256).max);
        deal(CRVUSD, bob, type(uint256).max);
        deal(CRVUSD, charlie, type(uint256).max);

        //
        // ########## Set up mv ##########
        //

        vaults.push(IVault(VAULT_CRV));
        vaults.push(IVault(VAULT_USDe));
        vaults.push(IVault(VAULT_WBTC));
        vaults.push(IVault(VAULT_WETH));
        vaults.push(IVault(VAULT_pufETH));
        vaults.push(IVault(VAULT_sFRAX));

        gauges.push(IGauge(GAUGE_CRV));
        gauges.push(IGauge(GAUGE_USDe));
        gauges.push(IGauge(GAUGE_WBTC));
        gauges.push(IGauge(GAUGE_WETH));
        gauges.push(IGauge(GAUGE_pufETH));
        gauges.push(IGauge(GAUGE_sFRAX));

        mv = new MetaVaultHarness(
            owner,
            CRVUSD,
            200,
            type(uint256).max,
            address(vaults[0]),
            address(gauges[0])
        );

        for (uint256 i = 1; i < vaults.length; i++) {
            vm.prank(owner);
            mv.addVault(address(vaults[i]), address(gauges[i]));
        }

        targets = new uint16[](vaults.length);
        targets[0] = 200;
        targets[1] = 300;
        targets[2] = 500;
        targets[3] = 2000;
        targets[4] = 3000;
        targets[5] = 4000;

        vm.prank(owner);
        mv.setTargets(targets);

        //
        // ########## Set up mv with ballast ##########
        //

        mvWithBallast = new MetaVaultHarness(
            owner,
            CRVUSD,
            200,
            type(uint256).max,
            address(vaults[0]),
            address(gauges[0])
        );

        for (uint256 i = 1; i < vaults.length; i++) {
            vm.prank(owner);
            mvWithBallast.addVault(address(vaults[i]), address(gauges[i]));
        }

        vm.prank(owner);
        mvWithBallast.setTargets(targets);
        vm.prank(owner);
        ERC20(CRVUSD).approve(address(mvWithBallast), type(uint256).max);
        vm.prank(owner);
        console.log("owner is depositing 1e25");
        mvWithBallast.deposit(1e25, owner);
        console.log("owner done depositing");

        console.log(">>> %e", mvWithBallast.totalAssets());
        for (uint256 i = 0; i < vaults.length; ++i) {
            console.log(">> %d: %e", i, vaults[i].totalAssets());
        }

        // vm.stopPrank();
    }

    // TODO: test max deposits and max deviation
    // TODO: test rebalance empty

    function test_rebalance() public {
        vm.startPrank(alice);

        ERC20(CRVUSD).approve(address(mv), type(uint256).max);

        // deposit into the 0th vault without regard for targets
        mv.__depositIntoVault(0, 1e5);

        // the 0th vault contains 100% of the assets, all other vaults
        // contain 0%
        uint256[] memory percentages = mv.__percentages();
        assertEq(percentages[0], 10_000);
        for (uint256 i = 1; i < percentages.length; i++) {
            assertEq(percentages[i], 0);
        }

        vm.stopPrank();

        vm.prank(owner);
        mv.rebalance();

        // all percentages are close to their targets
        percentages = mv.__percentages();
        for (uint256 i = 0; i < percentages.length; i++) {
            assertLt(absDiff(percentages[i], targets[i]), 10);
        }
    }

    function test_deposit() public {
        vm.startPrank(alice);

        assertEq(ERC20(CRVUSD).balanceOf(address(mv)), 0);

        ERC20(CRVUSD).approve(address(mv), type(uint256).max);

        uint256 mvShares = mv.deposit(1e18, alice);
        // console.log("T resulting mv shares: %e", mvShares);

        // NOTE: this will depend on the _decimalsOffset()
        assertEq(mvShares, 1e18);
        assertEq(mv.totalSupply(), 1e18);

        // the total assets contained in the metavault is (almost)
        // what we just put in
        assertLt(absDiff(mv.totalAssets(), 1e18), 10);

        // all the crvUSD that the metavault got was deposited
        // into the sub-vaults
        assertEq(ERC20(CRVUSD).balanceOf(address(mv)), 0);

        for (uint256 i = 0; i < vaults.length; i++) {
            if (address(gauges[i]) == address(0)) {
                assertGe(vaults[i].maxWithdraw(address(mv)), 0);
            } else {
                // all the vault shares were deposited into the
                // respective gauge
                assertEq(vaults[i].maxWithdraw(address(mv)), 0);
                assertGe(gauges[i].balanceOf(address(mv)), 0);
            }
        }

        vm.stopPrank();
    }

    function test_withdraw() public {
        // deposit 1e18
        test_deposit();

        vm.startPrank(alice);

        uint256 maxWithdraw = mv.maxWithdraw(alice);

        // we can withdraw (almost) everything that we put in
        assertLt(absDiff(maxWithdraw, mv.totalAssets()), 10);

        mv.withdraw(maxWithdraw, alice, alice);

        // all vaults are (almost) empty
        for (uint256 i = 0; i < vaults.length; i++) {
            assertLt(absDiff(vaults[i].maxWithdraw(address(mv)), 0), 10);
        }

        // the metavault is (almost) empty
        assertLt(absDiff(mv.totalAssets(), 0), 10);

        // the metavault gave everything that it extracted from the
        // sub-vaults to alice
        assertEq(ERC20(CRVUSD).balanceOf(address(mv)), 0);

        vm.stopPrank();
    }

    function test_redeem() public {
        // deposit 1e18
        test_deposit();

        vm.startPrank(alice);

        uint256 maxRedeem = mv.maxRedeem(alice);

        // we can withdraw (almost) everything that we put in
        assertLt(absDiff(maxRedeem, mv.totalSupply()), 10);

        mv.redeem(maxRedeem, alice, alice);

        // all vaults are (almost) empty
        for (uint256 i = 0; i < vaults.length; i++) {
            assertLt(absDiff(vaults[i].maxWithdraw(address(mv)), 0), 10);
        }

        // the metavault is (almost) empty
        assertLt(absDiff(mv.totalAssets(), 0), 10);

        // the metavault gave everything that it extracted from the
        // sub-vaults to alice
        assertEq(ERC20(CRVUSD).balanceOf(address(mv)), 0);

        vm.stopPrank();
    }

    function test_withBallastDeposit() public {
        vm.startPrank(alice);
        // assertEq(ERC20(CRVUSD).balanceOf(address(mv)), 0);

        ERC20(CRVUSD).approve(address(mvWithBallast), type(uint256).max);

        console.log(
            " pre-dep %e",
            ERC20(CRVUSD).balanceOf(address(mvWithBallast))
        );
        mvWithBallast.deposit(1e18, alice);
        console.log(
            "post-dep %e",
            ERC20(CRVUSD).balanceOf(address(mvWithBallast))
        );

        for (uint256 i = 0; i < vaults.length; i++) {
            console.log(vaults[i].maxWithdraw(address(mvWithBallast)));
        }

        console.log("=====");

        for (uint256 i = 0; i < vaults.length; i++) {
            console.log(vaults[i].balanceOf(alice));
        }

        // assertEq(mvWithBallast.totalAssets(), 1e18 - vaults.length);

        // assertEq(ERC20(CRVUSD).balanceOf(address(mvWithBallast)), 0);
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

    function test_multiDepositRedeem() public {
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

        console.log("# alice redeems");
        vm.startPrank(alice);
        uint256 aliceRedemption = mv.maxRedeem(alice);
        console.log("> redemption amount (shares) %e", aliceRedemption);
        mv.redeem(aliceRedemption, alice, alice);

        console.log("# bob redeems");
        vm.startPrank(bob);
        uint256 bobRedemption = mv.maxRedeem(bob);
        console.log("> redemption amount (shares) %e", bobRedemption);
        mv.redeem(bobRedemption, bob, bob);

        console.log("# charlie redeems");
        vm.startPrank(charlie);
        uint256 charlieRedemption = mv.maxRedeem(charlie);
        console.log("> redemption amount (shares) %e", charlieRedemption);
        mv.redeem(charlieRedemption, charlie, charlie);

        console.log("# withdrawals done");

        // TODO: assertions
    }
}
