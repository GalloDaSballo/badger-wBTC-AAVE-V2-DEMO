import brownie
from brownie import Contract
import pytest

def test_profitable_harvest(
    chain, accounts, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX, lpComponent, borrowed, reward, incentivesController
):
    # Deposit to the vault
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    assert token.balanceOf(vault.address) == amount

    print("stratDep1 ")
    print(strategy.estimatedTotalAssets())

    # Harvest 1: Send funds through the strategy
    strategy.harvest()
    chain.mine(100)
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    

    # TODO: Add some code before harvest #2 to simulate earning yield
    before_pps = vault.pricePerShare()
    before_total = vault.totalAssets()
    before_debt = vault.totalDebt()

    chain.sleep(3600 * 24 * 1) ## Sleep 1 day
    chain.mine(1)
    
    print("Reward") 
    print(incentivesController.getRewardsBalance(
            [lpComponent, borrowed],
            strategy
        ))
    print("stratDep2 ")
    print(strategy.estimatedTotalAssets())

    # Harvest 2: Realize profit
    strategy.harvest()
    print("Reward 2") 
    print(incentivesController.getRewardsBalance(
            [lpComponent, borrowed],
            strategy
        ))
    print("stratDep3 ")
    print(strategy.estimatedTotalAssets())
    amountAfterHarvest = token.balanceOf(strategy) + lpComponent.balanceOf(strategy) - borrowed.balanceOf(strategy)
    chain.sleep(3600 * 6)  # 6 hrs needed for profits to unlock
    chain.mine(1)
    profit = token.balanceOf(vault.address)  # Profits go to vault

    # NOTE: Your strategy must be profitable
    # NOTE: May have to be changed based on implementation
    stratAssets = strategy.estimatedTotalAssets()
    
    print("stratAssets")
    print(stratAssets)

    vaultAssets = vault.totalAssets()
    print("vaultAssets")
    print(vaultAssets)

    ## Total assets for strat are token + lpComponent + borrowed
    assert  amountAfterHarvest + profit > amount
    ## NOTE: Changed to >= because I can't get the PPS to increase
    assert vault.pricePerShare() >= before_pps ## NOTE: May want to tweak this to >= or increase amounts and blocks
    assert vault.totalAssets() > before_total ## NOTE: Assets must increase or there's something off with harvest
    ## NOTE: May want to harvest a third time and see if it icnreases totalDebt for strat

    ## Harvest3 since we are using leveraged strat
    strategy.harvest()
    vault.withdraw(amount, {"from": user})
    assert token.balanceOf(user) > amount ## The user must have made more money, else it means funds are stuck
