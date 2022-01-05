// SPDX-License-Identifier: MIT

pragma solidity ^0.7.1;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

import "../interfaces/IStrategy.sol";
import "../interfaces/luaswap/IUniswapV2Router.sol";
import "../interfaces/luaswap/IUniswapV2Pair.sol";
import "../interfaces/luaswap/ILuaDualFarm.sol";

contract LuaDualFarmStrategy is IStrategy, Ownable, Pausable {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    // Fees
    uint256 public constant WITHDRAWAL_FEE = 1;
    uint256 public constant WITHDRAWAL_MAX = 1000;

    uint256 public constant PERFORMANCE_FEE = 5;
    uint256 public constant PERFORMANCE_MAX = 100;

    // Addresses
    address public constant TREASURY_ADDRESS =
        address(0xA35Cb982d528eBF0E7e020F277EC179b0F63DC3A);
    address public constant HARVESTER_ADDRESS =
        address(0xbb55057D1e63C19A63FDE900cb4D34a6DD1299AA);

    // Contracts
    address public constant LUA_SWAP =
        address(0x0b792a01Fd3E8b3e23aaaA28561c3E774A82AA7b);
    address public luaMaster;

    // Tokens
    address public constant WRAPPED_TOMO =
        address(0xB1f66997A5760428D3a87D68b90BfE0aE64121cC);
    address public constant LUA_TOKEN =
        address(0x7262fa193e9590B2E075c3C16170f3f2f32F5C74);

    address public rewardToken;
    address public want;
    address public lpToken0;
    address public lpToken1;
    address public immutable vault;
    uint256 public immutable poolId;

    // Routes
    address[] public luaRouteToLp0;
    address[] public luaRouteToLp1;
    address[] public rewardRouteToLp0;
    address[] public rewardRouteToLp1;

    constructor(
        address _luaMaster,
        address _want,
        uint256 _poolId,
        address _vault,
        address _rewardToken,
        address[] memory _luaRouteToLp0,
        address[] memory _luaRouteToLp1,
        address[] memory _rewardRouteToLp0,
        address[] memory _rewardRouteToLp1
    ) {
        luaMaster = _luaMaster;
        want = _want;
        poolId = _poolId;
        vault = _vault;
        rewardToken = _rewardToken;

        lpToken0 = IUniswapV2Pair(want).token0();
        lpToken1 = IUniswapV2Pair(want).token1();

        luaRouteToLp0 = _luaRouteToLp0;
        luaRouteToLp1 = _luaRouteToLp1;

        rewardRouteToLp0 = _rewardRouteToLp0;
        rewardRouteToLp1 = _rewardRouteToLp1;

        _giveAllowances();
    }

    // puts the funds to work
    function deposit() public override whenNotPaused {
        uint256 wantBal = IERC20(want).balanceOf(address(this));

        if (wantBal > 0) {
            ILuaDualFarm(luaMaster).deposit(poolId, wantBal);
        }
    }

    function withdraw(uint256 _amount) external override {
        require(msg.sender == vault, "!vault");

        uint256 wantBal = IERC20(want).balanceOf(address(this));

        if (wantBal < _amount) {
            ILuaDualFarm(luaMaster).withdraw(poolId, _amount.sub(wantBal));
            wantBal = IERC20(want).balanceOf(address(this));
        }

        if (wantBal > _amount) {
            wantBal = _amount;
        }

        if (msg.sender == owner() || paused()) {
            IERC20(want).safeTransfer(vault, wantBal);
        } else {
            uint256 withdrawalFeeAmount = wantBal.mul(WITHDRAWAL_FEE).div(
                WITHDRAWAL_MAX
            );
            IERC20(want).safeTransfer(vault, wantBal.sub(withdrawalFeeAmount));
        }
    }

    // compounds earnings and charges performance fee
    function harvest() external override whenNotPaused {
        require(msg.sender == HARVESTER_ADDRESS, "!harvester");

        ILuaDualFarm(luaMaster).claimReward(poolId);
        chargeFees();
        addLiquidity();
        deposit();
    }

    // performance fees
    function chargeFees() internal {
        uint256 rewardPerformanceFee = IERC20(rewardToken)
            .balanceOf(address(this))
            .mul(PERFORMANCE_FEE)
            .div(PERFORMANCE_MAX);
        IERC20(rewardToken).safeTransfer(
            TREASURY_ADDRESS,
            rewardPerformanceFee
        );

        uint256 luaPerformanceFee = IERC20(LUA_TOKEN)
            .balanceOf(address(this))
            .mul(PERFORMANCE_FEE)
            .div(PERFORMANCE_MAX);
        IERC20(LUA_TOKEN).safeTransfer(TREASURY_ADDRESS, luaPerformanceFee);
    }

    // Adds liquidity to AMM and gets more LP tokens.
    function addLiquidity() internal {
        uint256 rewardHalf = IERC20(rewardToken).balanceOf(address(this)).div(
            2
        );
        swapLpRoute(rewardRouteToLp0, rewardHalf);
        swapLpRoute(rewardRouteToLp1, rewardHalf);

        uint256 luaHalf = IERC20(LUA_TOKEN).balanceOf(address(this)).div(2);
        swapLpRoute(luaRouteToLp0, luaHalf);
        swapLpRoute(luaRouteToLp1, luaHalf);

        uint256 lp0Bal = IERC20(lpToken0).balanceOf(address(this));
        uint256 lp1Bal = IERC20(lpToken1).balanceOf(address(this));
        IUniswapV2Router(LUA_SWAP).addLiquidity(
            lpToken0,
            lpToken1,
            lp0Bal,
            lp1Bal,
            0,
            0,
            address(this),
            block.timestamp
        );
    }

    function swapLpRoute(address[] storage route, uint256 amount) internal {
        if (route.length > 1) {
            IUniswapV2Router(LUA_SWAP).swapExactTokensForTokens(
                amount,
                0,
                route,
                address(this),
                block.timestamp
            );
        }
    }

    // calculate the total underlaying 'want' held by the strat.
    function balanceOf() public view override returns (uint256) {
        return balanceOfWant().add(balanceOfPool());
    }

    // it calculates how much 'want' this contract holds.
    function balanceOfWant() public view override returns (uint256) {
        return IERC20(want).balanceOf(address(this));
    }

    // it calculates how much 'want' the strategy has working in the farm.
    function balanceOfPool() public view override returns (uint256) {
        (uint256 _amount, , , ) = ILuaDualFarm(luaMaster).userInfo(
            poolId,
            address(this)
        );
        return _amount;
    }

    // called as part of strat migration. Sends all the available funds back to the vault.
    function retireStrat() external override {
        require(msg.sender == vault, "!vault");

        ILuaDualFarm(luaMaster).emergencyWithdraw(poolId);

        uint256 wantBal = IERC20(want).balanceOf(address(this));
        IERC20(want).transfer(vault, wantBal);
    }

    // pauses deposits and withdraws all funds from third party systems.
    function panic() public override onlyOwner {
        pause();
        ILuaDualFarm(luaMaster).emergencyWithdraw(poolId);
    }

    function pause() public override onlyOwner {
        _pause();

        _removeAllowances();
    }

    function unpause() external override onlyOwner {
        _unpause();

        _giveAllowances();

        deposit();
    }

    function _giveAllowances() internal {
        _removeAllowances();

        IERC20(want).safeApprove(luaMaster, type(uint256).max);
        IERC20(rewardToken).safeApprove(LUA_SWAP, type(uint256).max);
        IERC20(LUA_TOKEN).safeApprove(LUA_SWAP, type(uint256).max);

        if (IERC20(lpToken0).allowance(address(this), LUA_SWAP) == 0) {
            IERC20(lpToken0).safeApprove(LUA_SWAP, type(uint256).max);
        }

        if (IERC20(lpToken1).allowance(address(this), LUA_SWAP) == 0) {
            IERC20(lpToken1).safeApprove(LUA_SWAP, type(uint256).max);
        }
    }

    function _removeAllowances() internal {
        IERC20(want).safeApprove(luaMaster, 0);
        IERC20(rewardToken).safeApprove(LUA_SWAP, 0);
        IERC20(LUA_TOKEN).safeApprove(LUA_SWAP, 0);
        IERC20(lpToken0).safeApprove(LUA_SWAP, 0);
        IERC20(lpToken1).safeApprove(LUA_SWAP, 0);
    }

    /**
     * @dev Ability to return stuck funds to the vault
     * @param _token address of the token to rescue.
     */
    function inCaseTokensGetStuck(address _token) external onlyOwner {
        uint256 amount = IERC20(_token).balanceOf(address(this));
        IERC20(_token).safeTransfer(vault, amount);
    }
}
