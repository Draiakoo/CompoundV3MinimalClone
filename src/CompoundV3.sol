// SPDX-License-Identifier: MIT

pragma solidity 0.8.23;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

struct AssetInfo {
    address priceFeed;
    uint256 loanToValue;
}

struct UserInfo {
    int104 principal;
    uint64 trackingIndex;
    uint16 assetsIn;
}

contract CompoundV3 {

    using SafeERC20 for IERC20;

    uint64 internal constant SECONDS_PER_YEAR = 31_536_000;

    address public immutable baseToken;

    uint256 public immutable optimalUtilizationSupply;
    uint256 public immutable optimalUtilizationBorrow;
    uint256 public immutable supplyInterestBase;
    uint256 public immutable supplyInterestSlopeLow;
    uint256 public immutable supplyInterestSlopeHigh;
    uint256 public immutable borrowInterestBase;
    uint256 public immutable borrowInterestSlopeLow;
    uint256 public immutable borrowInterestSlopeHigh;

    mapping(address collateralToken => AssetInfo tokenInfo) public tokenInfos;

    mapping(address user => UserInfo info) public userInfos;

    mapping(address user => mapping(address token => uint256 collateralAmount)) public collaterals;

    uint256 public supplyInterestRate;
    uint256 public borrowInterestRate;
    uint256 public totalSupplyBase;
    uint256 public totalBorrowBase;
    uint256 public lastAccrualTime;

    constructor() {
        lastAcctualTime = block.timestamp;
    }


    function supplyBase(uint256 amount) external {
        // Transfer the tokens into this contract from the user
        IERC20(baseToken).safeTransferFrom(msg.sender, address(this), amount);

        // Accrue indices
        accureInternal();
        
        UserInfo memory userInfo = userInfos[msg.sender];
        int104 principal = userInfo.principal;
        // Unsafe cast to int256
        int256 balance = presentValue(supplyInterestRate, principal) + int256(amount);
    }

    function supplyCollateral(uint256 amount) external {}

    function borrowBase(uint256 amount) external {}

    function repayBase(uint256 amount) external {}

    function withdrawBase(uint256 amount) external {}

    function withdrawCollateral(uint256 amount) external {}





    function accrueInternal() internal {
        uint256 now_ = block.timestamp;
        uint256 timeElapsed = now_ - lastAccrualTime;
        if(timeElapsed > 0){
            (supplyInterestRate, borrowInterestRate) = accruedInterestIndices(timeElapsed);
            lastAccrualTime = now_;
        }
    }

    function accruedInterestIndices(uint256 timeElapsed) internal {
        uint256 baseSupplyIndex = supplyInterestRate;
        uint256 baseBorrowIndex = borrowInterestRate;
        if(timeElapsed > 0){
            uint256 utilization = getUtilization();
            uint256 supplyRate = getSupplyRate(utilization);
            uint256 borrowRate = getBorrowRate(utilization);
            baseSupplyIndex += baseSupplyIndex * (supplyRate * timeElapsed) / 1 ether;
            baseBorrowIndex += baseBorrowIndex * (borrowRate * timeElapsed) / 1 ether;
        }
        return (baseSupplyIndex, baseBorrowIndex);
    }

    function getUtilization() public view returns(uint256){
        uint256 totalSupply = presentValueSupply(supplyInterestRate, totalSupplyBase);
        uint256 totalSBorrow = presentValueBorrow(borrowInterestRate, totalBorrowBase);
        if(totalSupply == 0){
            return 0;
        } else {
            return totalBorrow * 1 ether / totalSupply;
        }
    }

    function presentValue(uint256 interestRate, uint256 principalValue) internal pure returns(uint256){
        return principalValue * interestRate / 1 ether;
    }

    function presentValueSupply(uint256 interestRate, uint256 principalValue) internal pure returns(uint256){
        return principalValue * interestRate / 1 ether;
    }

    function presentValueBorrow(uint256 interestRate, uint256 principalValue) internal pure returns(uint256){
        return principalValue * interestRate / 1 ether;
    }

    function getSupplyRate(uint256 utilization) public view returns(uint256){
        if(utilization <= optimalUtilizationSupply){
            return supplyInterestBase + supplyInterestSlopeLow * utilization / 1 ether;
        } else {
            return supplyInterestBase + supplyInterestSlopeLow * optimalUtilizationSupply / 1 ether + supplyInterestSlopeHigh * (utilization - optimalUtilizationSupply) / 1 ether;
        }
    }

    function getBorrowRate(uint256 utilization) public view returns(uint256){
        if(utilization <= optimalUtilizationBorrow){
            return borrowInterestBase + borrowInterestSlopeLow * utilization / 1 ether;
        } else {
            return borrowInterestBase + borrowInterestSlopeLow * optimalUtilizationBorrow / 1 ether + borrowInterestSlopeHigh * (utilization - optimalUtilizationBorrow) / 1 ether;
        }
    }


}
