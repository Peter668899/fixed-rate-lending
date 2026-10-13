// SPDX-License-Identifier: MIT
// 开源许可证：MIT

pragma solidity 0.6.12;
// 编译器版本锁定 0.6.12


// ERC20Interface：一个极简的 ERC20 接口，只声明了本库需要的函数
import "../interface/ERC20Interface.sol";

/**
 * ============================================================================
 *  SafeToken —— 用"底层调用"方式操作 ERC20 的工具库
 * ============================================================================
 *  【它和 SafeErc20.sol 的区别】
 *  这个项目里有两套功能类似的库（SafeToken 和 SafeErc20），都是做安全转账的：
 *    - SafeErc20.sol  用 Solidity 语法糖：token.safeTransfer(to, value)
 *    - SafeToken.sol  用更原始的"手工拼装调用数据"方式：token.call(abi.encodeWithSelector(...))
 *  两套并存属于历史遗留（代码在演进中重复造了轮子）。**PledgePool 实际用的是 SafeErc20**，
 *  本文件在核心流程里没有被调用；读代码时知道它是"备胎/遗留"即可。
 *
 *  【library 是什么】
 *  library 类似"静态工具类"：不能存状态变量、不能被继承、可以内联进调用方以省 gas。
 *  它的 internal 函数在编译时会直接嵌到调用者的代码里——所以叫 internal 表示"只给内部用"。
 *
 *  【本文件最值得学的知识点：为什么不用 token.transfer(...) 而要手工拼字节？】
 *  Solidity 里调用别的合约有两种方式：
 *    1. 高级写法：IERC20(token).transfer(to, value)  —— 编译器帮忙拼数据，但要求接口定义完全匹配
 *    2. 低级写法：token.call(abi.encodeWithSelector(函数选择器, 参数...))  —— 手工拼原始字节
 *  低级写法的好处是"不依赖接口定义"，连 ABI 都不匹配的怪代币也能调；
 *  代价是必须自己检查返回值，否则失败会被"悄悄吞掉"。
 *  下面每个函数都用 `require(success && ...)` 补上这个检查，这就是"safe"二字的由来。
 * ============================================================================
 */
library SafeToken {
  /**
   * 【查自己的余额】查本合约持有多少该代币
   * 用途：比如判断池子里到底还有多少 BUSD 可以分给贷款人
   */
  function myBalance(address token) internal view returns (uint256) {
    return ERC20Interface(token).balanceOf(address(this));   // address(this) = 本合约自身地址
  }

  /**
   * 【查别人的余额】查任意地址持有多少该代币
   */
  function balanceOf(address token, address user) internal view returns (uint256) {
    return ERC20Interface(token).balanceOf(user);
  }

  /**
   * 【安全授权】批准 to 地址可以从本合约转走 value 数量的代币
   * 0x095ea7b3 是 approve(address,uint256) 这个函数的"身份证号"（函数选择器）：
   *   keccak256("approve(address,uint256)") 取前 4 字节
   * 为什么需要授权？—— 合约要去 Uniswap 卖抵押品（BTC 换 BUSD）时必须先授权路由合约
   */
  function safeApprove(address token, address to, uint256 value) internal {
    // bytes4(keccak256(bytes('approve(address,uint256)')));
    (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0x095ea7b3, to, value));
    // 两道检查：
    //   success            —— 调用本身有没有 revert
    //   data.length == 0 || abi.decode(...) —— 有的代币返回空（老标准 TUSD 等），
    //                        有的返回 bool；两种都要兼容。返回 false 也要判为失败
    require(success && (data.length == 0 || abi.decode(data, (bool))), "!safeApprove");
  }

  /**
   * 【安全转账】把本合约的 value 个代币转给 to
   * 0xa9059cbb = keccak256("transfer(address,uint256)") 前 4 字节
   */
  function safeTransfer(address token, address to, uint256 value) internal {
    // bytes4(keccak256(bytes('transfer(address,uint256)')));
    (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0xa9059cbb, to, value));
    require(success && (data.length == 0 || abi.decode(data, (bool))), "!safeTransfer");
  }

  /**
   * 【安全代转】从 from 地址转 value 个代币给 to 地址（需要 from 事先授权）
   * 0x23b872dd = keccak256("transferFrom(address,address,uint256)") 前 4 字节
   * 这是"把钱从用户钱包搬进合约"最常用的一招
   */
  function safeTransferFrom(address token, address from, address to, uint256 value) internal {
    // bytes4(keccak256(bytes('transferFrom(address,address,uint256)')));
    (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0x23b872dd, from, to, value));
    require(success && (data.length == 0 || abi.decode(data, (bool))), "!safeTransferFrom");
  }


}
