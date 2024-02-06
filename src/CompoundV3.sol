// SPDX-License-Identifier: MIT

pragma solidity 0.8.23;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

struct AssetInfo {
    address priceFeed;
    uint8 offset;
    uint256 borrowCollateralFactor;
    uint256 totalDeposited;
}

struct UserInfo {
    int256 principal; // positive for lenders, negative for borrowers
    uint256 trackingIndex;
    uint16 assetsIn;
}

interface IPriceFeed {
  function decimals() external view returns (uint8);

  function description() external view returns (string memory);

  function version() external view returns (uint256);

  function latestRoundData()
    external
    view
    returns (
      uint80 roundId,
      int256 answer,
      uint256 startedAt,
      uint256 updatedAt,
      uint80 answeredInRound
    );
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

    uint256 public immutable baseBorrowMin;
    address public immutable baseTokenPriceFeed;

    mapping(address collateralToken => AssetInfo tokenInfo) public tokenInfos;
    mapping(uint16 index => address collateralToken) public indexToToken;

    mapping(address user => UserInfo info) public userInfos;

    mapping(address user => mapping(address token => uint256 collateralAmount)) public collaterals;



    uint256 public supplyInterestRate;
    uint256 public borrowInterestRate;
    uint256 public totalSupplyBase;
    uint256 public totalBorrowBase;
    uint256 public lastAccrualTime;

    constructor() {
    }


    function supplyOrRepayBase(uint256 _amount) external {
        // Transfer the tokens into this contract from the user
        IERC20(baseToken).safeTransferFrom(msg.sender, address(this), _amount);

        // Accrue indices
        accrueInternal();
        
        UserInfo memory userInfo = userInfos[msg.sender];
        int256 principal = userInfo.principal;
        // Unsafe cast to int256
        int256 balance = presentValue(principal) + int256(_amount);
        int256 newPrincipal = principalValue(balance);

        (uint256 repaidAmount, uint256 suppliedAmount) = repayAndSupplyAmount(principal, newPrincipal);

        totalSupplyBase += suppliedAmount;
        totalBorrowBase -= repaidAmount;

        userInfo.principal = newPrincipal;
    }

    // Notice there is no supplyCap for simplicity
    function supplyCollateral(address _token, uint256 _amount) external {
        AssetInfo memory assetInfo = tokenInfos[_token];

        if(assetInfo.priceFeed == address(0)) revert();

        IERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);

        assetInfo.totalDeposited += _amount;
        uint256 userCollateral = collaterals[msg.sender][_token];
        uint256 newUserCollateral = userCollateral + _amount;

        tokenInfos[_token] = assetInfo;

        // Update assetsIn
        if(userCollateral == 0 && newUserCollateral != 0){
            userInfos[msg.sender].assetsIn |= uint16(1 << assetInfo.offset);
        } else if(userCollateral != 0 && newUserCollateral == 0){
            userInfos[msg.sender].assetsIn &= ~uint16(1 << assetInfo.offset);
        }
    }

    function borrowOrWithdrawBase(uint256 _amount) external {
        accrueInternal();

        UserInfo memory userInfo = userInfos[msg.sender];
        int256 principal = userInfo.principal;
        int256 balance = presentValue(principal) - int256(_amount);
        int256 newPrincipal = principalValue(balance);

        (uint256 withdrawnAmount, uint256 borrowedAmount) = withdrawAndBorrowAmount(principal, newPrincipal);

        totalSupplyBase -= withdrawnAmount;
        totalBorrowBase += borrowedAmount;

        userInfo.principal = newPrincipal;

        if(balance < 0){
            if(uint256(-balance) < baseBorrowMin) revert();
            if(!isBorrowCollateralized(msg.sender)) revert();
        }

        IERC20(baseToken).safeTransfer(msg.sender, _amount);
    }

    function withdrawCollateral(address _token, uint256 _amount) external {
        AssetInfo memory assetInfo = tokenInfos[_token];

        if(assetInfo.priceFeed == address(0)) revert();

        uint256 collateral = collaterals[msg.sender][_token];
        uint256 newCollateral = collateral - _amount;

        tokenInfos[_token].totalDeposited -= _amount;
        collaterals[msg.sender][_token] = newCollateral;

        // Update assetsIn
        if(collateral == 0 && newCollateral != 0){
            userInfos[msg.sender].assetsIn |= uint16(1 << assetInfo.offset);
        } else if(collateral != 0 && newCollateral == 0){
            userInfos[msg.sender].assetsIn &= ~uint16(1 << assetInfo.offset);
        }

        if(!isBorrowCollateralized(msg.sender)) revert();

        IERC20(_token).safeTransfer(msg.sender, _amount);
    }

    function absorb(address[] calldata _accounts) external {}

    function buyCollateral(address _token, uint256 minAmount, uint256 baseAmount) external {}

    function transfer(address _receiver, uint256 _amount) external returns(bool) {}






    function isBorrowCollateralized(address _user) internal view returns(bool){
        int256 principal = userInfos[_user].principal;

        if(principal >= 0) {
            return true;
        }

        uint16 assetsIn = userInfos[_user].assetsIn;
        int256 borrowAmountToFulfill = presentValue(principal) * int256(getPrice(baseTokenPriceFeed)) / 1 ether;

        // Iterate to all assets
        for(uint8 i; i < 16; ++i){
            if(assetsIn & (uint16(1) << i) != 0){
                if(borrowAmountToFulfill >= 0){
                    return true;
                }

                address tokenAddress = indexToToken[i];
                AssetInfo memory asset = tokenInfos[tokenAddress];
                uint256 newAmount = collaterals[_user][tokenAddress] * getPrice(asset.priceFeed) / 1 ether;
                borrowAmountToFulfill += int256(newAmount * asset.borrowCollateralFactor / 1 ether);
            }
        }

        return borrowAmountToFulfill >= 0;
    }

    function repayAndSupplyAmount(int256 oldPrincipal, int256 newPrincipal) internal pure returns(uint256, uint256){
        if(newPrincipal < oldPrincipal) return(0, 0);

        if(newPrincipal <= 0){
            return(uint256(newPrincipal - oldPrincipal), 0);
        } else if(oldPrincipal >= 0){
            return (0, uint256(newPrincipal - oldPrincipal));
        } else {
            return (uint256(-oldPrincipal), uint256(newPrincipal));
        }
    }

    function withdrawAndBorrowAmount(int256 principal, int256 newPrincipal) internal pure returns(uint256, uint256){
        if(newPrincipal > principal) return(0, 0);

        if(newPrincipal >= 0){
            return(uint256(principal - newPrincipal), 0);
        } else if(principal <= 0){
            return(0, uint256(principal - newPrincipal));
        } else {
            return(uint256(principal), uint256(-newPrincipal));
        }
    }

    function accrueInternal() internal {
        uint256 now_ = block.timestamp;
        uint256 timeElapsed = now_ - lastAccrualTime;
        if(timeElapsed > 0){
            (supplyInterestRate, borrowInterestRate) = accruedInterestIndices(timeElapsed);
            lastAccrualTime = now_;
        }
    }

    function accruedInterestIndices(uint256 _timeElapsed) internal view returns(uint256, uint256){
        uint256 baseSupplyIndex = supplyInterestRate;
        uint256 baseBorrowIndex = borrowInterestRate;
        if(_timeElapsed > 0){
            uint256 utilization = getUtilization();
            uint256 supplyRate = getSupplyRate(utilization);
            uint256 borrowRate = getBorrowRate(utilization);
            baseSupplyIndex += baseSupplyIndex * (supplyRate * _timeElapsed) / 1 ether;
            baseBorrowIndex += baseBorrowIndex * (borrowRate * _timeElapsed) / 1 ether;
        }
        return (baseSupplyIndex, baseBorrowIndex);
    }

    function getUtilization() public view returns(uint256){
        uint256 totalSupply = presentValueSupply(supplyInterestRate, totalSupplyBase);
        uint256 totalBorrow = presentValueBorrow(borrowInterestRate, totalBorrowBase);
        if(totalSupply == 0){
            return 0;
        } else {
            return totalBorrow * 1 ether / totalSupply;
        }
    }

    function presentValue(int256 _principalValue) internal view returns(int256){
        if(_principalValue >= 0){
            return int256(presentValueSupply(supplyInterestRate, uint256(_principalValue)));
        } else {
            return -int256(presentValueBorrow(borrowInterestRate, uint256(-_principalValue)));
        }
    }

    function principalValue(int256 _presentValue) internal view returns(int256){
        if(_presentValue >= 0){
            return int256(principalValueSupply(supplyInterestRate, uint256(_presentValue)));
        } else {
            return -int256(principalValueBorrow(borrowInterestRate, uint256(-_presentValue)));
        }
    }

    function principalValueSupply(uint256 _interestRate, uint256 _presentValue) internal pure returns(uint256){
        return(_presentValue * 1 ether / _interestRate);
    }

    function principalValueBorrow(uint256 _interestRate, uint256 _presentValue) internal pure returns(uint256){
        return((_presentValue * 1 ether + _interestRate - 1) / _interestRate);
    }

    function presentValueSupply(uint256 _interestRate, uint256 _principalValue) internal pure returns(uint256){
        return _principalValue * _interestRate / 1 ether;
    }

    function presentValueBorrow(uint256 _interestRate, uint256 _principalValue) internal pure returns(uint256){
        return _principalValue * _interestRate / 1 ether;
    }

    function getSupplyRate(uint256 _utilization) public view returns(uint256){
        if(_utilization <= optimalUtilizationSupply){
            return supplyInterestBase + supplyInterestSlopeLow * _utilization / 1 ether;
        } else {
            return supplyInterestBase + supplyInterestSlopeLow * optimalUtilizationSupply / 1 ether + supplyInterestSlopeHigh * (_utilization - optimalUtilizationSupply) / 1 ether;
        }
    }

    function getBorrowRate(uint256 _utilization) public view returns(uint256){
        if(_utilization <= optimalUtilizationBorrow){
            return borrowInterestBase + borrowInterestSlopeLow * _utilization / 1 ether;
        } else {
            return borrowInterestBase + borrowInterestSlopeLow * optimalUtilizationBorrow / 1 ether + borrowInterestSlopeHigh * (_utilization - optimalUtilizationBorrow) / 1 ether;
        }
    }

    // Notice it does not check for stale price
    function getPrice(address _priceFeed) internal view returns(uint256){
        (, int price, , , ) = IPriceFeed(_priceFeed).latestRoundData();
        if (price <= 0) revert();
        uint8 priceFeedDecimals = IPriceFeed(_priceFeed).decimals();
        return uint256(price) * 10 ** (18 - priceFeedDecimals);
    }
}
