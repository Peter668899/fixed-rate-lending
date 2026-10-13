// SPDX-License-Identifier: MIT
// 开源许可证：MIT（可自由使用/修改/分发）

pragma solidity 0.6.12;
// 编译器版本锁定 0.6.12（老版本没有内置溢出检查、没有 try/catch 等新特性，锁死版本很重要）

// ReentrancyGuard：防重入攻击的"锁"，提供 nonReentrant 修饰符
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
// SafeTransfer：本项目的收付款柜台，提供 getPayableAmount（收钱）和 _redeem（付钱）
import "../library/SafeTransfer.sol";
// IDebtToken：凭证代币接口（spToken / jpToken 都是它），用来调 mint / burn
import "../interface/IDebtToken.sol";
// IBscPledgeOracle：价格预言机接口，用来查抵押品价格
import "../interface/IBscPledgeOracle.sol";
// IUniswapV2Router02：PancakeSwap 路由接口，到期/清算时用它把抵押品换成稳定币
import "../interface/IUniswapV2Router02.sol";
// multiSignatureClient：多签客户端，提供 validCall 修饰符（所有管理员函数都要多签批准）
import "../multiSignature/multiSignatureClient.sol";



/**
 * ============================================================================
 *                        PledgePool —— 整个项目的核心合约
 * ============================================================================
 *  【一句话说明它是什么】
 *  一个"固定利率、固定期限"的借贷撮合池：贷款人存稳定币赚利息，借款人抵押加密资产
 *  借出稳定币。合约负责撮合、看管资金、到期结算或强制清算。
 *
 *  【三个角色与他们的函数（读代码时按这个分组看）】
 *  贷款人：depositLend 存钱 → claimLend 领 spToken → withdrawLend 赎本息
 *          （没人匹配上时：refundLend 退款；池子失败时：emergencyLendWithdrawal 全退）
 *  借款人：depositBorrow 抵押 → claimBorrow 领 jpToken 和借款 → withdrawBorrow 赎回抵押品
 *          （多余抵押品：refundBorrow 退回；池子失败时：emergencyBorrowWithdrawal 全退）
 *  管理员：createPoolInfo 建池 setFee/setFeeAddress/setSwapRouterAddress/setMinAmount 配置
 *          settle 结算 finish 结束 liquidate 清算 setPause 紧急刹车
 *
 *  【池子的五种状态（所有函数的门禁都挂在这上面）】
 *   MATCH(0)       撮合期：双方存钱，时间必须早于 settleTime
 *   EXECUTION(1)   执行期：已结算，借款人拿钱去用
 *   FINISH(2)      正常结束：到期还本付息，双方赎回
 *   LIQUIDATION(3) 清算：抵押品跌破清算线，卖掉抵押品保住贷款人
 *   UNDONE(4)      撮合失败：一方没人来，全员原路退款
 *
 *  【"份额计算三行套路"——全合约重复出现 6 次，务必背下来】
 *   uint256 userShare = 我的质押量 × 1e18 ÷ 池子总量;      // 我在池子里占多少比例（放大 1e18 是为了保留小数精度）
 *   uint256 结果 = 池子可分配总量 × userShare ÷ 1e18;     // 按比例分给我多少
 *   _redeem(msg.sender, token, 结果);                     // 真正把钱转给我
 *  （Solidity 只有整数，没有小数，所以用"先放大再缩小"的技巧算比例）
 *
 *  【建议阅读顺序】
 *   ① 状态变量与结构体 → ② depositLend → ③ settle → ④ finish/liquidate → ⑤ 修饰符
 *
 *  【继承说明】
 *   PledgePool ─is─→ ReentrancyGuard    （拿到 nonReentrant，防重入）
 *             ─is─→ SafeTransfer        （拿到收付款能力）
 *             ─is─→ multiSignatureClient（拿到 validCall，管理员函数需多签）
 * ============================================================================
 */
contract PledgePool is ReentrancyGuard, SafeTransfer, multiSignatureClient{

    // 把 SafeMath 的 add/sub/mul/div 挂到 uint256 上，防止算术溢出/下溢
    // （0.6.12 的加减乘除默认不检查溢出，裸写 a+b 有被攻击风险，所以全项目都用 .add() 风格）
    using SafeMath for uint256;
    // 把 SafeERC20 的安全转账方法挂到 IERC20 上
    using SafeERC20 for IERC20;

    // default decimal
    uint256 constant internal calDecimal = 1e18;
    // 精度基数 1：用于"份额/比例"计算（1 个单位 = 1e18）
    // Based on the decimal of the commission and interest
    uint256 constant internal baseDecimal = 1e8;
    // 精度基数 2：用于费率、利率、抵押率（1 个单位 = 1e8）
    // 例：interestRate = 1000000（1e6）→ 除以 1e16 后约为 1e-10，是"很小"的年化利率
    //     martgageRate = 200000000（2e8）→ 除以 1e8 = 2.0，即抵押品要值借款的 2 倍
    uint256 public minAmount = 100e18;
    // 最小存款金额：100 个代币（默认 18 位小数）。
    // ⚠️ 隐含假设：代币必须是 18 位小数。若接入 6 位小数的代币（如 USDC），
    //    这个门槛会大到几乎无法跨越——换代币时务必同步调整 setMinAmount。
    // one years
    uint256 constant baseYear = 365 days;
    // 一年的秒数：31536000。用来把"年化利率"折算成"实际借款天数的利息"

    enum PoolState{ MATCH, EXECUTION, FINISH, LIQUIDATION, UNDONE }
    // 池子的五种状态。枚举在链上实际存储为 0~4 的整数，所以池子状态可以直接用数字比较
    PoolState constant defaultChoice = PoolState.MATCH;
    // 新建池子的默认状态 = MATCH（撮合期）

    bool public globalPaused = false;
    // 全局暂停开关：true 时所有带 notPause 的函数（存钱、领钱、赎回等）全部冻结。
    // 这是"紧急刹车"，出漏洞时管理员可一键停止用户操作，争取修复时间
    // pancake swap router
    address public swapRouter;
    // PancakeSwap 路由合约地址：到期/清算时把抵押品（BTC）卖掉换成稳定币用
    // receiving fee address
    address payable public feeAddress;
    // 平台手续费收款地址。payable 表示这个地址能接收原生币（BNB）
    // oracle address
    IBscPledgeOracle public oracle;
    // 价格预言机合约：查 BTC/BUSD 等的实时价格
    // fee
    uint256 public lendFee;
    // 贷款侧手续费率（1e8 精度）。在 finish/liquidate 里从贷款人应得金额中扣
    uint256 public borrowFee;
    // 借款侧手续费率（1e8 精度）。在 finish/liquidate 里从借款人抵押品中扣

        // 每个池的基本信息
    struct PoolBaseInfo{
        uint256 settleTime;         // 结算时间：撮合截止。（存钱必须早于它；过了它才能 settle）
        uint256 endTime;            // 结束时间：借款到期日。（必须晚于 settleTime；到期才能 finish）
        uint256 interestRate;       // 池的固定利率，单位是1e8 (1e8)
        uint256 maxSupply;          // 池的最大限额（本池最多能吸收多少贷款）
        uint256 lendSupply;         // 【实时累加】当前已被贷款人存入的总额
        uint256 borrowSupply;       // 【实时累加】当前已被借款人抵押的资产总额
        uint256 martgageRate;       // 池的抵押率，单位是1e8 (1e8)。2e8 = 2.0 倍（超额抵押）
        address lendToken;          // 贷款方代币地址 (比如 BUSD..)。address(0) 表示原生币 BNB
        address borrowToken;        // 借款方代币地址 (比如 BTC..)。即被抵押进来的资产
        PoolState state;            // 状态 'MATCH, EXECUTION, FINISH, LIQUIDATION, UNDONE'
        IDebtToken spCoin;          // sp_token的erc20地址 (比如 spBUSD_1..) 贷款人的存款凭证
        IDebtToken jpCoin;          // jp_token的erc20地址 (比如 jpBTC_1..) 借款人的抵押凭证
        uint256 autoLiquidateThreshold; // 自动清算阈值 (触发清算阈值，1e8 精度)
                                        // 含义：抵押品价值 < 借款额 × (1 + 该阈值) 就触发清算
    }
    // total base pool.
    PoolBaseInfo[] public poolBaseInfo;
    // 所有池子的基础信息数组。**数组下标 = 池子 ID（_pid）**，所以 pid 从 0 开始
    // public 会自动生成同名 getter：poolBaseInfo(0) 可读第 0 个池子

       // 每个池的数据信息
    struct PoolDataInfo{
        uint256 settleAmountLend;       // 结算时的实际出借金额（真正匹配成功的部分）
        uint256 settleAmountBorrow;     // 结算时的实际借款金额（真正被锁定的抵押品）
        uint256 finishAmountLend;       // 完成时的实际出借金额（本息总额，供贷款人按份额分）
        uint256 finishAmountBorrow;     // 完成时的实际借款金额（剩余抵押品，供借款人按份额赎）
        uint256 liquidationAmounLend;   // 清算时的实际出借金额（注意源码拼写错误 Amoun，将错就错）
        uint256 liquidationAmounBorrow; // 清算时的实际借款金额
    }
    // total data pool
    PoolDataInfo[] public poolDataInfo;
    // 池子的结算数据数组，与 poolBaseInfo 下标一一对应。
    // 为什么要拆成两张表？—— 配置（Base）是管理员定的常量，结算（Data）是业务产生的变量，
    // 分开存让职责更清晰，也避免一张结构体过于臃肿

       // 借款用户信息
    struct BorrowInfo {
        uint256 stakeAmount;           // 当前借款的质押金额（我总共抵押了多少）
        uint256 refundAmount;          // 多余的退款金额（累计已退回多少）
        bool hasNoRefund;              // 默认为false，false = 未退款，true = 已退款（防重复退款）
        bool hasNoClaim;               // 默认为false，false = 未认领，true = 已认领（防重复领取）
    }
    // Info of each user that stakes tokens.  {user.address : {pool.index : user.borrowInfo}}
    mapping (address => mapping (uint256 => BorrowInfo)) public userBorrowInfo;
    // 两层映射：用户地址 → 池子 ID → 我的抵押记录。查询方式：userBorrowInfo(我的地址, 池子ID)

      // 借款用户信息
    struct LendInfo {
        uint256 stakeAmount;          // 当前借款的质押金额（我总共存了多少）
        uint256 refundAmount;         // 超额退款金额（累计已退回多少）
        bool hasNoRefund;             // 默认为false，false = 无退款，true = 已退款
        bool hasNoClaim;              // 默认为false，false = 无索赔，true = 已索赔
    }

    // Info of each user that stakes tokens.  {user.address : {pool.index : user.lendInfo}}
    mapping (address => mapping (uint256 => LendInfo)) public userLendInfo;
    // 贷款人的存款记录表，结构与借款表完全对称

        // 事件
        // 存款借出事件，from是借出者地址，token是借出的代币地址，amount是借出的数量，mintAmount是生成的数量
    event DepositLend(address indexed from,address indexed token,uint256 amount,uint256 mintAmount); 
    // ⚠️ 注意：参数名叫 mintAmount，但 depositLend 里**并没有真的铸币**（铸币发生在 claimLend）。
    //    接入链下事件订阅时别被这个名字误导
    // 借出退款事件，from是退款者地址，token是退款的代币地址，refund是退款的数量
    event RefundLend(address indexed from, address indexed token, uint256 refund); 
    // 借出索赔事件，from是索赔者地址，token是索赔的代币地址，amount是索赔的数量
    event ClaimLend(address indexed from, address indexed token, uint256 amount); 
     // 提取借出事件，from是提取者地址，token是提取的代币地址，amount是提取的数量，burnAmount是销毁的数量
    event WithdrawLend(address indexed from,address indexed token,uint256 amount,uint256 burnAmount);
    // 存款借入事件，from是借入者地址，token是借入的代币地址，amount是借入的数量，mintAmount是生成的数量
    event DepositBorrow(address indexed from,address indexed token,uint256 amount,uint256 mintAmount); 
     // 借入退款事件，from是退款者地址，token是退款的代币地址，refund是退款的数量
    event RefundBorrow(address indexed from, address indexed token, uint256 refund);
    // 借入索赔事件，from是索赔者地址，token是索赔的代币地址，amount是索赔的数量
    event ClaimBorrow(address indexed from, address indexed token, uint256 amount); 
    // 提取借入事件，from是提取者地址，token是提取的代币地址，amount是提取的数量，burnAmount是销毁的数量
    event WithdrawBorrow(address indexed from,address indexed token,uint256 amount,uint256 burnAmount); 
    // 交换事件，fromCoin是交换前的币种地址，toCoin是交换后的币种地址，fromValue是交换前的数量，toValue是交换后的数量
    event Swap(address indexed fromCoin,address indexed toCoin,uint256 fromValue,uint256 toValue); 
    // 紧急借入提取事件，from是提取者地址，token是提取的代币地址，amount是提取的数量
    event EmergencyBorrowWithdrawal(address indexed from, address indexed token, uint256 amount); 
     // 紧急借出提取事件，from是提取者地址，token是提取的代币地址，amount是提取的数量
    event EmergencyLendWithdrawal(address indexed from, address indexed token, uint256 amount);
    // 状态改变事件，pid是项目id，beforeState是改变前的状态，afterState是改变后的状态
    // ★ 这是后端最关心的事件：池子生命周期推进时都会抛出它
    event StateChange(uint256 indexed pid, uint256 indexed beforeState, uint256 indexed afterState); 
     // 设置费用事件，newLendFee是新的借出费用，newBorrowFee是新的借入费用
    event SetFee(uint256 indexed newLendFee, uint256 indexed newBorrowFee);
    // 设置交换路由器地址事件，oldSwapAddress是旧的交换地址，newSwapAddress是新的交换地址
    event SetSwapRouterAddress(address indexed oldSwapAddress, address indexed newSwapAddress); 
     // 设置费用地址事件，oldFeeAddress是旧的费用地址，newFeeAddress是新的费用地址
    event SetFeeAddress(address indexed oldFeeAddress, address indexed newFeeAddress);
    // 设置最小数量事件，oldMinAmount是旧的最小数量，newMinAmount是新的最小数量
    event SetMinAmount(uint256 indexed oldMinAmount, uint256 indexed newMinAmount); 

    /**
     * 【构造函数】部署时执行一次，把关键搭档合约的地址记下来
     * @param _oracle         价格预言机地址
     * @param _swapRouter     DEX 路由地址（PancakeSwap）
     * @param _feeAddress     手续费收款地址
     * @param _multiSignature 多签合约地址（本合约的管理员操作都受它约束）
     */
    constructor(
        address _oracle,
        address _swapRouter,
        address payable _feeAddress,
        address _multiSignature
    ) multiSignatureClient(_multiSignature) public {
        // 三个零地址检查：地址填错（0x000...0）会导致后续所有相关调用失败，钱可能被永久锁死
        require(_oracle != address(0), "Is zero address");
        require(_swapRouter != address(0), "Is zero address");
        require(_feeAddress != address(0), "Is zero address");

        oracle = IBscPledgeOracle(_oracle);   // 把接口类型"套"在地址上，之后就能 oracle.getPrices(...)
        swapRouter = _swapRouter;
        feeAddress = _feeAddress;
        lendFee = 0;      // 初始费率为 0，上线后再由多签设置
        borrowFee = 0;
    }

    /**
     * @dev Set the lend fee and borrow fee
     * @notice Only allow administrators to operate
     */
    /**
     * 【管理员】设置贷款/借款两侧的手续费
     * validCall = 必须经过多签批准才能执行（后面所有管理员函数同理）
     * @param _lendFee   贷款侧费率（1e8 精度）
     * @param _borrowFee 借款侧费率（1e8 精度）
     */
    function setFee(uint256 _lendFee,uint256 _borrowFee) validCall external{
        lendFee = _lendFee;
        borrowFee = _borrowFee;
        emit SetFee(_lendFee, _borrowFee);   // 抛事件，链下可追踪费率变更历史
    }

    /**
     * @dev Set swap router address, example pancakeswap or babyswap..
     * @notice Only allow administrators to operate
     */
    /**
     * 【管理员】更换 DEX 路由地址（比如从 Pancake 换成 BabySwap）
     */
    function setSwapRouterAddress(address _swapRouter) validCall external{
        require(_swapRouter != address(0), "Is zero address");
        emit SetSwapRouterAddress(swapRouter,_swapRouter);   // 先记录旧地址，便于审计追溯
        swapRouter = _swapRouter;
    }

    /**
     * @dev Set up the address to receive the handling fee
     * @notice Only allow administrators to operate
     */
    /**
     * 【管理员】更换手续费收款地址
     */
    function setFeeAddress(address payable _feeAddress) validCall external {
        require(_feeAddress != address(0), "Is zero address");
        emit SetFeeAddress(feeAddress, _feeAddress);
        feeAddress = _feeAddress;
    }

    /**
     * @dev Set the min amount
     */
    /**
     * 【管理员】修改最小存款金额
     * 注意：这里没有任何边界检查（比如不能设为 0 或过大），属于可优化点
     */
    function setMinAmount(uint256 _minAmount) validCall external {
        emit SetMinAmount(minAmount,_minAmount);
        minAmount = _minAmount;
    }


     /**
     * @dev Query pool length
     */
    /**
     * 【查询】一共有多少个池子
     * 后端定时任务就靠这个函数决定循环次数（先拿总长度，再逐个读池子数据）
     */
    function poolLength() external view returns (uint256) {
        return poolBaseInfo.length;
    }

    /**
     * @dev 创建一个新的借贷池。函数接收一系列参数，包括结算时间、结束时间、利率、最大供应量、抵押率、借款代币、借出代币、SP代币、JP代币和自动清算阈值。
     *  Can only be called by the owner.
     */
    /**
     * 【管理员】创建新池子 —— 一轮借贷业务的起点
     *
     * 现实中的流程：项目方决定"开一期 BTC 抵押借 BUSD 的产品"，
     * 先部署两个凭证代币（spBUSD_1、jpBTC_1），再调这个函数把池子建出来
     *
     * @param _settleTime             撮合截止时间（时间戳）
     * @param _endTime                借款到期时间（时间戳，必须晚于 settleTime）
     * @param _interestRate           固定年化利率（1e8 精度）
     * @param _maxSupply              本池最多吸收多少贷款
     * @param _martgageRate           抵押率（1e8 精度，2e8 = 抵押品需值借款的 2 倍）
     * @param _lendToken              贷款币地址（借款人拿走、贷款人存的币，如 BUSD）
     * @param _borrowToken            抵押币地址（借款人的抵押品，如 BTC）
     * @param _spToken                spToken 合约地址（贷款人凭证）
     * @param _jpToken                jpToken 合约地址（借款人凭证）
     * @param _autoLiquidateThreshold 自动清算阈值（1e8 精度）
     */
    function createPoolInfo(uint256 _settleTime,  uint256 _endTime, uint64 _interestRate,
                        uint256 _maxSupply, uint256 _martgageRate, address _lendToken, address _borrowToken,
                    address _spToken, address _jpToken, uint256 _autoLiquidateThreshold) public validCall{
        // 检查是否已设置token ...
        // 需要结束时间大于结算时间
        require(_endTime > _settleTime, "createPool:end time grate than settle time");
        // 逻辑上先撮合再还款：到期日必须晚于撮合截止日，否则池子还没撮合完就该还钱了
        // 需要_jpToken不是零地址
        require(_jpToken != address(0), "createPool:is zero address");
        // 需要_spToken不是零地址
        require(_spToken != address(0), "createPool:is zero address");
        // 凭证合约地址不能为空，否则后面 mint/burn 全部失败

        // 推入基础池信息
        poolBaseInfo.push(PoolBaseInfo({
            settleTime: _settleTime,
            endTime: _endTime,
            interestRate: _interestRate,
            maxSupply: _maxSupply,
            lendSupply:0,                 // 新池子，已存入贷款为 0
            borrowSupply:0,               // 新池子，已抵押资产为 0
            martgageRate: _martgageRate,
            lendToken:_lendToken,
            borrowToken:_borrowToken,
            state: defaultChoice,         // 出生即 MATCH 撮合期
            spCoin: IDebtToken(_spToken), // 把地址包成接口对象，便于调 mint/burn
            jpCoin: IDebtToken(_jpToken),
            autoLiquidateThreshold:_autoLiquidateThreshold
        }));
        // 推入池数据信息
        poolDataInfo.push(PoolDataInfo({
            settleAmountLend:0,           // 六项结算数据全部初始化为 0，
            settleAmountBorrow:0,         // 等 settle/finish/liquidate 时才会被写入
            finishAmountLend:0,
            finishAmountBorrow:0,
            liquidationAmounLend:0,
            liquidationAmounBorrow:0
        }));
        // 两张表同步 push，靠"下标对齐"建立关联——所以任何一张表都不能单独增删
    }
      /**
     * @dev Get pool state
     * @notice returned is an int integer
     */
    /**
     * 【查询】返回池子当前状态（0~4 的整数）
     * enum 在链上就是数字，转成 uint256 方便前端/后端消费
     */
    function getPoolState(uint256 _pid) public view returns (uint256) {
        PoolBaseInfo storage pool = poolBaseInfo[_pid];
        return uint256(pool.state);
    }

       /**
     * @dev 存款人执行存款操作
     * @notice 池状态必须为MATCH
     * @param _pid 是池索引
     * @param _stakeAmount 是用户的质押金额
     */
    /**
     * 【贷款人·第1步】存入稳定币（只在撮合期可用）
     *
     * 门禁一览（函数签名上的修饰符，任一不过直接回滚）：
     *  - payable      ：允许携带原生币（lendToken 是零地址时收 BNB）
     *  - nonReentrant ：防重入（本函数会转钱，必须防）
     *  - notPause     ：管理员没拉闸
     *  - timeBefore   ：当前时间 < settleTime（还在撮合期）
     *  - stateMatch   ：池子状态 == MATCH
     *
     * @param _pid         池子 ID
     * @param _stakeAmount 存入金额（ERC20 场景下即代币数量）
     */
    function depositLend(uint256 _pid, uint256 _stakeAmount) external payable nonReentrant notPause timeBefore(_pid) stateMatch(_pid){
        // 时间和状态的限制
        PoolBaseInfo storage pool = poolBaseInfo[_pid];
        // storage = 引用（直接操作链上存储），修改 pool 就是修改链上数据；
        // 如果用 memory 则是复制一份，改副本对链上无影响——这是 Solidity 新手最容易踩的坑
        LendInfo storage lendInfo = userLendInfo[msg.sender][_pid];
        // msg.sender = 当前调用者，也就是存钱的这位贷款人
        // 边界条件
        require(_stakeAmount <= (pool.maxSupply).sub(pool.lendSupply), "depositLend: 数量超过限制");
        // 不能超过"池子剩余额度" = 总额度 - 已存入。用 .sub 而不是 - 是为了防下溢
        uint256 amount = getPayableAmount(pool.lendToken,_stakeAmount);
        // ★ 这里是全函数唯一"动钱"的时刻：
        //   ERC20 → 内部 safeTransferFrom 把钱从用户钱包拉进本合约
        //   原生币 → 取 msg.value（钱随交易一起送来，已在合约账上）
        require(amount > minAmount, "depositLend: 少于最小金额");
        // 金额下限检查。此处顺序"先拉款再检查"是安全的：EVM 交易具备原子性，
        // 这个 require 一失败，前面已完成的转账会连同整笔交易一起回滚，用户的钱不会丢
        // 保存借款用户信息
        lendInfo.hasNoClaim = false;
        lendInfo.hasNoRefund = false;
        // 重置两个"已领取/已退款"标记：因为份额基数变了，之前的状态要作废重新计算
        // （由于 timeBefore 与 claimLend 的 timeAfter 互斥，正常流程走不到"领完再存"，
        //   这里属于防御性写法）
        if (pool.lendToken == address(0)){
            // —— 原生币分支：钱在 msg.value 里 ——
            lendInfo.stakeAmount = lendInfo.stakeAmount.add(msg.value);
            pool.lendSupply = pool.lendSupply.add(msg.value);
        } else {
            // —— ERC20 分支：按入参数量记账（与 getPayableAmount 拉到的金额一致）——
            lendInfo.stakeAmount = lendInfo.stakeAmount.add(_stakeAmount);
            pool.lendSupply = pool.lendSupply.add(_stakeAmount);
        }
        // 用 .add() 累加而不是直接赋值，是为了**支持多次存款**：存两次会累加成总额
        emit DepositLend(msg.sender, pool.lendToken, _stakeAmount, amount);
        // 抛出事件通知链下。注意此处并未铸 spToken——凭证要等 settle 后由 claimLend 发放
    }

       /**
     * @dev 退还过量存款给存款人
     * @notice 池状态不等于匹配和未完成
     * @param _pid 是池索引
     */
    /**
     * 【贷款人·补充动作】退还未被匹配的资金
     *
     * 业务场景：池子目标借 10000，贷款人存了 15000，settle 时只匹配 10000，
     * 多出的 5000 通过本函数按比例退回
     *
     * 门禁：timeAfter（撮合期已过）+ stateNotMatchUndone（已进入 EXECUTION/FINISH/LIQUIDATION）
     * @param _pid 池子 ID
     */
    function refundLend(uint256 _pid) external nonReentrant notPause timeAfter(_pid) stateNotMatchUndone(_pid){
        PoolBaseInfo storage pool = poolBaseInfo[_pid]; // 获取池的基本信息
        PoolDataInfo storage data = poolDataInfo[_pid]; // 获取池的数据信息
        LendInfo storage lendInfo = userLendInfo[msg.sender][_pid]; // 获取用户的出借信息
        // 限制金额
        require(lendInfo.stakeAmount > 0, "refundLend: not pledged"); // 需要用户已经质押了一定数量
        require(pool.lendSupply.sub(data.settleAmountLend) > 0, "refundLend: not refund"); // 需要池中还有未退还的金额
        require(!lendInfo.hasNoRefund, "refundLend: repeat refund"); // 需要用户没有重复退款
        // 三道校验：① 你得存过钱 ② 池子里确实有"没匹配上"的余额 ③ 你没退过款（防二刷）
        // 用户份额 = 当前质押金额 / 总金额
        uint256 userShare = lendInfo.stakeAmount.mul(calDecimal).div(pool.lendSupply);
        // 份额套路第 1 步：我的存款占池子总存款的比例（放大 1e18 保留精度）
        // refundAmount = 总退款金额 * 用户份额
        uint256 refundAmount = (pool.lendSupply.sub(data.settleAmountLend)).mul(userShare).div(calDecimal);
        // 份额套路第 2 步：池子未匹配总额 × 我的占比 ÷ 1e18
        // 退款操作
        _redeem(msg.sender,pool.lendToken,refundAmount);
        // 份额套路第 3 步：把钱转给用户（SafeTransfer 里的付钱函数）
        // 更新用户信息
        lendInfo.hasNoRefund = true;
        // 先标记后 emit 是标准顺序（有 nonReentrant 保护，不存在重入窗口）
        lendInfo.refundAmount = lendInfo.refundAmount.add(refundAmount);
        emit RefundLend(msg.sender, pool.lendToken, refundAmount); // 触发退款事件
    }

     /**
     * @dev 存款人接收 sp_toke,主要功能是让存款人领取 sp_token
     * @notice 池状态不等于匹配和未完成
     * @param _pid 是池索引
     */
    /**
     * 【贷款人·第2步】领取 spToken（存款凭证）
     *
     * 为什么存款时不直接发凭证？
     *  因为存款时还不知道"最终能匹配多少"——要等 settle 算完实际匹配额，
     *  这里再按份额把相应数量的 spToken 铸给每个贷款人
     *
     * @param _pid 池子 ID
     */
    function claimLend(uint256 _pid) external nonReentrant notPause timeAfter(_pid) stateNotMatchUndone(_pid){
        PoolBaseInfo storage pool = poolBaseInfo[_pid]; // 获取池的基本信息
        PoolDataInfo storage data = poolDataInfo[_pid]; // 获取池的数据信息
        LendInfo storage lendInfo = userLendInfo[msg.sender][_pid]; // 获取用户的借款信息
        // 金额限制
        require(lendInfo.stakeAmount > 0, "claimLend: 不能领取 sp_token"); // 需要用户的质押金额大于0
        require(!lendInfo.hasNoClaim,"claimLend: 不能再次领取"); // 用户不能再次领取
        // 用户份额 = 当前质押金额 / 总金额
        uint256 userShare = lendInfo.stakeAmount.mul(calDecimal).div(pool.lendSupply); 
        // 份额套路第 1 步
        // totalSpAmount = settleAmountLend
        uint256 totalSpAmount = data.settleAmountLend; // 总的Sp金额等于借款结算金额
        // 池子实际匹配成功的总额，也就是"这批凭证要覆盖的总量"
        // 用户 sp 金额 = totalSpAmount * 用户份额
        uint256 spAmount = totalSpAmount.mul(userShare).div(calDecimal); 
        // 份额套路第 2 步：我能领到多少 spToken
        // 铸造 sp token
        pool.spCoin.mint(msg.sender, spAmount); 
        // ★ 调用凭证代币合约铸币。能铸成功是因为 PledgePool 被加进了 DebtToken 的 minter 白名单
        // 更新领取标志
        lendInfo.hasNoClaim = true; 
        // 打标记，防止重复领取（否则可以无限刷 spToken）
        emit ClaimLend(msg.sender, pool.borrowToken, spAmount); // 触发领取借款事件
    }

        /**
     * @dev 存款人取回本金和利息
     * @notice 池的状态可能是完成或清算
     * @param _pid 是池索引
     * @param _spAmount 是销毁的sp数量
     */
    /**
     * 【贷款人·第3步】销毁 spToken 换回本息（故事终点）
     *
     * 两种结局走同一个函数：
     *   FINISH      → 按 finishAmountLend（本金+利息）分
     *   LIQUIDATION → 按 liquidationAmounLend（卖抵押品所得）分，可能拿不满
     *
     * @param _pid      池子 ID
     * @param _spAmount 要销毁的 spToken 数量（= 你要赎回的份额）
     */
    function withdrawLend(uint256 _pid, uint256 _spAmount)  external nonReentrant notPause stateFinishLiquidation(_pid) {
        PoolBaseInfo storage pool = poolBaseInfo[_pid];
        PoolDataInfo storage data = poolDataInfo[_pid];
        require(_spAmount > 0, 'withdrawLend: 取款金额为零');
        // 销毁 sp_token
        pool.spCoin.burn(msg.sender,_spAmount);
        // ★ 关键顺序：先销毁凭证，再给钱。
        //   凭证一旦消失就无法再次出示，从根本上杜绝"一张凭证领两次"
        // 计算销毁份额
        uint256 totalSpAmount = data.settleAmountLend;
        // 池子实际匹配总额（= spToken 的总发行量，两者数值一致）
        // sp份额 = _spAmount/totalSpAmount
        uint256 spShare = _spAmount.mul(calDecimal).div(totalSpAmount);
        // 我烧掉的凭证占总量的比例
        // 完成
        if (pool.state == PoolState.FINISH){
            require(block.timestamp > pool.endTime, "withdrawLend: 少于结束时间");
            // 必须真到期才能赎回（防止有人提前抽走资金，让借款人的贷款提前断供）
            // block.timestamp = 当前区块时间戳
            // 赎回金额 = finishAmountLend * sp份额
            uint256 redeemAmount = data.finishAmountLend.mul(spShare).div(calDecimal);
            // 退款动作
             _redeem(msg.sender,pool.lendToken,redeemAmount);
            emit WithdrawLend(msg.sender,pool.lendToken,redeemAmount,_spAmount);
        }
        // 清算
        if (pool.state == PoolState.LIQUIDATION) {
            require(block.timestamp > pool.settleTime, "withdrawLend: 少于匹配时间");
            // 清算场景只要求过了撮合期即可——清算就是"提前止损"，不能等到期
            // 赎回金额
            uint256 redeemAmount = data.liquidationAmounLend.mul(spShare).div(calDecimal);
            // 退款动作
             _redeem(msg.sender,pool.lendToken,redeemAmount);
            emit WithdrawLend(msg.sender,pool.lendToken,redeemAmount,_spAmount);
        }
    }

       /**
     * @dev 紧急提取贷款
     * @notice 池状态必须是未完成
     * @param _pid 是池索引
     */
    /**
     * 【贷款人·兜底】池子撮合失败（UNDONE）时，全额取回本金
     * 门禁 stateUndone 已保证只在这种"死局"下可调
     * 与 refundLend 的区别：这里是"存多少退多少"，不走份额计算（因为没有匹配，也没有利息）
     */
    function emergencyLendWithdrawal(uint256 _pid) external nonReentrant notPause stateUndone(_pid){
        PoolBaseInfo storage pool = poolBaseInfo[_pid]; // 获取池的基本信息
        require(pool.lendSupply > 0,"emergencLend: not withdrawal"); // 要求贷款供应大于0
        // 贷款紧急提款
        LendInfo storage lendInfo = userLendInfo[msg.sender][_pid]; // 获取用户的贷款信息
        // 限制金额
        require(lendInfo.stakeAmount > 0, "refundLend: not pledged"); // 要求质押金额大于0
        require(!lendInfo.hasNoRefund, "refundLend: again refund"); // 要求没有退款
        // 退款操作
        _redeem(msg.sender,pool.lendToken,lendInfo.stakeAmount); // 执行赎回操作
        // 全额退还本金（不存在利息，因为从未真正放款）
        // 更新用户信息
        lendInfo.hasNoRefund = true; // 设置没有退款为真
        emit EmergencyLendWithdrawal(msg.sender, pool.lendToken, lendInfo.stakeAmount); // 触发紧急贷款提款事件
    }



       /**
     * @dev 借款人质押操作
     * @param _pid 是池子索引
     * @param _stakeAmount 是用户质押的数量
     */
    /**
     * 【借款人·第1步】抵押加密资产（只在撮合期可用）
     *
     * 与 depositLend 高度对称，注意三处差异：
     *  ① 操作对象是 borrowToken（抵押品），不是 lendToken
     *  ② 记账写进 userBorrowInfo，累加 pool.borrowSupply
     *  ③ 没有"池子上限"检查——借款上限是 settle 时按抵押率动态算的
     *     （因为不同价格下，同一堆抵押品能支撑的借款额不同）
     */
    function depositBorrow(uint256 _pid, uint256 _stakeAmount ) external payable nonReentrant notPause timeBefore(_pid) stateMatch(_pid){
        // 基础信息
        PoolBaseInfo storage pool = poolBaseInfo[_pid]; // 获取池子基础信息
        BorrowInfo storage borrowInfo = userBorrowInfo[msg.sender][_pid]; // 获取用户借款信息
        // 动作
        uint256 amount = getPayableAmount(pool.borrowToken, _stakeAmount); // 获取应付金额
        // ★ 动钱时刻：把抵押品（如 BTC）从借款人钱包拉进合约托管
        require(amount > 0, 'depositBorrow: deposit amount is zero'); // 要求质押金额大于0
        // 保存用户信息
        borrowInfo.hasNoClaim = false; // 设置用户未提取质押物
        borrowInfo.hasNoRefund = false; // 设置用户未退款
        // 更新信息
        if (pool.borrowToken == address(0)){ // 如果借款代币是0地址（即ETH）
            borrowInfo.stakeAmount = borrowInfo.stakeAmount.add(msg.value); // 更新用户质押金额
            pool.borrowSupply = pool.borrowSupply.add(msg.value); // 更新池子借款供应量
        } else{ // 如果借款代币不是0地址（即其他ERC20代币）
            borrowInfo.stakeAmount = borrowInfo.stakeAmount.add(_stakeAmount); // 更新用户质押金额
            pool.borrowSupply = pool.borrowSupply.add(_stakeAmount); // 更新池子借款供应量
        }
        emit DepositBorrow(msg.sender, pool.borrowToken, _stakeAmount, amount); // 触发质押借款事件
    }

        /**
     * @dev 退还给借款人的过量存款，当借款人的质押量大于0，且借款供应量减去结算借款量大于0，且借款人没有退款时，计算退款金额并进行退款。
     * @notice 池状态不等于匹配和未完成
     * @param _pid 是池状态
     */
    /**
     * 【借款人·补充动作】拿回多余的抵押品
     *
     * 业务场景：抵押品太多，结算时只锁定"够用"的部分，剩下的退还给借款人。
     * 逻辑与 refundLend 完全对称（份额 → 金额 → 转账 → 打标记）
     */
    function refundBorrow(uint256 _pid) external nonReentrant notPause timeAfter(_pid) stateNotMatchUndone(_pid){
        // 基础信息
        PoolBaseInfo storage pool = poolBaseInfo[_pid]; // 获取池的基础信息
        PoolDataInfo storage data = poolDataInfo[_pid]; // 获取池的数据信息
        BorrowInfo storage borrowInfo = userBorrowInfo[msg.sender][_pid]; // 获取借款人的信息
        // 条件
        require(pool.borrowSupply.sub(data.settleAmountBorrow) > 0, "refundBorrow: not refund"); // 需要借款供应量减去结算借款量大于0
        require(borrowInfo.stakeAmount > 0, "refundBorrow: not pledged"); // 需要借款人的质押量大于0
        require(!borrowInfo.hasNoRefund, "refundBorrow: again refund"); // 需要借款人没有退款
        // 计算用户份额
        uint256 userShare = borrowInfo.stakeAmount.mul(calDecimal).div(pool.borrowSupply); // 用户份额等于借款人的质押量乘以计算小数点后的位数，然后除以借款供应量
        uint256 refundAmount = (pool.borrowSupply.sub(data.settleAmountBorrow)).mul(userShare).div(calDecimal); // 退款金额等于（借款供应量减去结算借款量）乘以用户份额，然后除以计算小数点后的位数
        // 动作
        _redeem(msg.sender,pool.borrowToken,refundAmount); // 赎回
        // 更新用户信息
        borrowInfo.refundAmount = borrowInfo.refundAmount.add(refundAmount); // 更新借款人的退款金额
        borrowInfo.hasNoRefund = true; // 设置借款人已经退款
        emit RefundBorrow(msg.sender, pool.borrowToken, refundAmount); // 触发退款事件
    }

       /**
     * @dev 借款人接收 sp_token 和贷款资金
     * @notice 池状态不等于匹配和未完成
     * @param _pid 是池状态
     */
    /**
     * 【借款人·第2步】领取 jpToken 凭证 + 真正拿到借款 —— 一次交易干两件事
     *
     * 数学关键：jpToken 总量 = 实际匹配贷款额 × 抵押率
     *   例：匹配到 10000 BUSD、抵押率 2.0 → 铸 20000 个 jpToken
     *   含义：这 20000 个凭证背后对应着"2 倍价值"的抵押品，谁烧掉全部 jpToken，
     *        谁就能把全部抵押品赎回去
     */
    function claimBorrow(uint256 _pid) external nonReentrant notPause timeAfter(_pid) stateNotMatchUndone(_pid)  {
        // 池基本信息
        PoolBaseInfo storage pool = poolBaseInfo[_pid];
        PoolDataInfo storage data = poolDataInfo[_pid];
        BorrowInfo storage borrowInfo = userBorrowInfo[msg.sender][_pid];
        // 限制
        require(borrowInfo.stakeAmount > 0, "claimBorrow: 没有索取 jp_token");
        require(!borrowInfo.hasNoClaim,"claimBorrow: 再次索取");
        // 总 jp 数量 = settleAmountLend * martgageRate
        uint256 totalJpAmount = data.settleAmountLend.mul(pool.martgageRate).div(baseDecimal);
        // 池子实际匹配贷款额 × 抵押率 ÷  = jpToken 总发行量
        uint256 userShare = borrowInfo.stakeAmount.mul(calDecimal).div(pool.borrowSupply);
        // 我的抵押品占池子总抵押品的比例
        uint256 jpAmount = totalJpAmount.mul(userShare).div(calDecimal);
        // 我能拿到的 jpToken 数量
        // 铸造 jp token
        pool.jpCoin.mint(msg.sender, jpAmount);
        // 索取贷款资金
        uint256 borrowAmount = data.settleAmountLend.mul(userShare).div(calDecimal);
        // 我能借到的钱 = 匹配总额 × 我的抵押占比
        _redeem(msg.sender,pool.lendToken,borrowAmount);
        // ★ 把贷款币（稳定币）真正转给借款人——借款人"拿到钱"就在这一行
        // 更新用户信息
        borrowInfo.hasNoClaim = true;
        emit ClaimBorrow(msg.sender, pool.borrowToken, jpAmount);
    }

       /**
     * @dev 借款人提取剩余的保证金，这个函数首先检查提取的金额是否大于0，然后销毁相应数量的JPtoken。接着，它计算JPtoken的份额，并根据池的状态（完成或清算）进行相应的操作。如果池的状态是完成，它会检查当前时间是否大于结束时间，然后计算赎回金额并进行赎回。如果池的状态是清算，它会检查当前时间是否大于匹配时间，然后计算赎回金额并进行赎回。
     * @param _pid 是池状态
     * @param _jpAmount 是用户销毁JPtoken的数量
     */
    /**
     * 【借款人·第3步】销毁 jpToken，赎回抵押品
     *   FINISH      → 按 finishAmountBorrow 赎回（还清本息后拿回大部分抵押品）
     *   LIQUIDATION → 按 liquidationAmounBorrow 赎回（清算后往往只剩一点点）
     * 与 withdrawLend 完全对称，只是"币"和"池子数据字段"不同
     */
    function withdrawBorrow(uint256 _pid, uint256 _jpAmount ) external nonReentrant notPause stateFinishLiquidation(_pid) {
        // 声明池基础信息和数据信息的存储
        PoolBaseInfo storage pool = poolBaseInfo[_pid];
        PoolDataInfo storage data = poolDataInfo[_pid];
        // 要求提取的金额大于0
        require(_jpAmount > 0, 'withdrawBorrow: withdraw amount is zero');
        // 销毁jp token
        pool.jpCoin.burn(msg.sender,_jpAmount);
        // 同样是"先销毁凭证、后给资产"的顺序
        // jp份额
        uint256 totalJpAmount = data.settleAmountLend.mul(pool.martgageRate).div(baseDecimal);
        // jpToken 总发行量，必须与 claimBorrow 里的算法完全一致，
        // 否则份额算错、有人会多拿或拿不到（这类"两处公式必须同步"是最容易出 bug 的地方）
        uint256 jpShare = _jpAmount.mul(calDecimal).div(totalJpAmount);
        // 完成状态
        if (pool.state == PoolState.FINISH) {
            // 要求当前时间大于结束时间
            require(block.timestamp > pool.endTime, "withdrawBorrow: less than end time");
            uint256 redeemAmount = jpShare.mul(data.finishAmountBorrow).div(calDecimal);
            _redeem(msg.sender,pool.borrowToken,redeemAmount);
            emit WithdrawBorrow(msg.sender, pool.borrowToken, _jpAmount, redeemAmount);
        }
        // 清算状态
        if (pool.state == PoolState.LIQUIDATION){
            // 要求当前时间大于匹配时间
            require(block.timestamp > pool.settleTime, "withdrawBorrow: less than match time");
            uint256 redeemAmount = jpShare.mul(data.liquidationAmounBorrow).div(calDecimal);
            _redeem(msg.sender,pool.borrowToken,redeemAmount);
            emit WithdrawBorrow(msg.sender, pool.borrowToken, _jpAmount, redeemAmount);
        }
    }
       /**
     * @dev 紧急借款提取
     * @notice 在极端情况下，总存款为0，或者总保证金为0，在某些极端情况下，如总存款为0或总保证金为0时，借款者可以进行紧急提取。首先，代码会获取池子的基本信息和借款者的借款信息，然后检查借款供应和借款者的质押金额是否大于0，以及借款者是否已经进行过退款。如果这些条件都满足，那么就会执行赎回操作，并标记借款者已经退款。最后，触发一个紧急借款提取的事件。
     * @param _pid 是池子的索引
     */
    /**
     * 【借款人·兜底】撮合失败（UNDONE）时取回全部抵押品
     * 与 emergencyLendWithdrawal 对称：存多少退多少，无利息、无手续费
     */
    function emergencyBorrowWithdrawal(uint256 _pid) external nonReentrant notPause stateUndone(_pid) {
        // 获取池子的基本信息
        PoolBaseInfo storage pool = poolBaseInfo[_pid];
        // 确保借款供应大于0
        require(pool.borrowSupply > 0,"emergencyBorrow: not withdrawal");
        // 获取借款者的借款信息
        BorrowInfo storage borrowInfo = userBorrowInfo[msg.sender][_pid];
        // 确保借款者的质押金额大于0
        require(borrowInfo.stakeAmount > 0, "refundBorrow: not pledged");
        // 确保借款者没有进行过退款
        require(!borrowInfo.hasNoRefund, "refundBorrow: again refund");
        // 执行赎回操作
        _redeem(msg.sender,pool.borrowToken,borrowInfo.stakeAmount);
        // 标记借款者已经退款
        borrowInfo.hasNoRefund = true;
        // 触发紧急借款提取事件
        emit EmergencyBorrowWithdrawal(msg.sender, pool.borrowToken, borrowInfo.stakeAmount);
    }

    /**
     * @dev Can it be settle
     * @param _pid is pool index
     */
    /**
     * 【状态检查器 1/3】现在可以结算了吗？
     * 只是个"只读判断"，不改任何状态。给链下机器人（Keeper）轮询用：
     * 返回 true 时，才去调真正的 settle()
     */
    function checkoutSettle(uint256 _pid) public view returns(bool){
        return block.timestamp > poolBaseInfo[_pid].settleTime;   // 过了撮合截止时间就可以结算
    }

       /**
     * @dev  结算
     * @param _pid 是池子的索引
     */
    /**
     * 【状态机引擎 1/3】settle —— 结算：MATCH → EXECUTION（或 MATCH → UNDONE）
     *
     * 这是整个合约数学最密集的地方，它回答一个问题：
     *   "双方存入的资金，按当前价格和抵押率，到底能匹配成多少？"
     *
     * 【数学推导】以 BUSD 贷款、BTC 抵押为例（prices[0]=BUSD价, prices[1]=BTC价）
     *   totalValue  = borrowSupply × (prices[1]/prices[0])
     *               = 抵押的 BTC 数量 × BTC 相对 BUSD 的价格
     *               = 抵押品的美元价值
     *   actualValue = totalValue × 1e8 ÷ martgageRate
     *               = 抵押品价值 ÷ 抵押率 = "这批抵押品合法能撑起的最大贷款额"
     *                 （抵押率 2.0 时：值 20000 美元的 BTC 最多匹配 10000 美元贷款）
     *
     * 然后比较"贷款人愿意给的钱"和"抵押品能撑的钱"，取小的那个成交：
     *   情况 A：lendSupply > actualValue  → 钱多货少，只匹配 actualValue，其余资金退款
     *   情况 B：lendSupply ≤ actualValue  → 全额匹配，多余抵押品退还
     */
    function settle(uint256 _pid) public validCall {
        // 获取基础池信息
        PoolBaseInfo storage pool = poolBaseInfo[_pid];
        // 获取数据池信息
        PoolDataInfo storage data = poolDataInfo[_pid];
        // 需要当前时间大于池子的结算时间
        require(block.timestamp > poolBaseInfo[_pid].settleTime, "settle: 小于结算时间");
        // 池子的状态必须是匹配状态
        require(pool.state == PoolState.MATCH, "settle: 池子状态必须是匹配");
        // 两个门禁：时间到了 + 还在撮合期（防重复结算：结算后状态变了，再调就会被拦下）
        if (pool.lendSupply > 0 && pool.borrowSupply > 0) {
            // —— 双方都有人参与，可以撮合 ——
            // 获取标的物价格
            uint256[2]memory prices = getUnderlyingPriceView(_pid);
            // 返回 [贷款币价格, 抵押币价格]，即 prices[0]=BUSD价、prices[1]=BTC价
            // 总保证金价值 = 保证金数量 * 保证金价格
            uint256 totalValue = pool.borrowSupply.mul(prices[1].mul(calDecimal).div(prices[0])).div(calDecimal);
            // 抵押品数量 × (抵押币价 ÷ 贷款币价) = 抵押品折成贷款币的价值。
            // 中间乘以 1e18 再除回来，是为了在整数运算中保住精度（避免除法先算导致结果为 0）
            // 转换为稳定币价值
            uint256 actualValue = totalValue.mul(baseDecimal).div(pool.martgageRate);
            // 抵押品价值 ÷ 抵押率 = 可支撑的最大贷款额
            if (pool.lendSupply > actualValue){
                // 总借款大于总借出
                // （注释写法有点绕：实际含义是"贷款人多于抵押品能支撑的量"，钱多了）
                data.settleAmountLend = actualValue;
                // 只匹配 actualValue，剩下的钱以后再 refundLend 退给贷款人
                data.settleAmountBorrow = pool.borrowSupply;
                // 抵押品全部锁定（都被用上了）
            } else {
                // 总借款小于总借出
                data.settleAmountLend = pool.lendSupply;
                // 贷款全额成交
                data.settleAmountBorrow = pool.lendSupply.mul(pool.martgageRate).div(prices[1].mul(baseDecimal).div(prices[0]));
                // 只需锁定"够用"的抵押品：
                //   应锁抵押品 = 贷款额 × 抵押率 ÷ (抵押币价/贷款币价)
                // 注意这里的除法顺序：先算 (抵押币价 × 1e8 ÷ 贷款币价) 得到"汇率"，
                // 再用贷款额×抵押率除以汇率。与情况 A 的"乘汇率"是逆运算
            }
            // 更新池子状态
            pool.state = PoolState.EXECUTION;
            // ★ 状态机第一次推进：撮合完成，进入执行期
            // 触发事件
            emit StateChange(_pid,uint256(PoolState.MATCH), uint256(PoolState.EXECUTION));
        } else {
            // 极端情况，借款或借出任一为0
            pool.state = PoolState.UNDONE;
            // ★ 一方没人来 → 撮合失败
            data.settleAmountLend = pool.lendSupply;
            data.settleAmountBorrow = pool.borrowSupply;
            // 两边都按"实际存入"记录，随后各自走 emergency 函数全额退款
            // 触发事件
            emit StateChange(_pid,uint256(PoolState.MATCH), uint256(PoolState.UNDONE));
        }
    }

    /**
     * @dev Can it be finish
     * @param _pid is pool index
     */
    /**
     * 【状态检查器 2/3】现在可以正常结束了吗？（过了借款到期日即可）
     * 同样给链下 Keeper 轮询用
     */
    function checkoutFinish(uint256 _pid) public view returns(bool){
        return block.timestamp > poolBaseInfo[_pid].endTime;
    }

       /**
     * @dev 完成一个借贷池的操作，包括计算利息、执行交换操作、赎回费用和更新池子状态等步骤。
     * @param _pid 是池子的索引
     */
    /**
     * 【状态机引擎 2/3】finish —— 正常结束：EXECUTION → FINISH
     *
     * 【它要解决的现实问题】
     * 借款人抵押的是 BTC，但贷款人要的是 BUSD。到期时怎么办？
     *   → 合约把抵押的 BTC **拿到 DEX 上卖掉**，换成 BUSD 还给贷款人！
     * 这就是为什么项目要接一个 PancakeSwap 路由合约。
     *
     * 【执行五步】
     *  ① 算本息：利息 = 天数比例 × 年化利率 × 匹配贷款额
     *  ② 卖抵押品：卖出的量要覆盖"本息 + 贷款手续费"
     *  ③ 滑点保护：换回来的钱必须 ≥ 应付本息，否则整笔交易回滚
     *  ④ 分账：多出来的部分给平台（feeAddress），其余记入 finishAmountLend
     *  ⑤ 剩的抵押品记账到 finishAmountBorrow，供借款人赎回
     */
    function finish(uint256 _pid) public validCall {
        // 获取基础池子信息和数据信息
        PoolBaseInfo storage pool = poolBaseInfo[_pid];
        PoolDataInfo storage data = poolDataInfo[_pid];

        // 验证当前时间是否大于池子的结束时间
        require(block.timestamp > poolBaseInfo[_pid].endTime, "finish: less than end time");
        // 验证池子的状态是否为执行状态
        require(pool.state == PoolState.EXECUTION,"finish: pool state must be execution");
        // 门禁：真到期 + 处于执行期（防重复 finish）

        // 获取借款和贷款的token
        (address token0, address token1) = (pool.borrowToken, pool.lendToken);
        // 元组解构赋值：token0 = 要卖掉的币（BTC），token1 = 想换到的币（BUSD）
        // 注意：这里"借入/借出"的命名容易让人绕晕，记住 token0 是抵押品、token1 是稳定币即可

        // 计算时间比率 = ((结束时间 - 结算时间) * 基础小数)/365天
        uint256 timeRatio = ((pool.endTime.sub(pool.settleTime)).mul(baseDecimal)).div(baseYear);
        // 借款天数 ÷ 一年天数（放大 1e8 倍保留精度）。
        // 例如借 182.5 天 → timeRatio ≈ 0.5e8 = 50000000

        // 计算利息 = 时间比率 * 利率 * 结算贷款金额
        uint256 interest = timeRatio.mul(pool.interestRate.mul(data.settleAmountLend)).div(1e16);
        // 这里除以 1e16 是因为：timeRatio 是 1e8 精度、interestRate 也是 1e8 精度，
        // 两个 1e8 相乘得到 1e16 倍放大，必须除回去才能得到"正常单位"的利息

        // 计算贷款金额 = 结算贷款金额 + 利息
        uint256 lendAmount = data.settleAmountLend.add(interest);
        // 贷款人应得的总额（本金 + 利息）

        // 计算销售金额 = 贷款金额*(1+贷款费)
        uint256 sellAmount = lendAmount.mul(lendFee.add(baseDecimal)).div(baseDecimal);
        // ⚠️ 变量名叫 sellAmount 但语义容易误读：它其实是"希望换回多少稳定币"（目标产出），
        //    因为下面 _sellExactAmount 的入参是 amountOut（期望得到多少），
        //    多乘 (1+fee) 是为了卖够本息之外再卖出手续费那部分

        // 执行交换操作
        (uint256 amountSell,uint256 amountIn) = _sellExactAmount(swapRouter,token0,token1,sellAmount);
        // 返回 (实际卖出的抵押品数量, 实际换回的稳定币数量)

        // 验证交换后的金额是否大于等于贷款金额
        require(amountIn >= lendAmount, "finish: Slippage is too high");
        // ★ 滑点保护：如果行情波动导致换回的钱不够付本息，整笔交易回滚
        //   宁可失败重试，也不能让贷款人吃亏

        // 如果交换后的金额大于贷款金额，计算费用并赎回
        if (amountIn > lendAmount) {
            uint256 feeAmount = amountIn.sub(lendAmount) ;
            // 差额就是平台赚的手续费（因为 sellAmount 多卖了 (1+fee) 倍）
            // 贷款费
            _redeem(feeAddress,pool.lendToken, feeAmount);
            // 手续费直接转给平台收款地址
            data.finishAmountLend = amountIn.sub(feeAmount);
        }else {
            data.finishAmountLend = amountIn;
        }
        // 记入 finishAmountLend，之后贷款人按 spToken 份额来分这笔钱

        // 计算剩余的借款金额并赎回借款费
        uint256 remianNowAmount = data.settleAmountBorrow.sub(amountSell);
        // 剩余抵押品 = 锁定的抵押品总量 - 卖掉的部分
        uint256 remianBorrowAmount = redeemFees(borrowFee,pool.borrowToken,remianNowAmount);
        // 从剩余抵押品里扣掉借款侧手续费（转给平台），返回借款人实际能赎回的量
        data.finishAmountBorrow = remianBorrowAmount;

        // 更新池子状态为完成
        pool.state = PoolState.FINISH;

        // 触发状态改变事件
        emit StateChange(_pid,uint256(PoolState.EXECUTION), uint256(PoolState.FINISH));
        // ★ 状态机第二次推进：正常收尾
    }


      /**
     * @dev 检查清算条件,它首先获取了池子的基础信息和数据信息，然后计算了保证金的当前价值和清算阈值，最后比较了这两个值，如果保证金的当前价值小于清算阈值，那么就满足清算条件，函数返回true，否则返回false。
     * @param _pid 是池子的索引
     */
    /**
     * 【状态检查器 3/3】现在该清算了吗？—— 风控的核心判断
     *
     * 【判断逻辑】
     *   抵押品当前价值  <  借款额 × (1 + 自动清算阈值)
     *   成立 → 返回 true（抵押品不够还债了，该卖抵押品保护贷款人）
     *
     * 例：借款 10000、阈值 0.2 → 阈值线 12000。
     *     当抵押品市值跌到 12000 以下，就开始清算。
     *     （1.2 倍这个缓冲垫用于覆盖卖币滑点，保证贷款人能拿回本息）
     *
     * ⚠️ 这个函数只是"判断"，不会自己触发清算。谁调用它？—— 本该是链下 Keeper 机器人
     *    （本项目后端代码里目前没有这个调用，这是已知缺口）
     */
    function checkoutLiquidate(uint256 _pid) external view returns(bool) {
        PoolBaseInfo storage pool = poolBaseInfo[_pid]; // 获取基础池信息
        PoolDataInfo storage data = poolDataInfo[_pid]; // 获取池数据信息
        // 保证金价格
        uint256[2]memory prices = getUnderlyingPriceView(_pid); // 获取标的价格视图
        // 保证金当前价值 = 保证金数量 * 保证金价格
        uint256 borrowValueNow = data.settleAmountBorrow.mul(prices[1].mul(calDecimal).div(prices[0])).div(calDecimal);
        // 与 settle 里的 totalValue 算法相同：把锁定的抵押品折成稳定币价值。
        // 注意这里用的是 settleAmountBorrow（结算时锁定的那部分），不是全部抵押品
        // 清算阈值 = settleAmountLend*(1+autoLiquidateThreshold)
        uint256 valueThreshold = data.settleAmountLend.mul(baseDecimal.add(pool.autoLiquidateThreshold)).div(baseDecimal);
        // 借款额 × (1 + 阈值率)
        return borrowValueNow < valueThreshold; // 如果保证金当前价值小于清算阈值，则返回true，否则返回false
    }

        /**
     * @dev 清算
     * @param _pid 是池子的索引
     */
    /**
     * 【状态机引擎 3/3】liquidate —— 强制清算：EXECUTION → LIQUIDATION
     *
     * 流程与 finish 几乎一致（算本息 → 卖抵押品 → 分账），三个关键差异：
     *  ① 时间门禁更宽：只需过了 settleTime，不必等到 endTime（要趁早止损）
     *  ② 记账写进 liquidationAmoun* 字段，而非 finishAmount*
     *  ③ 【重要】少了一道滑点保护：finish 里有 require(amountIn >= lendAmount)，
     *     这里没有。也就是说行情剧烈下跌时，贷款人可能拿不回全部本息——
     *     源码注释也写了"可能会有滑点, amountIn - lendAmount < 0"。
     *     这是接手项目时值得和负责人确认的设计取舍（是有意为之的"共担风险"，还是遗漏）
     */
    function liquidate(uint256 _pid) public validCall {
        PoolDataInfo storage data = poolDataInfo[_pid]; // 获取池子的数据信息
        PoolBaseInfo storage pool = poolBaseInfo[_pid]; // 获取池子的基本信息
        require(block.timestamp > pool.settleTime, "现在的时间小于匹配时间"); // 需要当前时间大于结算时间
        require(pool.state == PoolState.EXECUTION,"liquidate: 池子的状态必须是执行状态"); // 需要池子的状态是执行状态
        // 必须是"已放款但未到期"的执行期，才谈得上提前清算
        // sellamount
        (address token0, address token1) = (pool.borrowToken, pool.lendToken); // 获取借款和贷款的token
        // 时间比率 = ((结束时间 - 结算时间) * 基础小数)/365天
        uint256 timeRatio = ((pool.endTime.sub(pool.settleTime)).mul(baseDecimal)).div(baseYear);
        // 利息 = 时间比率 * 利率 * 结算贷款金额
        uint256 interest = timeRatio.mul(pool.interestRate.mul(data.settleAmountLend)).div(1e16);
        // 与 finish 完全相同的利息公式：清算也要按约定利率把本息还给贷款人，
        // 亏损由借款人承担（这正是"超额抵押"存在的意义）
        // 贷款金额 = 结算贷款金额 + 利息
        uint256 lendAmount = data.settleAmountLend.add(interest);
        // sellamount = lendAmount*(1+lendFee)
        // 添加贷款费用
        uint256 sellAmount = lendAmount.mul(lendFee.add(baseDecimal)).div(baseDecimal);
        (uint256 amountSell,uint256 amountIn) = _sellExactAmount(swapRouter,token0,token1,sellAmount); // 卖出准确的金额
        // 卖出抵押品换稳定币
        // 可能会有滑点，amountIn - lendAmount < 0;
        // ⚠️ 源码自己承认了这个风险点：下跌行情中换回的钱可能不够本息，
        //    而这里**没有** finish 那样的 require 兜底
        if (amountIn > lendAmount) {
            // 换回的钱够付本息，还有富余 → 富余部分即平台手续费
            uint256 feeAmount = amountIn.sub(lendAmount) ; // 费用金额
            // 贷款费用
            _redeem(feeAddress,pool.lendToken, feeAmount);
            data.liquidationAmounLend = amountIn.sub(feeAmount);
        }else {
            // 不够付本息 → 有多少记多少，贷款人按份额分到打折的本息（这就是清算风险）
            data.liquidationAmounLend = amountIn;
        }
        // liquidationAmounBorrow  借款费用
        uint256 remianNowAmount = data.settleAmountBorrow.sub(amountSell); // 剩余的现在的金额
        // 没被卖掉的抵押品（往往已经被卖掉大半，因为抵押品总量是按 2 倍抵押率锁的）
        uint256 remianBorrowAmount = redeemFees(borrowFee,pool.borrowToken,remianNowAmount); // 剩余的借款金额
        // 扣掉借款手续费
        data.liquidationAmounBorrow = remianBorrowAmount;
        // 更新池子状态
        pool.state = PoolState.LIQUIDATION;
         // 事件
        emit StateChange(_pid,uint256(PoolState.EXECUTION), uint256(PoolState.LIQUIDATION));
        // ★ 状态机走向清算分支
    }


      /**
     * @dev 费用计算,计算并赎回费用。首先，它计算费用，这是通过乘以费率并除以基数来完成的。如果计算出的费用大于0，它将从费用地址赎回相应的费用。最后，它返回的是原始金额减去费用。
     */
    /**
     * 【工具】按比例扣手续费
     * @param feeRatio 费率（1e8 精度）
     * @param token    手续费用什么币支付
     * @param amount   待扣费的金额
     * @return 扣完手续费后剩下的金额
     * 副作用：若手续费 > 0，会顺带把钱转给 feeAddress
     */
    function redeemFees(uint256 feeRatio,address token,uint256 amount) internal returns (uint256){
        // 计算费用，费用 = 金额 * 费率 / 基数
        uint256 fee = amount.mul(feeRatio)/baseDecimal;
        // 如果费用大于0
        if (fee>0){
            // 从费用地址赎回相应的费用
            _redeem(feeAddress,token, fee);
        }
        // 返回金额减去费用
        return amount.sub(fee);
        // 注意：这里用的是原生除法 / 而不是 SafeMath 的 .div()，风格不统一
        //（除法没有下溢风险，所以不影响安全，但读代码时会觉得别扭）
    }



    /**
     * @dev Get the swap path
     */
    /**
     * 【DEX 工具 1】构造兑换路径
     * Uniswap 系列的兑换必须有明确的"路径"：比如 BTC → WBNB → BUSD，就要写成 [BTC, WBNB, BUSD]
     * @return path 长度为 2 的数组：[要卖的币, 想换到的币]
     *
     * 特殊处理：原生币（BNB）在 DEX 里要用它的"包装版本" WBNB 参与，所以遇到 address(0) 就换成 WETH() 地址
     * （BSC 上 Pancake 把这个函数仍叫 WETH，实际返回的是 WBNB 地址）
     */
    function _getSwapPath(address _swapRouter,address token0,address token1) internal pure returns (address[] memory path){
        IUniswapV2Router02 IUniswap = IUniswapV2Router02(_swapRouter);
        path = new address[](2);   // 只支持"直接兑换"（两个币之间有交易对），不做多跳
        path[0] = token0 == address(0) ? IUniswap.WETH() : token0;
        // 三元运算符：是零地址就取包装币地址，否则用原地址
        path[1] = token1 == address(0) ? IUniswap.WETH() : token1;
    }

     /**
      * @dev Get input based on output
      */
    /**
     * 【DEX 工具 2】反推"想换到 X，需要先卖出多少"
     * 也叫"exact output"策略：先定目标产出，再算需要投入多少（对借款人更友好——能精确控制还款金额）
     */
    function _getAmountIn(address _swapRouter,address token0,address token1,uint256 amountOut) internal view returns (uint256){
        IUniswapV2Router02 IUniswap = IUniswapV2Router02(_swapRouter);
        address[] memory path = _getSwapPath(swapRouter,token0,token1);
        // ⚠️ 细节：这里路径用的是全局变量 swapRouter，而不是入参 _swapRouter；
        //    调用方 _sellExactAmount 传入的也正好是全局变量，所以当前不出问题，
        //    但如果将来有人用别的路由地址调用这个函数，就会拿到错误价格——属于潜在坑
        uint[] memory amounts = IUniswap.getAmountsIn(amountOut, path);
        // 由 DEX 根据当前池子储备算出所需输入量
        return amounts[0];
        // amounts[0] = 需要付出的 token0 数量
    }

     /**
      * @dev sell Exact Amount
      */
    /**
     * 【DEX 工具 3】"精确产出"卖出：卖出恰好足够的抵押品，换回指定数量的稳定币
     * @return (实际卖出的数量, 实际换回的数量)
     */
    function _sellExactAmount(address _swapRouter,address token0,address token1,uint256 amountout) internal returns (uint256,uint256){
        uint256 amountSell = amountout > 0 ? _getAmountIn(swapRouter,token0,token1,amountout) : 0;
        // 目标产出为 0 时直接跳过询价（省 gas，也为避免 DEX 报错）
        return (amountSell,_swap(_swapRouter,token0,token1,amountSell));
        // 先问"要卖多少"，再真的执行兑换
    }

    /**
      * @dev Swap
      */
    /**
     * 【DEX 工具 4】真正执行兑换
     * 步骤：① 授权 DEX 可以动我们的币 ② 按币种类型调对应的 swap 方法 ③ 抛 Swap 事件
     * @return 最终换到的 token1 数量
     */
    function _swap(address _swapRouter,address token0,address token1,uint256 amount0) internal returns (uint256) {
        if (token0 != address(0)){
            _safeApprove(token0, address(_swapRouter), uint256(-1));
            // 授权额度设为 uint256(-1)（即 2^256-1，无限大）。
            // 好处：以后不用每次卖币都重新授权，省 gas；坏处：DEX 合约若有漏洞，
            // 我们的代币理论上可被无限转走。安全审计时这是一个常见讨论点
        }
        if (token1 != address(0)){
            _safeApprove(token1, address(_swapRouter), uint256(-1));
        }
        IUniswapV2Router02 IUniswap = IUniswapV2Router02(_swapRouter);
        address[] memory path = _getSwapPath(_swapRouter,token0,token1);
        uint256[] memory amounts;
        if(token0 == address(0)){
            // 用原生币（BNB）买代币：需要把 amount0 作为 value 随调用发送
            // {value:amount0} 是 Solidity 的"调用时携带原生币"语法
            // now+30 = 交易有效期 30 秒（now 是 block.timestamp 的旧写法，现已弃用）
            amounts = IUniswap.swapExactETHForTokens{value:amount0}(0, path,address(this), now+30);
            // 参数中的 0 = 滑点容忍度设为"无限"（不限制最少收到多少），
            // 也就是说：**这里没有滑点保护**！真正的最小值保护靠外层的 require 与
            // 上游的"精确产出"策略来兜底（因为卖出量是按目标产出反推的）
        }else if(token1 == address(0)){
            // 把代币卖成原生币
            amounts = IUniswap.swapExactTokensForETH(amount0,0, path, address(this), now+30);
        }else{
            // 代币换代币（项目主流程：BTC 换 BUSD）
            amounts = IUniswap.swapExactTokensForTokens(amount0,0, path, address(this), now+30);
        }
        emit Swap(token0,token1,amounts[0],amounts[amounts.length-1]);
        // amounts[0] = 实际付出的量；amounts[最后一个] = 实际收到的量（数组首尾就是输入输出）
        return amounts[amounts.length-1];
    }

    /**
     * @dev Approve
     */
    /**
     * 【工具】安全授权（低级调用版，与 SafeToken.safeApprove 一个套路）
     * 0x095ea7b3 = approve(address,uint256) 的函数选择器
     * 检查 success 与返回值，兼容"不返回值的代币"
     */
    function _safeApprove(address token, address to, uint256 value) internal {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0x095ea7b3, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "!safeApprove");
    }

       /**
     * @dev 获取最新的预言机价格
     */
    /**
     * 【工具】查本池子两个币的价格
     * @return [贷款币价格, 抵押币价格]
     *   prices[0] = lendToken 价格（如 BUSD ≈ 1e8 表示 1.00 美元）
     *   prices[1] = borrowToken 价格（如 BTC ≈ 2000e8 表示 20000 美元）
     * settle / checkoutLiquidate 都靠它把"币的数量"折算成"美元价值"
     */
    function getUnderlyingPriceView(uint256 _pid) public view returns(uint256[2]memory){
        // 从基础池中获取指定的池
        PoolBaseInfo storage pool = poolBaseInfo[_pid];
        // 创建一个新的数组来存储资产
        uint256[] memory assets = new uint256[](2);
        // 将借款和贷款的token添加到资产数组中
        assets[0] = uint256(pool.lendToken);     // 把地址转成整数，因为预言机的 key 是 uint256
        assets[1] = uint256(pool.borrowToken);
        // 从预言机获取资产的价格
        uint256[]memory prices = oracle.getPrices(assets);
        // 调用预言机批量取价（BscPledgeOracle.getPrices）
        // 返回价格数组
        return [prices[0],prices[1]];
        // 这里做了一个数组字面量构造，把结果塞进定长数组 uint256[2] 里返回
    }

    /**
     * @dev set Pause
     */
    /**
     * 【管理员】全局暂停开关（一键拉闸）
     * 每次调用取反：从"运行"变"暂停"，再调一次变回"运行"
     * 注意它自己也带 validCall —— 解锁同样需要多签批准，防止单点作恶
     */
    function setPause() public validCall {
        globalPaused = !globalPaused;
        // ! 是逻辑取反
    }

    /**
     * 【修饰符】notPause：全局未暂停才允许执行
     * 用户侧的所有存/取/领/赎函数都挂着它，出事时管理员可一键冻结
     */
    modifier notPause() {
        require(globalPaused == false, "Stake has been suspended");
        _;
    }


    /**
     * 【修饰符】timeBefore：必须在撮合截止前
     * 用途：存钱类操作（depositLend / depositBorrow）
     * 报错文案写的是 "Less than this time"，字面意思容易理解反，实际含义是"时间还没到 settleTime"
     */
    modifier timeBefore(uint256 _pid) {
        require(block.timestamp < poolBaseInfo[_pid].settleTime, "Less than this time");
        _;
    }

    /**
     * 【修饰符】timeAfter：必须在撮合截止后
     * 用途：领取凭证、退款、赎回等（因为要等 settle 算完账才能操作）
     */
    modifier timeAfter(uint256 _pid) {
        require(block.timestamp > poolBaseInfo[_pid].settleTime, "Greate than this time");
        _;
    }


    /**
     * 【修饰符】stateMatch：池子必须处于撮合期
     */
    modifier stateMatch(uint256 _pid) {
        require(poolBaseInfo[_pid].state == PoolState.MATCH, "state: Pool status is not equal to match");
        _;
    }

    /**
     * 【修饰符】stateNotMatchUndone：池子"不是撮合期、也不是失败"
     * 也就是只允许 EXECUTION / FINISH / LIQUIDATION 三态
     * 用途：退款、领凭证（这三种状态下账目才算清楚）
     */
    modifier stateNotMatchUndone(uint256 _pid) {
        require(poolBaseInfo[_pid].state == PoolState.EXECUTION || poolBaseInfo[_pid].state == PoolState.FINISH || poolBaseInfo[_pid].state == PoolState.LIQUIDATION,"state: not match and undone");
        _;
    }

    /**
     * 【修饰符】stateFinishLiquidation：池子已结束或已清算
     * 用途：赎回类操作（withdrawLend / withdrawBorrow）——只有结算完才能按比例分钱
     */
    modifier stateFinishLiquidation(uint256 _pid) {
        require(poolBaseInfo[_pid].state == PoolState.FINISH || poolBaseInfo[_pid].state == PoolState.LIQUIDATION,"state: finish liquidation");
        _;
    }

    /**
     * 【修饰符】stateUndone：池子已确认撮合失败
     * 用途：两个 emergencyXxxWithdrawal 兜底退款函数
     */
    modifier stateUndone(uint256 _pid) {
        require(poolBaseInfo[_pid].state == PoolState.UNDONE,"state: state must be undone");
        _;
    }

}
