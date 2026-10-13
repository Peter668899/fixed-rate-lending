
// SPDX-License-Identifier: MIT
// 开源许可证：MIT

pragma solidity 0.6.12;
// 编译器版本锁定 0.6.12

// SafeErc20：安全 ERC20 操作库（里面定义了 IERC20 接口和 safeTransfer 等方法）
import "./SafeErc20.sol";

/**
 * ============================================================================
 *  SafeTransfer —— 全项目的"收付款柜台"
 * ============================================================================
 *  【它在整个系统里的地位】
 *  这是最"底层"的一个合约，PledgePool 继承它之后，所有涉及资金进出的地方都只调用两个函数：
 *    getPayableAmount()  —— 收钱（把钱从用户钱包搬进合约）
 *    _redeem()           —— 付钱（把钱从合约转给某个地址）
 *  看懂这两个函数，整个项目的资金流向就没有秘密了。
 *
 *  【为什么要专门封装一层？两个真实原因】
 *  1. 兼容两种资产：ERC20 代币（BUSD/BTC）和原生币（BNB/ETH）。
 *     两者的转账方式完全不同——代币要调 transferFrom，原生币直接 transfer。
 *     用 address(0) 当"暗号"来区分：lendToken 地址是 0 就表示"这个池子收原生币"。
 *  2. 防"假成功"：ERC20 标准对转账失败的处理并不统一，有的代币失败返回 false 而不报错。
 *     safeTransfer 会同时检查返回值和是否 revert，避免"钱没转成功但程序以为成功了"。
 * ============================================================================
 */
contract SafeTransfer{

    // 把 SafeERC20 库的方法挂到 IERC20 类型上，之后可以写 token.safeTransfer(...)
    using SafeERC20 for IERC20;
    // 事件：只要发生一次转账（_redeem），链上就留一条记录，方便后端/区块浏览器追踪
    event Redeem(address indexed recieptor,address indexed token,uint256 amount);

    /**
     * @notice  transfers money to the pool
     * @dev function to transfer
     * @param token of address
     * @param amount of amount
     * @return return amount
     */
    /**
     * 【收钱】把用户的钱搬进合约（PledgePool 里 depositLend / depositBorrow 的 L251/L385 调它）
     *
     * @param token  收款币种地址。传 address(0) 表示"收原生币 BNB/ETH"
     * @param amount 用户想付的金额（ERC20 场景）
     * @return 实际收到的金额——原生币场景返回 msg.value，ERC20 场景原样返回 amount
     *
     * ⚠️ 前置条件：ERC20 场景下，用户必须**事先**授权本合约可以动他的币（approve），
     *    否则 safeTransferFrom 会失败。这就是前端通常要"先授权、再存款"的原因。
     */
    function getPayableAmount(address token,uint256 amount) internal returns (uint256) {
        if (token == address(0)){
            // —— 原生币分支 ——
            // 原生币没有 transferFrom 这种玩法。用户发交易时钱就已经随 msg.value 一起送过来了，
            // 此刻钱其实已经躺在合约账上，所以这里只需把 msg.value 当作"实收金额"记下来。
            amount = msg.value;
        }else if (amount > 0){
            // —— ERC20 分支 ——
            // 这个分支才是真正"把钱搬进来"的动作。
            // safeTransferFrom(从谁, 给谁, 多少)：
            //   从 msg.sender 的余额 → 转到 address(this)（也就是本合约自己）
            // 内部会检查授权额度是否足够、余额是否足够、返回值是否正常
            IERC20 oToken = IERC20(token);
            oToken.safeTransferFrom(msg.sender, address(this), amount);
        }
        // 注意 amount 为 0 的 ERC20 情况：跳过转账直接返回 0，
        // 由调用方（如 depositBorrow 的 require(amount > 0)）负责拦下
        return amount;
    }

    /**
     * @dev An auxiliary foundation which transter amount stake coins to recieptor.
     * @param recieptor account.
     * @param token address
     * @param amount redeem amount.
     */
    /**
     * 【付钱】把合约里的钱转给指定地址（退款、赎回、提取、发手续费都走这里）
     *
     * @param recieptor 收款地址（注意类型是 address payable，原生币转账要求收款方能收钱）
     * @param token     付款币种，address(0) 表示付原生币
     * @param amount    付款金额
     *
     * 全项目调用它的场景：
     *   refundLend/refundBorrow        退还未匹配的资金
     *   withdrawLend/withdrawBorrow    赎回本息/抵押品
     *   emergencyLendWithdrawal        撮合失败退款
     *   finish/liquidate 中付手续费给 feeAddress
     */
    function _redeem(address payable recieptor,address token,uint256 amount) internal{
        if (token == address(0)){
            // 原生币：transfer 只转发 2300 gas，接收方无法执行复杂逻辑，
            // 这实际上是一种"防重入"的额外保险（但也意味着合约地址收款可能失败）
            recieptor.transfer(amount);
        }else{
            // ERC20：走安全转账，失败会 revert
            IERC20 oToken = IERC20(token);
            oToken.safeTransfer(recieptor,amount);
        }
        // 无论哪种币，都抛一个 Redeem 事件出来（后端可用它统计资金流出）
        emit Redeem(recieptor,token,amount);
    }
}
