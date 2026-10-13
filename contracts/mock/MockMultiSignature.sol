// SPDX-License-Identifier: MIT
// 开源许可证：MIT

pragma solidity =0.6.12;
// 编译器版本锁定 0.6.12

/**
 * ============================================================================
 *  MockMultiSignature —— 测试用的"假多签"
 * ============================================================================
 *  【它做了什么"假"事】
 *  getValidSignature() 永远返回 defaultIndex(1)，也就是"永远批准"。
 *
 *  【为什么测试要这样设计】
 *  PledgePool 里所有管理员函数都带 validCall（需要多签批准）。
 *  如果在测试环境还用真多签，那每个 createPoolInfo / settle 之前都要：
 *  发起申请 → 多个账户签名 → 再执行，测试会变得极其繁琐。
 *  换成这个 Mock，所有敏感操作直接放行，测试就能专注在业务逻辑上。
 *
 *  ⚠️ 【极其重要的一点】
 *  这意味着**测试通过 ≠ 生产可用**：
 *  真实部署时多签门槛、成员名单、审批流程都必须单独验证，
 *  否则可能出现"代码测试全绿，上线后管理员操作全部被卡住"的事故。
 *
 *  【与真实 multiSignature 的关系】
 *  两者都实现了同一个查询接口 getValidSignature(msghash, lastIndex)，
 *  所以可以被无缝替换——这就是"依赖接口而非实现"的好处。
 * ============================================================================
 */
contract MockMultiSignature {
    // 门槛设为 1（本 Mock 中无实际作用，仅保持与真实版结构相似）
    uint256 public threshold = 1;
    // 永远返回这个值，表示"签名有效"
    uint256 public defaultIndex = 1;
    
    /**
     * 【永远批准】无论查什么哈希，都返回 1（> 0 即视为通过）
     */
    function getValidSignature(bytes32 msghash, uint256 lastIndex) external view returns (uint256) {
        // Always return a valid signature for testing purposes
        return defaultIndex;
    }
}
