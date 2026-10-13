// SPDX-License-Identifier: MIT
// 开源许可证：MIT

pragma solidity 0.6.12;
// 编译器版本锁定 0.6.12

/**
 * 【接口声明】告诉编译器："外面有一个合约，它有这个方法"
 * 本文件只声明不实现——真正的实现在 multiSignature.sol 里
 */
interface IMultiSignature{
    /**
     * 查询某个哈希对应的"有效签名数/有效索引"
     * @param msghash   待校验的消息哈希（本项目中是"调用者地址 + 目标合约地址"的组合哈希）
     * @param lastIndex 起始查询位置
     * @return 有效签名索引。返回 0 表示"没通过审核"
     */
    function getValidSignature(bytes32 msghash,uint256 lastIndex) external view returns(uint256);
}

/**
 * ============================================================================
 *  multiSignatureClient —— 多签"客户端"基类（权限守门员的客户端）
 * ============================================================================
 *  【要解决的现实问题】
 *  合约里有些危险操作：改费率、改手续费地址、创建池子、结算、清算、增删 minter……
 *  如果这些操作靠"一个管理员私钥"就能做，那么私钥一旦泄露或管理员作恶，项目直接完蛋。
 *  解法：**多签（Multisig）**——把权限交给一个多签合约，需要 N 个成员中的 M 个签名同意
 *  才能执行（比如 2/3 多签）。没有足够签名，任何敏感操作都过不去。
 *
 *  【它怎么工作（两步）】
 *  1. 我要调用 `createPoolInfo()`（它带 validCall 修饰符）
 *  2. validCall 触发 checkMultiSignature()：向多签合约询问
 *     "针对『我这个地址 + 这个合约』的这次调用，你们批准了吗？"
 *     没批准 → require 失败，交易回滚。
 *
 *  【为什么用"哈希"而不是直接检查调用者？】
 *  哈希 = keccak256(调用者地址 + 本合约地址)，等于给"谁在调哪个合约的哪次操作"打上唯一指纹。
 *  多签成员在链下对这个指纹签名，链上再拿指纹去多签合约核对，两边对得上才放行。
 *
 *  【一个技术亮点：它把变量存在了"非常规位置"】
 *  见下面的 multiSignaturePositon 常量和 assembly 块——用的是类似 EIP-1967 的"插槽技巧"，
 *  目的是避免与子合约的存储变量发生位置冲突。
 *
 *  【谁继承了它】
 *  PledgePool、BscPledgeOracle、AddressPrivileges（→ DebtToken）都继承自它，
 *  所以这些合约里的敏感函数都能用 validCall 保护起来。
 * ============================================================================
 */
contract multiSignatureClient{
    // 一个"魔法数字"当作存储插槽的位置：keccak256 计算出的随机大数，
    // 用它当存储位置几乎不可能与普通变量的位置撞车，专门用来放多签地址
    uint256 private constant multiSignaturePositon = uint256(keccak256("org.multiSignature.storage"));
    // 默认索引 0：多签合约约定"返回 0"= 未批准
    uint256 private constant defaultIndex = 0;

    /**
     * 构造函数：把多签合约地址记下来
     * @param multiSignature 多签合约地址（不能是零地址，否则所有 validCall 都会失效/报错）
     */
    constructor(address multiSignature) public {
        require(multiSignature != address(0),"multiSignatureClient : Multiple signature contract address is zero!");
        // 用底层汇编把地址写进上面那个特殊插槽
        saveValue(multiSignaturePositon,uint256(multiSignature));
    }

    /**
     * 【读配置】返回本合约绑定的多签合约地址
     * public view：任何人都可以查询，用来核对多签地址是否正确
     */
    function getMultiSignatureAddress()public view returns (address){
        return address(getValue(multiSignaturePositon));   // 从特殊插槽读出来再转回地址
    }

    /**
     * 【核心修饰符】validCall —— 挂上它的函数必须获得多签批准才能执行
     * 全项目最常用的修饰符之一，看到它就等于看到"这是敏感操作"
     * 写法解读：`_;` 是被修饰函数的函数体插入点 → 先过 checkMultiSignature 才轮到业务逻辑
     */
    modifier validCall(){
        checkMultiSignature();
        _;
    }

    /**
     * 【校验逻辑】向多签合约询问"这次调用被批准了吗"
     *
     * 细节拆解：
     * 1. 用 assembly（内联汇编）读 callvalue() —— 即本次调用携带的原生币数量。
     *    这里读了赋值给 value，但后面并未使用（原设计可能想把金额也纳入签名范围，
     *    后来改为只用地址组合，属于代码演进留下的痕迹）。
     * 2. msgHash = keccak256(msg.sender + address(this))
     *    —— 给"谁调用哪个合约"打指纹。
     *    ⚠️ 注意指纹没包含函数名和参数，所以是"按调用者+合约"粒度批准的，
     *       同一调用者对本合约的任意敏感操作共用同一份批准（粒度较粗，是个值得注意的设计取舍）。
     * 3. 去多签合约问 getValidSignature(msgHash, 0)，返回 > 0 才算通过。
     * 4. 第 34、37 行被注释掉的代码，是"把已用过的索引存起来防止重复使用"的逻辑
     *    （防重放）。当前版本没启用，所以同一份批准理论上可以重复使用多次。
     *
     * 这段代码用 internal view：不写状态、不花 gas（被交易调用时仍需执行）
     */
    function checkMultiSignature() internal view {
        uint256 value;
        assembly {
            value := callvalue()    // 读本次调用附带的原生币金额（此处读完未使用）
        }
        bytes32 msgHash = keccak256(abi.encodePacked(msg.sender, address(this)));
        address multiSign = getMultiSignatureAddress();
//        uint256 index = getValue(uint256(msgHash));
        uint256 newIndex = IMultiSignature(multiSign).getValidSignature(msgHash,defaultIndex);
        require(newIndex > defaultIndex, "multiSignatureClient : This tx is not aprroved");
//        saveValue(uint256(msgHash),newIndex);
    }

    /**
     * 【写特殊插槽】用汇编 sstore 把 value 写进 position 位置的存储槽
     * 为什么用汇编？因为 Solidity 语法不允许给任意位置写值（普通变量位置由编译器决定）
     */
    function saveValue(uint256 position,uint256 value) internal
    {
        assembly {
            sstore(position, value)
        }
    }

    /**
     * 【读特殊插槽】用汇编 sload 从 position 位置读值
     */
    function getValue(uint256 position) internal view returns (uint256 value) {
        assembly {
            value := sload(position)
        }
    }
}
