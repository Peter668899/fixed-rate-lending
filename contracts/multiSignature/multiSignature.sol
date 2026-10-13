// SPDX-License-Identifier: MIT
// 开源许可证：MIT

pragma solidity 0.6.12;
// 编译器版本锁定 0.6.12

// multiSignatureClient：本合约也继承它（形成"多签合约自己也受多签约束"的自洽结构）
import "./multiSignatureClient.sol";


/**
 * ============================================================================
 *  whiteListAddress —— 一份"能增删查"的地址白名单工具
 * ============================================================================
 *  【实现技巧：删除元素不搬数组，而是"拿最后一个填坑再砍尾巴"】
 *  数组删除中间元素如果老老实实往前搬，要遍历、费 gas。这里的做法是：
 *    想删下标 i → 把最后一个元素复制到 i 位置 → 再把数组长度减一（pop）
 *  结果：集合内容正确，但**元素顺序被打乱**。这是"无序集合"的标准优化手段。
 *  （EnumerableSet 也是类似思想，只是多了个反向映射来保持 O(1) 查找）
 *
 *  【注意 storage vs memory】
 *  addWhiteListAddress / removeWhiteListAddress 的参数是 `address[] storage`（引用真实存储，能改）；
 *  isEligibleAddress 用的是 `address[] memory`（只读副本，不能改）。
 *  编译器会据此报错——写错关键字就编不过。
 * ============================================================================
 */
library whiteListAddress{
    // add whiteList
    /**
     * 【加入白名单】如果不存在才 push，避免重复
     */
    function addWhiteListAddress(address[] storage whiteList,address temp) internal{
        if (!isEligibleAddress(whiteList,temp)){
            whiteList.push(temp);   // 只有确认不存在才追加
        }
    }
    /**
     * 【移出白名单】找到目标下标 → 用最后一个元素覆盖它 → 砍掉尾巴
     * @return true 找到并删除成功；false 表示不在名单里
     */
    function removeWhiteListAddress(address[] storage whiteList,address temp)internal returns (bool) {
        uint256 len = whiteList.length;
        uint256 i=0;
        // 第一步：线性查找目标所在下标
        for (;i<len;i++){
            if (whiteList[i] == temp)
                break;
        }
        // 第二步：i<len 说明找到了（循环自然结束则 i==len 表示没找到）
        if (i<len){
            if (i!=len-1) {
                // 要删的不是最后一个，就把最后一个搬到 i 位置填坑
                whiteList[i] = whiteList[len-1];
            }
            whiteList.pop();    // 砍掉尾巴，长度减一
            return true;
        }
        return false;
    }
    /**
     * 【查找】遍历判断地址是否在名单里。pure 表示纯函数：不读也不写链上状态
     */
    function isEligibleAddress(address[] memory whiteList,address temp) internal pure returns (bool){
        uint256 len = whiteList.length;
        for (uint256 i=0;i<len;i++){
            if (whiteList[i] == temp)
                return true;
        }
        return false;
    }
}


/**
 * ============================================================================
 *  multiSignature —— 多签钱包本体（审批中心）
 * ============================================================================
 *  【它是什么】
 *  一个"需要 N 个成员中 M 个签名才能放行"的审批中心。前面讲过的 validCall 修饰符，
 *  就是拿着指纹（msg.sender + 目标合约）来这里问："这次操作通过了吗？"
 *
 *  【完整工作流程（重点！这是理解全项目权限的关键）】
 *  假设要做一次敏感的 `settle()` 结算：
 *
 *   链下：                                       链上：
 *   ① 申请人调用 createApplication(目标合约地址) ─→ 生成一条"申请单"，
 *                                                    用哈希 keccak256(申请人, 目标合约) 做单号
 *   ② 多签成员们看到申请，各自调用 signApplication(单号)
 *                                              ─→ 把成员地址加进这条申请的签名名单
 *   ③ 签名数达到 threshold（门槛）                ─→ 这条申请就"生效"了
 *   ④ 申请人（或任何人）去调用目标合约的 settle()  ─→ validCall 触发，
 *                                                    多签合约回答"已通过"，
 *                                                    settle() 才真正执行
 *
 *  【为什么签名数不够就过不去】
 *  getValidSignature 会数这条申请下的签名人数，只有 >= threshold 才返回非 0，
 *  调用侧只认非 0 结果。
 *
 *  【安全设计点评（接手项目时要留意的点）】
 *  - 批准粒度较粗：指纹只含"申请人+目标合约"，不含具体函数和参数。
 *    也就是说一份批准，理论上可以用于该申请人对该合约的多次不同调用。
 *  - 没有防重放的落库逻辑：signatureMap 的签名名单会一直存在，不会被"用掉即失效"。
 *    （multiSignatureClient 中读写索引的那两行恰好被注释掉了，印证了这一点）
 *  - transferOwner 可替换成员，需 onlyOwner + validCall 双重校验。
 * ============================================================================
 */
contract multiSignature  is multiSignatureClient {
    // 默认索引 0：与客户端约定一致，"返回 0 = 未通过"
    uint256 private constant defaultIndex = 0;
    // 把白名单库的方法挂到 address[] 类型上，方便直接写 signatureOwners.isEligibleAddress(x)
    using whiteListAddress for address[];
    // 多签成员名单（公钥地址列表）
    address[] public signatureOwners;
    // 门槛：需要多少个成员签名才放行（如 3 个成员设 2，即 2/3 多签）
    uint256 public threshold;
    /**
     * 一条"申请单"的结构
     *  applicant  —— 谁发起的申请（之后要拿着这个身份去调用目标合约）
     *  signatures —— 已经签名的成员名单
     */
    struct signatureInfo {
        address applicant;
        address[] signatures;
    }
    // 单号(哈希) → 申请单数组。
    // 为什么是数组？因为同一个"申请人+目标合约"可以反复发起多次申请，每次一条。
    // 客户端取用时传 lastIndex=0，即总是拿最早那条满足门槛的申请。
    mapping(bytes32=>signatureInfo[]) public signatureMap;
    // 四个事件，用来让链下（前端/后端）跟踪多签活动
    event TransferOwner(address indexed sender,address indexed oldOwner,address indexed newOwner);
    event CreateApplication(address indexed from,address indexed to,bytes32 indexed msgHash);
    event SignApplication(address indexed from,bytes32 indexed msgHash,uint256 index);
    event RevokeApplication(address indexed from,bytes32 indexed msgHash,uint256 index);

    /**
     * 构造函数：部署多签钱包
     * @param owners         初始成员地址列表
     * @param limitedSignNum 签名门槛 threshold
     * 注意 parent 构造传的是 address(this)：多签合约把自己注册为自己的"多签地址"，
     * 于是它自己的敏感函数（transferOwner）也会走一遍 validCall 检查——自我约束。
     */
    constructor(address[] memory owners,uint256 limitedSignNum) multiSignatureClient(address(this)) public {
        // 门槛不能超过成员总数，否则永远无法达成
        require(owners.length>=limitedSignNum,"Multiple Signature : Signature threshold is greater than owners' length!");
        signatureOwners = owners;
        threshold = limitedSignNum;
    }

    /**
     * 【换人】把某个成员替换成新地址（成员离职/换钥匙时用）
     * 两道门：onlyOwner（调用者必须是成员）+ validCall（且这个操作已被多签批准）
     */
    function transferOwner(uint256 index,address newOwner) public onlyOwner validCall{
        require(index<signatureOwners.length,"Multiple Signature : Owner index is overflow!");
        emit TransferOwner(msg.sender,signatureOwners[index],newOwner);   // 先记录旧成员再改
        signatureOwners[index] = newOwner;
    }

    /**
     * 【发起申请】第①步：申请人提交"我准备调用 to 这个合约"
     * @param to 目标合约地址（如 PledgePool 地址）
     * @return 这条申请在本单号下的下标
     *
     * 注意：这个函数**没有权限限制**——任何人都能发起申请，这是合理设计：
     * 发起申请≠获得批准，真正决定权在签名成员手上。
     */
    function createApplication(address to) external returns(uint256) {
        bytes32 msghash = getApplicationHash(msg.sender,to);   // 单号 = hash(申请人, 目标合约)
        uint256 index = signatureMap[msghash].length;          // 本条单号已有的申请数 = 新申请的数组下标
        signatureMap[msghash].push(signatureInfo(msg.sender,new address[](0)));  // 新申请，签名名单为空
        emit CreateApplication(msg.sender,to,msghash);
        return index;
    }

    /**
     * 【签名】第②步：成员对某条申请表示同意
     * validIndex 保证这条申请存在（否则下标越界）
     * 内部用白名单库 addWhiteListAddress —— 同一成员重复签名不会重复计数
     */
    function signApplication(bytes32 msghash) external onlyOwner validIndex(msghash,defaultIndex){
        emit SignApplication(msg.sender,msghash,defaultIndex);
        signatureMap[msghash][defaultIndex].signatures.addWhiteListAddress(msg.sender);
    }

    /**
     * 【撤销签名】成员反悔时调用（比如发现申请内容有问题）
     * 会把该成员从签名名单里移除，签名数随之减少，可能重新低于门槛
     */
    function revokeSignApplication(bytes32 msghash) external onlyOwner validIndex(msghash,defaultIndex){
        emit RevokeApplication(msg.sender,msghash,defaultIndex);
        signatureMap[msghash][defaultIndex].signatures.removeWhiteListAddress(msg.sender);
    }

    /**
     * 【核心查询】第③步：客户端问"这条申请通过了吗？"
     * @param msghash   单号
     * @param lastIndex 从哪个下标开始找（客户端固定传 0）
     * @return 满足门槛的申请下标 + 1（因为 0 被约定为"未通过"）
     *
     * 这是 multiSignatureClient.checkMultiSignature() 唯一依赖的接口：
     * 返回 > 0 → require 通过 → 敏感操作放行。
     */
    function getValidSignature(bytes32 msghash,uint256 lastIndex) external view returns(uint256){
        signatureInfo[] storage info = signatureMap[msghash];
        for (uint256 i=lastIndex;i<info.length;i++){
            // 逐个申请检查签名人数是否达到门槛
            if(info[i].signatures.length >= threshold){
                return i+1;   // 用 i+1 避开"0=未通过"的歧义
            }
        }
        return 0;   // 一条都没达标
    }

    /**
     * 【查申请详情】返回某条申请的申请人 + 已签名名单（前端展示用）
     * validIndex 保证下标有效
     */
    function getApplicationInfo(bytes32 msghash,uint256 index) validIndex(msghash,index) public view returns (address,address[]memory) {
        signatureInfo memory info = signatureMap[msghash][index];
        return (info.applicant,info.signatures);
    }

    /**
     * 【查申请条数】某单号下共有几条申请
     */
    function getApplicationCount(bytes32 msghash) public view returns (uint256) {
        return signatureMap[msghash].length;
    }

    /**
     * 【算单号】纯函数：把"申请人 + 目标合约"拼成哈希
     * abi.encodePacked 是紧凑编码，两边拼接后取 keccak256
     * ⚠️ 注意：这里只拼了地址，没拼 nonce，因此同一对(申请人,合约)永远算出同一个单号
     */
    function getApplicationHash(address from,address to) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(from, to));
    }

    /**
     * 【修饰符】onlyOwner —— 调用者必须是多签成员之一
     * 复用白名单库的查找函数做成员判定
     */
    modifier onlyOwner{
        require(signatureOwners.isEligibleAddress(msg.sender),"Multiple Signature : caller is not in the ownerList!");
        _;
    }

    /**
     * 【修饰符】validIndex —— 保证访问的申请下标真实存在，防止数组越界读
     */
    modifier validIndex(bytes32 msghash,uint256 index){
        require(index<signatureMap[msghash].length,"Multiple Signature : Message index is overflow!");
        _;
    }
}
