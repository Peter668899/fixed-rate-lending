// SPDX-License-Identifier: MIT
// 开源许可证：MIT

pragma solidity 0.6.12;
// 编译器版本锁定 0.6.12

/**
 * ============================================================================
 *  IDebtToken —— 凭证代币接口（spToken / jpToken 的"使用说明书"）
 * ============================================================================
 *  【interface 是什么】
 *  只声明函数签名、不写实现。它的作用是告诉编译器："外面有个合约有这些方法"，
 *  于是你就能把某个地址"套"成这个类型来调用：
 *      IDebtToken(spToken地址).mint(用户, 数量)
 *
 *  【为什么 PledgePool 通过接口调用，而不直接 import DebtToken 合约？】
 *  1. 解耦：质押池不需要知道凭证代币内部怎么实现，只要知道"能 mint、能 burn"
 *  2. 省体积：不必把整个 DebtToken 的代码编进 PledgePool，部署更便宜
 *  3. 可替换：将来换一个功能更强的凭证合约，只要接口一致，PledgePool 不用改
 *
 *  【在本项目中的实际用法】
 *  PledgePool 里 pool.spCoin / pool.jpCoin 就是这种类型：
 *    claimLend()  → spCoin.mint(贷款人, 份额)   发放存款凭证
 *    withdrawLend() → spCoin.burn(贷款人, 份额) 销毁存款凭证换回本息
 *    claimBorrow()  → jpCoin.mint(借款人, 份额)
 *    withdrawBorrow() → jpCoin.burn(借款人, 份额)
 *
 *  真实实现见 pledge/DebtToken.sol（继承 ERC20 + AddressPrivileges，带 onlyMinter 白名单）。
 *  注意：真实实现的 mint/burn 会 return bool，而接口这里没有声明返回值——
 *        这没问题，Solidity 允许调用方忽略返回值。
 * ============================================================================
 */
interface IDebtToken {
     /**
     * @dev Returns the amount of tokens owned by `account`.
     */
    function balanceOf(address account) external view returns (uint256);
    // 查某人有多少凭证代币（只读）

     /**
     * @dev Returns the amount of tokens in existence.
     */
    function totalSupply() external view returns (uint256);
    // 查凭证总发行量（只读）。注意：这个值恒等于池子的 settleAmountLend

     /**
     * @dev Minting tokens for specific accounts.
     */
    function mint(address account, uint256 amount) external;
    // 铸币（只能由 minter 白名单里的地址调用，也就是 PledgePool 合约）

     /**
     * @dev Burning tokens for specific accounts.
     */
    function burn(address account, uint256 amount) external;
    // 销毁（同样受 minter 白名单限制）

}
