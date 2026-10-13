// SPDX-License-Identifier: MIT
// 开源许可证：MIT
pragma solidity 0.6.12;
// 编译器版本锁定 0.6.12

// multiSignatureClient：多签客户端基类，提供 validCall 修饰符（本文件权限控制的核心）
import "../multiSignature/multiSignatureClient.sol";
// EnumerableSet：OpenZeppelin 提供的"可遍历集合"工具，这里是用来存一张能增删、能遍历、能判重的地址名单
import "@openzeppelin/contracts/utils/EnumerableSet.sol";

/**
 * @dev Collection of functions related to the address type
 */
/**
 * ============================================================================
 *  AddressPrivileges —— "谁能铸币"的白名单合约
 * ============================================================================
 *  【它解决什么问题】
 *  spToken / jpToken 是凭空铸造出来的代币。如果谁都能铸，那就是印钞机，项目瞬间归零。
 *  所以需要一份**名单**：只有名单里的地址（Minter）才有资格铸币和销毁。
 *  本合约就是管这份名单的。
 *
 *  【为什么用 EnumerableSet 而不是数组？】
 *  数组删除元素要遍历、容易出错且费 gas；EnumerableSet 内部用"数组 + 映射下标"实现，
 *  支持 O(1) 增删和判重，还能直接遍历，是白名单场景的标准做法。
 *
 *  【关键安全点：改名单为什么要多签？】
 *  addMinter / delMinter 都带 validCall 修饰符（来自父类 multiSignatureClient），
 *  意思是"这个操作必须先得到多签合约的批准"。不然管理员一把私钥被盗，
 *  攻击者就能把自己加进名单，无限印 spToken 抽干池子。
 *
 *  【继承关系】
 *  AddressPrivileges ──is──> multiSignatureClient  （拿到 validCall）
 *  DebtToken         ──is──> AddressPrivileges      （拿到 onlyMinter）
 * ============================================================================
 */
contract AddressPrivileges is multiSignatureClient {

    /**
     * 构造函数
     * @param multiSignature 多签管理合约地址，交给父类保存，后续 validCall 要用它校验签名
     */
    constructor(address multiSignature) multiSignatureClient(multiSignature) public {
        // 空实现：初始化工作由父构造函数完成
    }

    // 把 EnumerableSet 库的"AddressSet 专用版"方法挂到该类型上，
    // 这样后面就能直接写 _minters.add(addr) 这种"面向对象"风格
    using EnumerableSet for EnumerableSet.AddressSet;
    // private：只有本合约内部能读写；别的合约（哪怕是子合约）看不到内容，更安全
    EnumerableSet.AddressSet private _minters;

    /**
      * @notice add a minter
      * @dev function to add a minter for an asset
      * @param _addMinter add a  minter address
      # @return true or false
      */
    /**
     * 【加入白名单】把一个地址变成有权铸币的 Minter
     * 现实中的调用场景：部署 PledgePool 之后，由多签批准，把 PledgePool 合约地址加进来
     * @param _addMinter 待加入的地址
     * @return true 表示新增成功；如果该地址已在集合中，会返回 false（集合的幂等特性）
     */
    function addMinter(address _addMinter) public validCall returns (bool) {
        // 防线 1：零地址检查。误把 0x000...0 加进名单毫无意义，且往往是笔误
        require(_addMinter != address(0), "Token: _addMinter is the zero address");
        // return 会把库函数的返回值直接抛给调用方：新增成功 true，已存在 false
        return EnumerableSet.add(_minters, _addMinter);
    }

    /**
      * @notice delete a minter
      * @dev function to delete a minter for an asset
      * @param _delMinter delete a minter address
      # @return true or false
      */
    /**
     * 【移出白名单】取消某地址的铸币权
     * 典型场景：发现某合约有漏洞，先把它的铸币权摘掉，阻止损失扩大（"紧急刹车"）
     * @param _delMinter 待移除的地址
     * @return true 表示确实删掉了；地址本来就不在集合里则返回 false
     */
    function delMinter(address _delMinter) public validCall returns (bool) {
        // 同样防零地址：删零地址一定是调用方搞错了
        require(_delMinter != address(0), "Token: _delMinter is the zero address");
        return EnumerableSet.remove(_minters, _delMinter);
    }

    /**
      * @notice get minter list length
      * @dev function to get the minter list length
      # @return the lenght of minter list
      */
    /**
     * 【查数量】当前白名单里有几个人
     * view 表示只读，不写链上数据，因此调用不花 gas（被交易调用时除外）
     */
    function getMinterLength() public view returns (uint256) {
        return EnumerableSet.length(_minters);   // 直接返回集合长度
    }

    /**
      * @notice Determine if this address is minter
      * @dev function to judge address
      * @param account is a condition
      # @return true or false
      */
    /**
     * 【判断】某地址是不是 Minter
     * 这个函数是 onlyMinter 修饰符的内部依赖——每次铸币前都要问一次它
     * @param account 待检查的地址
     */
    function isMinter(address account) public view returns (bool) {
        return EnumerableSet.contains(_minters, account);   // 集合包含判断，O(1)
    }

     /**
      * @notice Get minter account according to index
      * @dev function to get minter account
      * @param _index of index
      # @return  a minter account
      */
    /**
     * 【按下标取人】想要遍历整份名单时用（枚举集合没有提供迭代器，只能按下标取）
     * @param _index 从 0 开始的下标
     */
    function getMinter(uint256 _index) public view  returns (address){
        // 越界检查：下标最大只能到 length-1。
        // 注意这里 length 为 0 时会发生 0-1 下溢——0.6.12 没有内置溢出检查，
        // 但 require 里的减法未使用 SafeMath，理论上会 wrap 成极大值导致校验失效；
        // 实际调用中集合为空时取下标本来也无意义，属于"边缘瑕疵"，读代码时知道即可。
        require(_index <= getMinterLength() - 1, "Token: index out of bounds");
        return EnumerableSet.at(_minters, _index);
    }

    /**
     * 【修饰符】onlyMinter —— 所有"要有铸币权才能干"的函数都挂它
     * 写法说明：`_;` 是占位符，代表被修饰函数的函数体从这里插入执行。
     * 因此执行顺序是：先检查 isMinter，通过了才执行真正的函数体。
     */
    modifier onlyMinter() {
        require(isMinter(msg.sender), "Token: caller is not the minter");
        // msg.sender = 当前调用者（在链上是"谁发起了这笔交易/调用"）
        _;
    }

}
