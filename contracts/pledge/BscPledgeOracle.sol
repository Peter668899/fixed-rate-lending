// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

// multiSignatureClient：多签基类。本合约所有 setXXX 都要多签批准（validCall）
import "../multiSignature/multiSignatureClient.sol";
// Chainlink 价格预言机的标准接口：链下交易所把价格喂到链表合约里，链上直接读
import "@chainlink/contracts/src/v0.6/interfaces/AggregatorV3Interface.sol";


/**
 * ============================================================================
 *  BscPledgeOracle —— 价格预言机（Pledge 的"行情报价牌"）
 * ============================================================================
 *  【为什么借贷协议离不开预言机】
 *  合约要判断"抵押品够不够值钱"，必须知道 BTC 现在多少美元。
 *  但合约自己上不了网，拿不到外部数据——这就是"预言机"存在的理由：
 *  由可信的链下服务（如 Chainlink）把价格写进一个链表合约，合约再去读。
 *
 *  这个价格用在两处关键位置：
 *  1. settle()   结算时把 BTC 折算成美元，算出最多能匹配多少贷款
 *  2. checkoutLiquidate() 判断抵押率是否跌破清算线
 *  价格一旦失真，整个借贷协议的安全性就崩了（这是 DeFi 被黑的重灾区）。
 *
 *  【本合约的两种取价模式】
 *  模式 A（首选）：接了 Chainlink 聚合器（assetsMap），实时读链上喂价
 *  模式 B（兜底）：管理员手动 setPrice/setPrices（priceMap），测试网常用
 *  getUnderlyingPrice 会先看有没有聚合器，有就用 A，没有就退回 B。
 *
 *  【三个映射表，key 都是 uint256 形式的代币地址】
 *  assetsMap[代币]   → 该代币对应的 Chainlink 聚合器合约
 *  decimalsMap[代币] → 聚合器返回的价格是几位小数
 *  priceMap[代币]    → 手动设置的价格（scaled by 1e8）
 * ============================================================================
 */
contract BscPledgeOracle is multiSignatureClient {

    // 代币地址 → Chainlink 聚合器合约（address 转 uint256 后作 key）
    mapping(uint256 => AggregatorV3Interface) internal assetsMap;
    // 代币地址 → 聚合器价格的小数位数（用于把价格统一换算成 18 位）
    mapping(uint256 => uint256) internal decimalsMap;
    // 代币地址 → 手动设置的价格（单位 1e8，即 200000000 = 2.00）
    mapping(uint256 => uint256) internal priceMap;
    // 全局精度除数，默认 1（可由 setDecimals 修改，用来把聚合器价格缩放到我们想要的口径）
    uint256 internal decimals = 1;

    /**
     * 构造函数
     * @param multiSignature 多签合约地址
     * 注意：函数体里那些被注释掉的代码，是主网/测试网各代币的 Chainlink 聚合器地址，
     *      部署时按网络环境手动填入（写死在构造函数里便于部署后即用）
     */
    constructor(address multiSignature) multiSignatureClient(multiSignature) public {
//        //  bnb/USD
//        assetsMap[uint256(0x0000000000000000000000000000000000000000)] = AggregatorV3Interface(0x2514895c72f50D8bd4B4F9b1110F0D6bD2c97526);
//        // DAI/USD
//        assetsMap[uint256(0xf2bDB4ba16b7862A1bf0BE03CD5eE25147d7F096)] = AggregatorV3Interface(0xE4eE17114774713d2De0eC0f035d4F7665fc025D);
//        // BTC/USD
//        assetsMap[uint256(0xF592aa48875a5FDE73Ba64B527477849C73787ad)] = AggregatorV3Interface(0x5741306c21795FdCBb9b265Ea0255F499DFe515C);
//        // BUSD/USD
//        assetsMap[uint256(0xDc6dF65b2fA0322394a8af628Ad25Be7D7F413c2)] = AggregatorV3Interface(0x9331b55D9830EF609A2aBCfAc0FBCE050A52fdEa);
//
//
//        decimalsMap[uint256(0x0000000000000000000000000000000000000000)] = 18;
//        decimalsMap[uint256(0xf2bDB4ba16b7862A1bf0BE03CD5eE25147d7F096)] = 18;
//        decimalsMap[uint256(0xF592aa48875a5FDE73Ba64B527477849C73787ad)] = 18;
//        decimalsMap[uint256(0xDc6dF65b2fA0322394a8af628Ad25Be7D7F413c2)] = 18;

    }

    /**
      * @notice set the precision
      * @dev function to update precision for an asset
      * @param newDecimals replacement oldDecimal
      */
    /**
     * 【设精度】修改全局除数 decimals（影响所有价格读出的大小）
     * 只在特殊口径对接时才用，默认 1 不用改
     */
    function setDecimals(uint256 newDecimals) public validCall{
        decimals = newDecimals;
    }


    /**
      * @notice Set prices in bulk
      * @dev function to update prices for an asset
      * @param prices replacement oldPrices
      */
    /**
     * 【批量设价】管理员一次性把多个代币的价格写进 priceMap（走多签）
     * 典型用途：测试网上没有 Chainlink，就由后端定时任务喂一个固定价
     * @param assets 代币列表（存的是 uint256 形式的地址）
     * @param prices 对应价格列表（1e8 精度）
     */
    function setPrices(uint256[]memory assets,uint256[]memory prices) external validCall {
        // 两个数组长度必须一致，否则下面按下标对应会错位
        require(assets.length == prices.length, "input arrays' length are not equal");
        uint256 len = assets.length;
        for (uint i=0;i<len;i++){
            // 注意：这里用循环下标 i 当 key，而不是 assets[i]。
            // 也就是说这个函数的写入位置是 0,1,2...，而不是按代币地址写；
            // 用真实源码时要留意这个细节（与 getUnderlyingPrice 按地址取值的口径不一致）
            priceMap[i] = prices[i];
        }
    }

    /**
      * @notice retrieve prices of assets in bulk
      * @dev function to get price for an assets
      * @param  assets Asset for which to get the price
      * @return uint mantissa of asset price (scaled by 1e8) or zero if unset or contract paused
      */
    /**
     * 【批量取价】传入一批代币，逐个查出价格返回
     * @param assets 代币列表
     * @return 与入参一一对应的价格数组（1e8 精度）
     */
    function getPrices(uint256[]memory assets) public view returns (uint256[]memory) {
        uint256 len = assets.length;
        // memory 数组：只在本次调用期间存在（不写链、不花存储费）
        uint256[] memory prices = new uint256[](len);
        for (uint i=0;i<len;i++){
            prices[i] = getUnderlyingPrice(assets[i]);   // 复用单个取价的逻辑
        }
        return prices;
    }

    /**
      * @notice retrieves price of an asset
      * @dev function to get price for an asset
      * @param asset Asset for which to get the price
      * @return uint mantissa of asset price (scaled by 1e8) or zero if unset or contract paused
      */
    /**
     * 【按地址取价】传入代币合约地址（address），转成 uint256 当 key 去查
     * 这是给外部合约最常用的入口——PledgePool 就是通过它拿价格
     * @param asset 代币地址
     * @return 价格（1e8 精度）
     */
    function getPrice(address asset) public view returns (uint256) {
        return getUnderlyingPrice(uint256(asset));   // uint256(asset) 把地址强制转成整数
    }

    /**
      * @notice get price based on index
      * @dev function to get price for index
      * @param underlying for which to get the price
      * @return uint mantissa of asset price (scaled by 1e8) or zero if unset or contract paused
      */
    /**
     * 【核心取价逻辑】整个预言机的分叉点就在这里
     * 流程：
     *   1. 看这个 key 有没有配 Chainlink 聚合器
     *   2. 有 → 实时读链上喂价（顺带按小数位统一成 18 位口径）
     *   3. 没有 → 退回去读管理员手动设置的价格 priceMap
     *
     * @param underlying 代币地址的整数形式
     * @return 价格，统一到 1e8 精度（200000000 表示 2.00）
     */
    function getUnderlyingPrice(uint256 underlying) public view returns (uint256) {
        AggregatorV3Interface assetsPrice = assetsMap[underlying];
        if (address(assetsPrice) != address(0)){
            // —— 模式 A：读 Chainlink ——
            // latestRoundData() 返回 5 个值，我们只要第 2 个 price（价格）
            // 第一个空格是 roundId，后面三个 updateAt/answeredInRound 等暂不使用，
            // 所以写成 (, int price,,,) —— 用逗号占位跳过不需要的返回值
            (, int price,,,) = assetsPrice.latestRoundData();
            uint256 tokenDecimals = decimalsMap[underlying];
            if (tokenDecimals < 18){
                // 价格小数位少于 18：先除以全局精度，再补齐到 18 位
                // 例：price=2000_00000000(8位) → /1 → ×10^10 → 2000e18
                return uint256(price)/decimals*(10**(18-tokenDecimals));
            }else if (tokenDecimals > 18){
                // 大于 18 位的分支：注意这里写的是 18-tokenDecimals，
                // 无符号整数相减会下溢成极大值，10**极大值 又会溢出——这一支实际不可用。
                // 现实中没有 >18 位小数的代币，所以从没被触发；读代码时知道这是个"死分支"即可。
                return uint256(price)/decimals/(10**(18-tokenDecimals));
            }else{
                // 恰好 18 位：最常见的路径（BSC 上多数代币都是 18 位），只做全局精度缩放
                return uint256(price)/decimals;
            }
        }else {
            // —— 模式 B：读管理员手动写入的价格 ——
            // 测试网场景：后端 schedule 里的 SavePlgrPriceTestNet 就是往这里写固定价
            return priceMap[underlying];
        }
    }


    /**
      * @notice set price of an asset
      * @dev function to set price for an asset
      * @param asset Asset for which to set the price
      * @param price the Asset's price
      */
    /**
     * 【设价·按地址】给某个代币地址设置手动价格（1e8 精度），走多签
     */
    function setPrice(address asset,uint256 price) public validCall {
        priceMap[uint256(asset)] = price;
    }

    /**
      * @notice set price of an underlying
      * @dev function to set price for an underlying
      * @param underlying underlying for which to set the price
      * @param price the underlying's price
      */
    /**
     * 【设价·按整数 key】同上，只是入参是整数形式
     * 要求 underlying > 0：因为 0 这个 key 在 BSC 上通常代表"原生币 BNB"，
     * 留个空位给特殊用途（不同项目约定不同，这里选择禁止用 0）
     */
    function setUnderlyingPrice(uint256 underlying,uint256 price) public validCall {
        require(underlying>0 , "underlying cannot be zero");
        priceMap[underlying] = price;
    }

    /**
      * @notice set price of an asset
      * @dev function to set price for an asset
      * @param asset Asset for which to set the price
      * @param aggergator the Asset's aggergator
      */
    /**
     * 【绑定聚合器·按地址】给某代币挂上 Chainlink 聚合器，并记录价格小数位
     * 部署后由多签调用一次即可长期自动取价
     */
    function setAssetsAggregator(address asset,address aggergator,uint256 _decimals) public validCall {
        assetsMap[uint256(asset)] = AggregatorV3Interface(aggergator);   // 记录聚合器合约
        decimalsMap[uint256(asset)] = _decimals;                         // 记录它的小数位
    }

    /**
      * @notice set price of an underlying
      * @dev function to set price for an underlying
      * @param underlying underlying for which to set the price
      * @param aggergator the underlying's aggergator
      */
    /**
     * 【绑定聚合器·按整数 key】同上，同样禁止 key 为 0
     */
    function setUnderlyingAggregator(uint256 underlying,address aggergator,uint256 _decimals) public validCall {
        require(underlying>0 , "underlying cannot be zero");
        assetsMap[underlying] = AggregatorV3Interface(aggergator);
        decimalsMap[underlying] = _decimals;
    }

    /** @notice get asset aggregator based on asset
      * @dev function to get aggregator for asset
      * @param asset for which to get the aggregator
      * @ return  an asset aggregator
      */
    /**
     * 【查配置·按地址】返回某代币绑定的聚合器地址与小数位
     * returns (address,uint256) 表示一次返回两个值（Solidity 支持多返回值）
     * 注意返回的 address 是"聚合器地址"，不是代币地址
     */
    function getAssetsAggregator(address asset) public view returns (address,uint256) {
        return (address(assetsMap[uint256(asset)]),decimalsMap[uint256(asset)]);
    }

     /**
       * @notice get asset aggregator based on index
       * @dev function to get aggregator for index
       * @param underlying for which to get the aggregator
       * @ return an asset aggregator
       */
    /**
     * 【查配置·按整数 key】同上
     */
    function getUnderlyingAggregator(uint256 underlying) public view returns (address,uint256) {
        return (address(assetsMap[underlying]),decimalsMap[underlying]);
    }

}
