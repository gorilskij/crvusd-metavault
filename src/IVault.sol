// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.4;

interface IVault {
    event Approval(
        address indexed owner,
        address indexed spender,
        uint256 value
    );
    event Deposit(
        address indexed sender,
        address indexed owner,
        uint256 assets,
        uint256 shares
    );
    event Transfer(
        address indexed sender,
        address indexed receiver,
        uint256 value
    );
    event Withdraw(
        address indexed sender,
        address indexed receiver,
        address indexed owner,
        uint256 assets,
        uint256 shares
    );

    function admin() external view returns (address);

    function allowance(
        address arg0,
        address arg1
    ) external view returns (uint256);

    function amm() external view returns (address);

    function approve(address _spender, uint256 _value) external returns (bool);

    function asset() external view returns (address);

    function balanceOf(address arg0) external view returns (uint256);

    function borrow_apr() external view returns (uint256);

    function borrowed_token() external view returns (address);

    function collateral_token() external view returns (address);

    function controller() external view returns (address);

    function convertToAssets(uint256 shares) external view returns (uint256);

    function convertToShares(uint256 assets) external view returns (uint256);

    function decimals() external view returns (uint8);

    function decreaseAllowance(
        address _spender,
        uint256 _sub_value
    ) external returns (bool);

    function deposit(uint256 assets) external returns (uint256);

    function deposit(
        uint256 assets,
        address receiver
    ) external returns (uint256);

    function factory() external view returns (address);

    function increaseAllowance(
        address _spender,
        uint256 _add_value
    ) external returns (bool);

    function initialize(
        address amm_impl,
        address controller_impl,
        address borrowed_token,
        address collateral_token,
        uint256 A,
        uint256 fee,
        address price_oracle,
        address monetary_policy,
        uint256 loan_discount,
        uint256 liquidation_discount
    ) external returns (address, address);

    function lend_apr() external view returns (uint256);

    function maxDeposit(address receiver) external view returns (uint256);

    function maxMint(address receiver) external view returns (uint256);

    function maxRedeem(address owner) external view returns (uint256);

    function maxWithdraw(address owner) external view returns (uint256);

    function mint(uint256 shares) external returns (uint256);

    function mint(uint256 shares, address receiver) external returns (uint256);

    function name() external view returns (string memory);

    function previewDeposit(uint256 assets) external view returns (uint256);

    function previewMint(uint256 shares) external view returns (uint256);

    function previewRedeem(uint256 shares) external view returns (uint256);

    function previewWithdraw(uint256 assets) external view returns (uint256);

    function pricePerShare() external view returns (uint256);

    function pricePerShare(bool is_floor) external view returns (uint256);

    function price_oracle() external view returns (address);

    function redeem(uint256 shares) external returns (uint256);

    function redeem(
        uint256 shares,
        address receiver
    ) external returns (uint256);

    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) external returns (uint256);

    function symbol() external view returns (string memory);

    function totalAssets() external view returns (uint256);

    function totalSupply() external view returns (uint256);

    function transfer(address _to, uint256 _value) external returns (bool);

    function transferFrom(
        address _from,
        address _to,
        uint256 _value
    ) external returns (bool);

    function withdraw(uint256 assets) external returns (uint256);

    function withdraw(
        uint256 assets,
        address receiver
    ) external returns (uint256);

    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) external returns (uint256);
}
