// SPDX-License-Identifier: AGPL-3.0
// Feel free to change the license, but this is what we use

// Feel free to change this version of Solidity. We support >=0.6.0 <0.7.0;
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

// These are the core Yearn libraries
import {BaseStrategy, StrategyParams} from "@yearnvaults/contracts/BaseStrategy.sol";
import {SafeERC20, SafeMath, IERC20, Address} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

// Import interfaces for many popular DeFi projects, or add your own!
//import "../interfaces/<protocol>/<Interface>.sol";

import {ILendingPool} from "../interfaces/aave/ILendingPool.sol";
import {IAaveIncentivesController} from "../interfaces/aave/IAaveIncentivesController.sol";
import {ISwapRouter} from "../interfaces/uniswap/ISwapRouter.sol";

contract Strategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    event Debug(string name, uint256 amount);

    IERC20 public constant aToken =
        IERC20(0x9ff58f4fFB29fA2266Ab25e75e2A8b3503311656); // Token we provide liquidity with
    IERC20 public constant reward =
        IERC20(0x4da27a545c0c5B758a6BA100e3a049001de870f5); // Token we farm and swap to want / aToken

    ILendingPool public constant LENDING_POOL =
        ILendingPool(0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9);

    address public constant INCENTIVES_CONTROLLER =
        0xd784927Ff2f95ba542BfC824c8a8a98F3495f6b5;

    // For Swapping
    address public constant ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;

    IERC20 public constant AAVE_TOKEN =
        IERC20(0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9);
    IERC20 public constant WETH_TOKEN =
        IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    constructor(address _vault) public BaseStrategy(_vault) {
        // You can set these parameters on deployment to whatever you want
        // maxReportDelay = 6300;
        // profitFactor = 100;
        // debtThreshold = 0;
    }

    // ******** OVERRIDE THESE METHODS FROM BASE CONTRACT ************

    function name() external view override returns (string memory) {
        // Add your own name here, suggestion e.g. "StrategyCreamYFI"
        return "StrategyAAVEwBTC";
    }

    // Equivalent to balance() which is balanceOfWant + balanceInPool
    function estimatedTotalAssets() public view override returns (uint256) {
        // Balance of want + balance in AAVE
        return
            want.balanceOf(address(this)).add(aToken.balanceOf(address(this)));
    }

    // Basically Harvest
    // TODO: Figure out _debtOutstanding
    function prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        )
    {
        _loss = 0; // Since we never lever up, loss is always 0
        _debtPayment = 0; // Since we never lever up, we never have to pay back any debt

        // Get current amount of want // used to estimate profit
        uint256 beforeBalance = want.balanceOf(address(this));
        emit Debug("beforeBalance", beforeBalance);

        // Calculate Gain from AAVE interest
        uint256 currentWantInAave = aToken.balanceOf(address(this));
        uint256 initialDeposit = vault.strategies(address(this)).totalDebt;
        if (currentWantInAave > initialDeposit) {
            uint256 interestProfit = currentWantInAave.sub(initialDeposit);
            emit Debug("interestProfit", interestProfit);
            LENDING_POOL.withdraw(address(want), interestProfit, address(this));
            // Withdraw interest of aToken so that now we have exactly the same amount
        }

        // Get rewards
        address[] memory assets = new address[](1);
        assets[0] = address(aToken);

        // Get Rewards, withdraw all
        IAaveIncentivesController(INCENTIVES_CONTROLLER).claimRewards(
            assets,
            type(uint256).max,
            address(this)
        );

        uint256 rewardsAmount = reward.balanceOf(address(this));

        if (rewardsAmount == 0) {
            _profit = 0;
            return (_profit, _loss, _debtPayment);
        }

        reward.safeApprove(ROUTER, rewardsAmount);

        // Swap Rewards in UNIV3
        // NOTE: Unoptimized, can be frontrun and most importantly this pool is low liquidity


            ISwapRouter.ExactInputSingleParams memory fromRewardToAAVEParams
         = ISwapRouter.ExactInputSingleParams(
            address(reward),
            address(AAVE_TOKEN),
            10000,
            address(this),
            now,
            rewardsAmount, // wei
            0,
            0
        );
        ISwapRouter(ROUTER).exactInputSingle(fromRewardToAAVEParams);

        uint256 aaveToSwap = AAVE_TOKEN.balanceOf(address(this));
        AAVE_TOKEN.safeApprove(ROUTER, aaveToSwap);

        // We now have AAVE tokens, let's get wBTC
        bytes memory path = abi.encodePacked(
            address(AAVE_TOKEN),
            uint24(10000),
            address(WETH_TOKEN),
            uint24(10000),
            address(want)
        );

        ISwapRouter.ExactInputParams memory fromAAVETowBTCParams = ISwapRouter
        .ExactInputParams(path, address(this), now, aaveToSwap, 0);
        ISwapRouter(ROUTER).exactInput(fromAAVETowBTCParams);

        uint256 afterBalance = want.balanceOf(address(this));
        emit Debug("afterBalance", afterBalance);

        _profit = afterBalance.sub(beforeBalance); // Profit here
        emit Debug("_profit", _profit);

        // At the end want.balanceOf(address(this)) >= _debtOustanding as the Vault wants it back
        if (_debtOutstanding > 0) {
            emit Debug("_debtOutstanding > 0", _debtOutstanding);

            uint256 toWithdraw = _debtOutstanding;

            if (_debtOutstanding < aToken.balanceOf(address(this))) {
                toWithdraw = aToken.balanceOf(address(this));
            }

            // I don't believe we'll ever have this as BaseStrategy liquidatesAll
            // In a different strategy (leveraged), we probably should pay debt back first
            liquidatePosition(toWithdraw);
            _debtPayment = toWithdraw;
            //Since we don't leverage we can always repay max, provided it's below the max amount in pool
        }
    }

    // Like tend, just deposit into AAVE
    function adjustPosition(uint256 _debtOutstanding) internal override {
        // TODO: Do something to invest excess `want` tokens (from the Vault) into your positions
        // NOTE: Try to adjust positions so that `_debtOutstanding` can be freed up on *next* harvest (not immediately)
        // NOTE: Since we can withdraw at any time (non leveraged), no reason to withdraw here, we can do it on harvest
        // This is tend, not much to change here
        uint256 wantAvailable = want.balanceOf(address(this));
        Debug("adjustPosition.wantAvailable", wantAvailable);
        if (wantAvailable > _debtOutstanding) {
            uint256 toDeposit = wantAvailable.sub(_debtOutstanding);
            Debug("adjustPosition.toDeposit", toDeposit);
            want.safeApprove(address(LENDING_POOL), toDeposit);
            LENDING_POOL.deposit(address(want), toDeposit, address(this), 0);
        }
    }

    // Like withdraw some, withdraw _amountNeeded from pool
    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        // TODO: Do stuff here to free up to `_amountNeeded` from all positions back into `want`
        // NOTE: Maintain invariant `want.balanceOf(this) >= _liquidatedAmount`
        // NOTE: Maintain invariant `_liquidatedAmount + _loss <= _amountNeeded`

        //This is basically withdrawSome
        LENDING_POOL.withdraw(address(want), _amountNeeded, address(this));

        uint256 totalAssets = want.balanceOf(address(this));
        if (_amountNeeded > totalAssets) {
            _liquidatedAmount = totalAssets;
            _loss = _amountNeeded.sub(totalAssets);
        } else {
            _liquidatedAmount = _amountNeeded;
        }

        require(want.balanceOf(address(this)) >= _liquidatedAmount);
        require(_liquidatedAmount + _loss <= _amountNeeded);
    }

    // Withdraw all from AAVE Pool
    function liquidateAllPositions() internal override returns (uint256) {
        // This is a generalization of withdrawAll that withdraws everything for the entire strat
        LENDING_POOL.withdraw(
            address(want),
            aToken.balanceOf(address(this)),
            address(this)
        );

        // TODO: Liquidate all positions and return the amount freed.
        return want.balanceOf(address(this));
    }

    // NOTE: Can override `tendTrigger` and `harvestTrigger` if necessary

    function prepareMigration(address _newStrategy) internal override {
        // TODO: Transfer any non-`want` tokens to the new strategy
        // NOTE: `migrate` will automatically forward all `want` in this strategy to the new one
        // This is gone if we use upgradeable
        aToken.safeTransfer(_newStrategy, aToken.balanceOf(address(this)));
        reward.safeTransfer(_newStrategy, reward.balanceOf(address(this)));

        // TODO: Claim all rewards outstanding
    }

    // Override this to add all tokens/tokenized positions this contract manages
    // on a *persistent* basis (e.g. not just for swapping back to want ephemerally)
    // NOTE: Do *not* include `want`, already included in `sweep` below
    //
    // Example:
    //
    function protectedTokens()
        internal
        view
        override
        returns (address[] memory)
    {
        address[] memory protected = new address[](2);
        protected[0] = address(aToken);
        protected[1] = address(reward);
        return protected;
    }

    /**
     * @notice
     *  Provide an accurate conversion from `_amtInWei` (denominated in wei)
     *  to `want` (using the native decimal characteristics of `want`).
     * @dev
     *  Care must be taken when working with decimals to assure that the conversion
     *  is compatible. As an example:
     *
     *      given 1e17 wei (0.1 ETH) as input, and want is USDC (6 decimals),
     *      with USDC/ETH = 1800, this should give back 1800000000 (180 USDC)
     *
     * @param _amtInWei The amount (in wei/1e-18 ETH) to convert to `want`
     * @return The amount in `want` of `_amtInEth` converted to `want`
     **/
    function ethToWant(uint256 _amtInWei)
        public
        view
        virtual
        override
        returns (uint256)
    {
        // TODO create an accurate price oracle
        // NOTE: aave does have a price oracle
        return _amtInWei;
    }
}
