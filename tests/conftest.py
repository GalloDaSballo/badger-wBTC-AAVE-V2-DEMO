import pytest
from brownie import config
from brownie import Contract

@pytest.fixture
def gov(accounts):
    yield accounts.at("0xFEB4acf3df3cDEA7399794D0869ef76A6EfAff52", force=True)


@pytest.fixture
def user(accounts):
    yield accounts[0]


@pytest.fixture
def rewards(accounts):
    yield accounts[1]


@pytest.fixture
def guardian(accounts):
    yield accounts[2]


@pytest.fixture
def management(accounts):
    yield accounts[3]


@pytest.fixture
def strategist(accounts):
    yield accounts[4]


@pytest.fixture
def keeper(accounts):
    yield accounts[5]


@pytest.fixture
def token():
    # TODO: Change to your want
    token_address = "0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599"  # this should be the address of the ERC-20 used by the strategy/vault (DAI)
    yield Contract(token_address)

@pytest.fixture
def lpComponent():
    # TODO: Change to your want
    token_address = "0x9ff58f4ffb29fa2266ab25e75e2a8b3503311656"  # this should be the address of the ERC-20 used by the strategy/vault (DAI)
    yield Contract(token_address)

@pytest.fixture
def borrowed():
    # TODO: Change to your borrowed (For leveraged strats)
    token_address = "0x9c39809Dec7F95F5e0713634a4D0701329B3b4d2"  # this should be the address of the ERC-20 used by the strategy/vault (DAI)
    yield Contract(token_address)


@pytest.fixture
def incentivesController():
    token_address = "0xd784927Ff2f95ba542BfC824c8a8a98F3495f6b5"
    yield Contract(token_address)

@pytest.fixture
def reward():
    # TODO: Change to your want
    token_address = "0x4da27a545c0c5b758a6ba100e3a049001de870f5"  # this should be the address of the ERC-20 used by the strategy/vault (DAI)
    yield Contract(token_address)

@pytest.fixture
def amount(accounts, token, user):
    ## TODO: Change amount to something that is big but makes sense
    amount = 1000 * 10 ** token.decimals()
    # In order to get some funds for the token you are about to use,
    # it impersonate an exchange address to use it's funds.
    # TODO: Change to a contract with your want
    reserve = accounts.at("0x9ff58f4fFB29fA2266Ab25e75e2A8b3503311656", force=True)
    token.transfer(user, amount, {"from": reserve})
    yield amount


@pytest.fixture
def weth():
    token_address = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"
    yield Contract(token_address)


@pytest.fixture
def weth_amout(user, weth):
    weth_amout = 10 ** weth.decimals()
    user.transfer(weth, weth_amout)
    yield weth_amout


@pytest.fixture
def vault(pm, gov, rewards, guardian, management, token):
    Vault = pm(config["dependencies"][0]).Vault
    vault = guardian.deploy(Vault)
    vault.initialize(token, gov, rewards, "", "", guardian, management)
    vault.setDepositLimit(2 ** 256 - 1, {"from": gov})
    vault.setManagement(management, {"from": gov})
    yield vault


@pytest.fixture
def strategy(strategist, keeper, vault, Strategy, gov):
    strategy = strategist.deploy(Strategy, vault)
    strategy.setKeeper(keeper)
    vault.addStrategy(strategy, 10_000, 0, 2 ** 256 - 1, 1_000, {"from": gov})
    yield strategy


@pytest.fixture(scope="session")
def RELATIVE_APPROX():
    yield 1e-5