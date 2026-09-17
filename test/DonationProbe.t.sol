// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {Test} from "forge-std/Test.sol";

interface IERC20 { function balanceOf(address) external view returns (uint256); }
interface IDistrib {
    function minRewardsDistributePeriod() external view returns (uint256);
    function rewardPoolLastCalculatedTimestamp(uint256) external view returns (uint128);
    function depositPoolAddresses(uint256,uint256) external view returns (address);
    function depositPools(uint256,address) external view returns (
        address token, string memory chainLinkPath, uint256 tokenPrice, uint256 deposited,
        uint256 lastUnderlyingBalance, uint8 strategy, address aToken, bool isExist);
    function undistributedRewards() external view returns (uint256);
}
interface IRP { function getPeriodRewards(uint256,uint128,uint128) external view returns (uint256); }

contract DonationProbe is Test {
    IDistrib constant D = IDistrib(0xDf1AC1AC255d91F5f4B1E3B4Aef57c5350F64C7A);
    IRP constant RP = IRP(0xb7994dE339AEe515C9b2792831CD83f3C9D8df87);
    address[5] POOLS = [
        0x47176B2Af9885dC6C4575d4eFd63895f7Aaa4790, // stETH
        0x9380d72aBbD6e0Cc45095A2Ef8c2CA87d77Cb384, // wETH
        0xdE283F8309Fd1AA46c95d299f6B8310716277A42, // wBTC
        0x6cCE082851Add4c535352f596662521B4De4750E, // USDC
        0x3B51989212BEdaB926794D6bf8e9E991218cf116  // USDT
    ];
    string[5] NAMES = ["stETH","wETH","wBTC","USDC","USDT"];

    function test_probe() public {
        vm.createSelectFork(vm.envOr("ETH_RPC", string("https://ethereum-rpc.publicnode.com")), 25996939);
        emit log_named_uint("now", block.timestamp);
        uint256 minP = D.minRewardsDistributePeriod();
        emit log_named_uint("minRewardsDistributePeriod (s)", minP);
        uint128 lastCalc = D.rewardPoolLastCalculatedTimestamp(0);
        emit log_named_uint("lastCalculatedTimestamp[0]", lastCalc);
        emit log_named_uint("seconds since last distribute", block.timestamp - lastCalc);
        emit log_named_uint("undistributedRewards", D.undistributedRewards());

        // How many pools under index 0?
        uint256 n;
        for (uint256 i; i < 8; i++) {
            try D.depositPoolAddresses(0, i) returns (address a) { if (a == address(0)) break; n++; } catch { break; }
        }
        emit log_named_uint("pools under rewardPoolIndex 0", n);

        // Emission for one minRewardsDistributePeriod, and since last distribute
        emit log_named_uint("emission [now, now+minP]", RP.getPeriodRewards(0, uint128(block.timestamp), uint128(block.timestamp + minP)));
        emit log_named_uint("emission [lastCalc, now] (pending E)", RP.getPeriodRewards(0, lastCalc, uint128(block.timestamp)));

        // Per-pool organic yield accrued since lastUnderlyingBalance (= what a donation must beat)
        uint256 totalYieldValue;
        for (uint256 i; i < 5; i++) {
            (address token, , uint256 price, uint256 deposited, uint256 lub, uint8 strat, address aToken, bool exist) = D.depositPools(0, POOLS[i]);
            if (!exist) { emit log_named_string("pool not under idx0", NAMES[i]); continue; }
            address ytok = aToken == address(0) ? token : aToken; // NONE->deposit token, AAVE->aToken
            uint256 bal = IERC20(ytok).balanceOf(address(D));
            uint256 organic = bal > lub ? bal - lub : 0;
            emit log_named_string("== pool", NAMES[i]);
            emit log_named_uint("  strategy", strat);
            emit log_named_uint("  tokenPrice(1e18 USD)", price);
            emit log_named_uint("  deposited", deposited);
            emit log_named_uint("  lastUnderlyingBalance", lub);
            emit log_named_uint("  yieldToken bal now", bal);
            emit log_named_uint("  organic yield (bal-lub)", organic);
            uint256 yieldVal = organic * price / 1e18;
            emit log_named_uint("  organic yield VALUE (1e18 USD*token?)", yieldVal);
            totalYieldValue += organic * price; // matches contract: yield_ = underlyingYield * price (no /1e18)
        }
        emit log_named_uint("SUM raw totalYield (contract units)", totalYieldValue);
    }
    function _tokenOf(uint256) internal view returns (address) { return address(0); }
}
