// SPDX-License-Identifier: MIT
// 开源许可证：MIT

pragma solidity 0.6.12;
// 编译器版本锁定 0.6.12


// SafeMath：安全算术库（0.6.x 没有内置溢出检查，加减乘除都要靠它）
import "./SafeMath.sol";
// Address：地址工具库（判断是不是合约、低级调用等）
import "./Address.sol";
// IERC20：标准 ERC20 接口
import "../interface/IERC20.sol";


/**
 * @title SafeERC20
 * @dev Wrappers around ERC20 operations that throw on failure (when the token
 * contract returns false). Tokens that return no value (and instead revert or
 * throw on failure) are also supported, non-reverting calls are assumed to be
 * successful.
 * To use this library you can add a `using SafeERC20 for IERC20;` statement to your contract,
 * which allows you to call the safe operations as `token.safeTransfer(...)`, etc.
 */
/**
 * ============================================================================
 *  SafeERC20 —— 安全 ERC20 操作库（本项目实际使用的转账库）
 * ============================================================================
 *  【这个文件是"借来的标准件"】
 *  它取自 OpenZeppelin 的 SafeERC20（社区使用最广的安全库之一），几乎没有改动。
 *  因此不需要逐行精读，理解它解决的问题即可：
 *
 *  【问题：ERC20 标准本身有个历史坑】
 *  标准规定 transfer/approve 成功要返回 true、失败返回 false。但现实中有两类"不听话"的代币：
 *    - 有的失败时不返回 false，而是直接 revert（如 BNB 上的部分代币）
 *    - 有的干脆什么都不返回（早期 TUSD 等）
 *  如果合约用普通写法 `require(token.transfer(...))`，遇到"不返回值的代币"会直接编译/运行报错，
 *  遇到"返回 false 当失败"的又可能被忽略——钱就悄悄丢了。
 *
 *  【解法：低级调用 + 灵活校验返回值】
 *  所有操作都走 _callOptionalReturn：
 *    - 用低级 call 发出转账请求（绕过编译器的返回值类型检查）
 *    - 调用后检查：返回值要么为空（当成成功），要么必须解码为 true
 *  这样三种"性格"的代币都能安全处理。
 *
 *  【本项目的使用方式】
 *  SafeTransfer.sol 里写了 `using SafeERC20 for IERC20;`，
 *  于是 PledgePool 的收付款最终都落在这里的 safeTransfer / safeTransferFrom 上。
 * ============================================================================
 */
library SafeERC20 {
    // 把 SafeMath 的加减乘除挂到 uint256 上，方便写 a.add(b)
    using SafeMath for uint256;
    // 把 Address 的方法挂到 address 上，方便写 addr.functionCall(...)
    using Address for address;

    /**
     * 【安全转账】把 token 的 value 数量转给 to
     * 内部把调用数据编码成 transfer(to,value) 再发出去
     * token.transfer.selector 就是函数选择器（等价于手写 0xa9059cbb）
     */
    function safeTransfer(IERC20 token, address to, uint256 value) internal {
        _callOptionalReturn(token, abi.encodeWithSelector(token.transfer.selector, to, value));
    }

    /**
     * 【安全代转】从 from 转 value 给 to（需要 from 提前 approve 授权）
     * 这是 PledgePool 把用户的钱搬进合约时实际执行的那一句
     */
    function safeTransferFrom(IERC20 token, address from, address to, uint256 value) internal {
        _callOptionalReturn(token, abi.encodeWithSelector(token.transferFrom.selector, from, to, value));
    }

    /**
     * @dev Deprecated. This function has issues similar to the ones found in
     * {IERC20-approve}, and its usage is discouraged.
     *
     * Whenever possible, use {safeIncreaseAllowance} and
     * {safeDecreaseAllowance} instead.
     */
    /**
     * 【安全授权】批准 spender 可以花掉本合约的 value 个代币
     * ⚠️ 官方已标记为 Deprecated（不推荐）：它要求"从非零额度改成非零额度"时必须先清零，
     *    否则容易被"授权竞态"攻击（对方抢在额度变更前花掉旧额度）。新代码请用下面两个增量函数。
     */
    function safeApprove(IERC20 token, address spender, uint256 value) internal {
        // safeApprove should only be called when setting an initial allowance,
        // or when resetting it to zero. To increase and decrease it, use
        // 'safeIncreaseAllowance' and 'safeDecreaseAllowance'
        // solhint-disable-next-line max-line-length
        require((value == 0) || (token.allowance(address(this), spender) == 0),
            "SafeERC20: approve from non-zero to non-zero allowance"
        );
        _callOptionalReturn(token, abi.encodeWithSelector(token.approve.selector, spender, value));
    }

    /**
     * 【增加授权】在现有额度上追加 value（不会触发上面的清零限制）
     * 项目里给 Uniswap 路由授权卖抵押品时可能用到
     */
    function safeIncreaseAllowance(IERC20 token, address spender, uint256 value) internal {
        uint256 newAllowance = token.allowance(address(this), spender).add(value);   // 先读旧额度再加
        _callOptionalReturn(token, abi.encodeWithSelector(token.approve.selector, spender, newAllowance));
    }

    /**
     * 【减少授权】从现有额度里扣掉 value（SafeMath 的 sub 会防止减成负数）
     */
    function safeDecreaseAllowance(IERC20 token, address spender, uint256 value) internal {
        uint256 newAllowance = token.allowance(address(this), spender).sub(value);
        _callOptionalReturn(token, abi.encodeWithSelector(token.approve.selector, spender, newAllowance));
    }

    /**
     * @dev Imitates a Solidity high-level call (i.e. a regular function call to a contract), relaxing the requirement
     * on the return value: the return value is optional (but if data is returned, it must not be false).
     * @param token The token targeted by the call.
     * @param data The call data (encoded using abi.encode or one of its variants).
     */
    /**
     * 【统一的低级调用 + 返回值校验】上面所有函数最终都汇聚到这里
     * @param token 目标代币合约
     * @param data  已经拼好的调用数据（哪个函数、什么参数）
     *
     * 两步校验：
     *  1. functionCall：调用了目标地址，并确认返回成功（Address 库内部还会检查目标是不是合约）
     *  2. 如果返回了数据，就把第一个返回值解码成 bool 并要求为 true
     *     —— 兼容"啥都不返回"的老代币（returndata.length == 0 时跳过检查）
     */
    function _callOptionalReturn(IERC20 token, bytes memory data) private {
        // We need to perform a low level call here, to bypass Solidity's return data size checking mechanism, since
        // we're implementing it ourselves. We use {Address.functionCall} to perform this call, which verifies that
        // the target address contains contract code and also asserts for success in the low-level call.

        bytes memory returndata = address(token).functionCall(data, "SafeERC20: low-level call failed");
        if (returndata.length > 0) { // Return data is optional
            // solhint-disable-next-line max-line-length
            require(abi.decode(returndata, (bool)), "SafeERC20: ERC20 operation did not succeed");
        }
    }
}
