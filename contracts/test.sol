//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;


// interface IERC20 {
//     function balanceOf(address) view external returns (uint);
//     function approve(address,uint) external returns (bool);
// }

interface yCredit {
  function deposit(address token, uint amount) external;
  function withdraw(address token, uint amount) external;
  function withdrawAll(address token) external;
  function balanceOf(address) external view returns (uint);
  function stake(uint256 amount) external;
  function approve(address, uint) external returns (bool);
}

interface Router {
  function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
    function getAmountsOut(uint amountIn, address[] memory path)
        external
        view
        returns (uint[] memory amounts);
}