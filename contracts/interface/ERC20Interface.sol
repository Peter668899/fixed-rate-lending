// SPDX-License-Identifier: MIT
// 开源许可证：MIT

pragma solidity 0.6.12;
// 编译器版本锁定 0.6.12


/**
 * ============================================================================
 *  ERC20Interface —— 极简 ERC20 接口（只声明了一个函数）
 * ============================================================================
 *  【只有一个函数？对，故意的】
 *  接口应该"按需声明"：用到什么就声明什么，不用的不写。
 *  本文件只被 library/SafeToken.sol 使用，而那里只用到了 balanceOf，
 *  所以这里就只声明 balanceOf —— 这是一种省事且不易出错的做法。
 *
 *  对比：interface/IERC20.sol 是完整的 ERC20 接口（transfer/approve/allowance...），
 *  供 SafeErc20 库使用。两个接口并存属于项目的历史演进痕迹。
 * ============================================================================
 */
interface ERC20Interface {
  function balanceOf(address user) external view returns (uint256);
  // 查某地址持有的代币数量
}
