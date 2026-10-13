// SPDX-License-Identifier: MIT
// 开源许可证声明：MIT 表示代码可自由使用/修改/分发（仅需保留版权声明）。
// 每个 Solidity 文件第一行都建议写这个，否则编译器会报警告。

pragma solidity 0.6.12;
// 指定编译器版本：必须恰好是 0.6.12（老版本语法与新版差异很大，锁死版本保证行为一致）

// ERC20：OpenZeppelin 提供的标准代币模板（转账、余额、授权、总供应量等都在里面）
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
// AddressPrivileges：本项目的"白名单管理员"合约，提供 onlyMinter 修饰符（谁能铸币/烧币）
import "./AddressPrivileges.sol";


/**
 * ============================================================================
 *  DebtToken —— Pledge 项目里的"借贷凭证代币"（spToken / jpToken 都是它）
 * ============================================================================
 *  【它是什么】
 *  一个标准的 ERC20 代币，但只有一件事特殊：**只能由被授权的 minter 铸造和销毁**。
 *
 *  【项目里有两种用途（同一个合约，部署两份）】
 *  1. spToken（deploy 时取名 spBUSD_1）= 贷款人的存款凭证
 *     - 贷款人存钱 → 结算后 mint 给他 → 到期他 burn 掉换回本息
 *  2. jpToken（deploy 时取名 jpBTC_1）= 借款人的抵押凭证
 *     - 借款人抵押 → 结算后 mint 给他 → 还清后他 burn 掉赎回抵押品
 *
 *  【为什么用 ERC20 做凭证？】
 *  因为是标准代币，就能直接进钱包、能在二级市场转让、能被其他协议识别。
 *  比如贷款人急用钱，未到期的 spToken 理论上可以卖掉换取现金。
 *
 *  【继承关系】
 *  DebtToken ──is──> ERC20            （有了全套代币功能）
 *             └──is──> AddressPrivileges （有了"谁有权铸币"的白名单）
 *                        └── multiSignatureClient （权限变更需多签批准）
 * ============================================================================
 */
contract DebtToken is ERC20, AddressPrivileges {

    /**
     * 构造函数：只在部署这一个合约时执行一次
     * @param _name            代币全名（如 "spBUSD_1"）
     * @param _symbol          代币简称（如 "spBUSD_1"）
     * @param multiSignature   多签管理合约地址（后续增删 minter 要经过它审批）
     */
    constructor(string memory _name, string memory _symbol, address multiSignature) public ERC20(_name, _symbol) AddressPrivileges(multiSignature) {
        // 函数体是空的：所有初始化都靠上面两个父构造函数完成
        // ERC20(_name, _symbol)          → 设置代币名称和简称
        // AddressPrivileges(...)         → 把多签地址存起来，决定谁能改权限
    }

    /**
      * @notice mint the token
      * @dev function to mint token for an asset
      * @param _to means receiving address
      * @param _amount means mint amount
      # @return true is success
      */
    /**
     * 【铸币】凭空创造代币并打入指定地址
     * 谁调用：只允许白名单里的 minter——实际上只有 PledgePool 合约会被加进白名单
     *         （因为凭证必须由借贷池按份额发放，不能让人随便印）
     * 用在哪：claimLend() 时给贷款人铸 spToken；claimBorrow() 时给借款人铸 jpToken
     *
     * @param _to     收币地址
     * @param _amount 铸造数量（注意：数量单位是该代币的最小单位，18 位小数）
     * @return 恒为 true（保留返回值只是为了兼容旧接口习惯）
     */
    function mint(address _to, uint256 _amount) public onlyMinter returns (bool) {
        // onlyMinter：修饰符，调用者不在白名单就直接 revert（回滚交易）
        _mint(_to, _amount);   // 父合约 ERC20 的内置函数：真正执行"铸造 + 记账"
        return true;
    }

    /**
      * @notice burn the token
      * @dev function to burn token for an asset
      * @param _from means destory address
      * @param _amount means destory amount
      # @return true is success
      */
    /**
     * 【销毁】从指定地址扣掉代币，让它永久消失（总供应量随之减少）
     * 这正是你前面答对的那一环：**"要销毁 spToken，才能换回本息"**
     * 用在哪：withdrawLend() 里先 burn 贷款人的 spToken 再付钱；
     *         withdrawBorrow() 里先 burn 借款人的 jpToken 再退抵押品。
     *
     * ⚠️ 安全设计要点：为什么不直接凭"你存过钱"的链上记录给钱，而要多一个代币？
     *    因为代币可转让。谁持有凭证，谁就有权赎回——合约只认代币，不认人。
     *    所以先 burn 后转账的顺序很重要：凭证消失了钱才出去，杜绝"一张凭证领两次"。
     *
     * @param _from   被销毁代币的地址（通常是操作者本人）
     * @param _amount 销毁数量
     * @return 恒为 true
     */
    function burn(address _from,uint256 _amount) public onlyMinter returns (bool) {
        // 同样受 onlyMinter 限制：只有质押池合约能销毁凭证
        _burn(_from, _amount);  // 父合约 ERC20 的内置函数：扣减余额 + 减少总供应量
        return true;
    }

}
