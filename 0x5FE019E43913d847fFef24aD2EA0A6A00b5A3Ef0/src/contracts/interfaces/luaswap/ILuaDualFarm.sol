// SPDX-License-Identifier: MIT

pragma solidity ^0.7.0;

interface ILuaDualFarm {
    function poolLength() external view returns (uint256);
    function pendingReward(uint256 _pid, address _user) external view returns (uint256);
    function pendingLuaReward(uint256 _pid, address _user) external view returns (uint256);

    function deposit(uint256 _pid, uint256 _amount) external;
    function withdraw(uint256 _pid, uint256 _amount) external;
    function emergencyWithdraw(uint256 _pid) external;
    function claimReward(uint256 _pid) external;
    function userInfo(uint256 _pid, address _user) external view returns (uint256, uint256, uint256, uint256);
}
