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

    event Debug(string name, uint256 value);

    IERC20 public constant aToken =
        IERC20(0x9ff58f4fFB29fA2266Ab25e75e2A8b3503311656); // Token we provide liquidity with
    IERC20 public constant vToken =
        IERC20(0x9c39809Dec7F95F5e0713634a4D0701329B3b4d2); // Variable Debt

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

    // Leverage
    uint256 public constant MAX_BPS = 10000;
    uint256 public minHealth = 1300000000000000000; // 1.3 with 18 decimals
    uint256 public minRebalanceAmount = 50000000; // 0.5 should be changed based on decimals (btc has 8)

    constructor(address _vault) public BaseStrategy(_vault) {
        // You can set these parameters on deployment to whatever you want
        // maxReportDelay = 6300;
        // profitFactor = 100;
        // debtThreshold = 0;
    }

    /** Settings */
    // NOTE: OnlyKeepers may be too lax
    function setRebalanceAmount(uint256 newRebalanceAmount)
        external
        onlyKeepers
    {
        minRebalanceAmount = newRebalanceAmount;
    }

    function setMinHealth(uint256 newMinHealth) external onlyKeepers {
        minHealth = newMinHealth;
    }

    // ******** OVERRIDE THESE METHODS FROM BASE CONTRACT ************

    function name() external view override returns (string memory) {
        // Add your own name here, suggestion e.g. "StrategyCreamYFI"
        return "StrategyAAVEwBTC";
    }

    // Equivalent to balance() which is balanceOfWant + balanceInPool
    function estimatedTotalAssets() public view override returns (uint256) {
        // Balance of want + balance in AAVE
        return want.balanceOf(address(this)).add(deposited()).sub(borrowed());
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
        Debug("beforeBalance", beforeBalance);

        // Claim stkAAVE -> swap into want
        _claimRewardsAndGetMoreWant();

        uint256 afterSwapBalance = want.balanceOf(address(this));
        uint256 wantFromSwap = afterSwapBalance.sub(beforeBalance);
        Debug("wantFromSwap", wantFromSwap);

        // Calculate Gain from AAVE interest // NOTE: This should never happen as we take more debt than we earn
        uint256 currentWantInAave = deposited().sub(borrowed());
        Debug("currentWantInAave", currentWantInAave);
        uint256 initialDeposit = vault.strategies(address(this)).totalDebt;
        Debug("initialDeposit", initialDeposit);
        if (currentWantInAave > initialDeposit) {
            uint256 interestProfit = currentWantInAave.sub(initialDeposit);
            Debug("interestProfit", interestProfit);
            LENDING_POOL.withdraw(address(want), interestProfit, address(this));
            // Withdraw interest of aToken so that now we have exactly the same amount
        }

        uint256 afterBalance = want.balanceOf(address(this));
        Debug("afterBalance", afterBalance);
        uint256 wantEarned = afterBalance.sub(beforeBalance); // Earned before repaying debt
        Debug("wantEarned", wantEarned);

        // Pay off any debt
        // Debt is equal to negative of canBorrow
        uint256 toRepay = debtBelowHealth();
        Debug("toRepay", toRepay);
        uint256 repaid = toRepay >= wantEarned ? wantEarned : toRepay;
        Debug("repaid", repaid);

        uint256 earned = wantEarned.sub(repaid);
        Debug("earned", earned);

        if (repaid > 0) {
            want.safeApprove(address(LENDING_POOL), repaid);
            LENDING_POOL.repay(address(want), repaid, 2, address(this));
        }

        _profit = earned;
        Debug("_profit", _profit);

        // At the end want.balanceOf(address(this)) >= _debtOustanding as the Vault wants it back
        if (_debtOutstanding > 0) {
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
        if (wantAvailable > _debtOutstanding) {
            uint256 toDeposit = wantAvailable.sub(_debtOutstanding);
            want.safeApprove(address(LENDING_POOL), toDeposit);
            LENDING_POOL.deposit(address(want), toDeposit, address(this), 0);

            // Lever up
            _invest();
        }
    }

    function _claimRewardsAndGetMoreWant() internal {
        // Get rewards
        address[] memory assets = new address[](2);
        assets[0] = address(aToken);
        assets[1] = address(vToken);

        // Get Rewards, withdraw all
        IAaveIncentivesController(INCENTIVES_CONTROLLER).claimRewards(
            assets,
            type(uint256).max,
            address(this)
        );

        uint256 rewardsAmount = reward.balanceOf(address(this));
        Debug("rewardsAmount", rewardsAmount);

        if (rewardsAmount == 0) {
            return;
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
        Debug("aaveToSwap", aaveToSwap);

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

        // Lever Down
        _divestFromAAVE();
        // Withdraws all

        uint256 totalAssets = want.balanceOf(address(this));
        if (_amountNeeded > totalAssets) {
            _liquidatedAmount = totalAssets;
            _loss = _amountNeeded.sub(totalAssets);
        } else {
            _liquidatedAmount = _amountNeeded;
        }

        require(want.balanceOf(address(this)) >= _liquidatedAmount);
        require(_liquidatedAmount + _loss <= _amountNeeded);

        // Lever up again
        _invest();
    }

    // Withdraw all from AAVE Pool
    function liquidateAllPositions() internal override returns (uint256) {
        // Repay all debt and divest
        _divestFromAAVE();

        // TODO: earn here

        // TODO: Liquidate all positions and return the amount freed.
        return want.balanceOf(address(this));
    }

    // NOTE: Can override `tendTrigger` and `harvestTrigger` if necessary

    function prepareMigration(address _newStrategy) internal override {
        // TODO: Transfer any non-`want` tokens to the new strategy
        // NOTE: `migrate` will automatically forward all `want` in this strategy to the new one
        // This is gone if we use upgradeable

        //Divest all
        _divestFromAAVE();

        // TODO: Harvest rewards here

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

    /* Leverage functions */
    function deposited() public view returns (uint256) {
        return aToken.balanceOf(address(this));
    }

    function borrowed() public view returns (uint256) {
        return vToken.balanceOf(address(this));
    }

    // What should we repay?
    function debtBelowHealth() public view returns (uint256) {
        (
            uint256 totalCollateralETH,
            uint256 totalDebtETH,
            uint256 availableBorrowsETH,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        ) = LENDING_POOL.getUserAccountData(address(this));

        // How much did we go off of minHealth? //NOTE: We always borrow as much as we can
        uint256 maxBorrow = deposited().mul(ltv).div(MAX_BPS);

        if (healthFactor < minHealth && borrowed() > maxBorrow) {
            uint256 maxValue = borrowed().sub(maxBorrow);

            return maxValue;
        }

        return 0;
    }

    // NOTE: We always borrow max, no fucks given
    function canBorrow() public view returns (uint256) {
        (
            uint256 totalCollateralETH,
            uint256 totalDebtETH,
            uint256 availableBorrowsETH,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        ) = LENDING_POOL.getUserAccountData(address(this));

        if (healthFactor > minHealth) {
            // Amount = deposited * ltv - borrowed
            // Div MAX_BPS because because ltv / maxbps is the percent
            uint256 maxValue = deposited().mul(ltv).div(MAX_BPS).sub(
                borrowed()
            );

            // Don't borrow if it's dust, save gas
            if (maxValue < minRebalanceAmount) {
                return 0;
            }

            return maxValue;
        }

        return 0;
    }

    function _invest() internal {
        // Loop on it until it's properly done
        uint256 max_iterations = 5;
        for (uint256 i = 0; i < max_iterations; i++) {
            uint256 toBorrow = canBorrow();
            if (toBorrow > 0) {
                LENDING_POOL.borrow(
                    address(want),
                    toBorrow,
                    2,
                    0,
                    address(this)
                );

                want.safeApprove(address(LENDING_POOL), toBorrow);
                LENDING_POOL.deposit(address(want), toBorrow, address(this), 0);
            } else {
                return;
            }
        }
    }

    // Divest all from AAVE, awful gas, but hey, it works
    function _divestFromAAVE() internal {
        uint256 repayAmount = canRepay(); // The "unsafe" (below target health) you can withdraw

        // Loop to withdraw until you have the amount you need
        while (repayAmount != uint256(-1)) {
            _withdrawStepFromAAVE(repayAmount);
            repayAmount = canRepay();
        }
        if (deposited() > 0) {
            // Withdraw the rest here
            LENDING_POOL.withdraw(
                address(want),
                type(uint256).max,
                address(this)
            );
        }
    }

    //Take 95% of withdrawable, use that to repay AAVE
    function _withdrawStepFromAAVE(uint256 canRepay) internal {
        if (canRepay > 0) {
            //Repay this step
            LENDING_POOL.withdraw(address(want), canRepay, address(this));

            want.safeApprove(address(LENDING_POOL), canRepay);
            LENDING_POOL.repay(address(want), canRepay, 2, address(this));
        }
    }

    // returns 95% of the collateral we can withdraw from aave, used to loop and repay debts
    function canRepay() public view returns (uint256) {
        (
            uint256 totalCollateralETH,
            uint256 totalDebtETH,
            uint256 availableBorrowsETH,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        ) = LENDING_POOL.getUserAccountData(address(this));

        uint256 aBalance = deposited();
        uint256 vBalance = borrowed();

        if (vBalance == 0) {
            return uint256(-1); //You have repaid all
        }

        uint256 diff = aBalance.sub(
            vBalance.mul(10000).div(currentLiquidationThreshold)
        );
        uint256 inWant = diff.mul(95).div(100); // Take 95% just to be safe

        return inWant;
    }
}
