// SPDX-License-Identifier: MIT
// 开源许可证：MIT

pragma solidity =0.6.12;
// 编译器版本锁定（=0.6.12 与 0.6.12 含义相同，这里写成"等于"的显式形式）

// Ownable：OpenZeppelin 的基础权限合约，提供 onlyOwner 修饰符
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * ============================================================================
 *  MockOracle —— 测试用的"假预言机"
 * ============================================================================
 *  【为什么需要它】
 *  真实预言机 BscPledgeOracle 要走 Chainlink，测试环境里没有真实喂价。
 *  测试时换成这个 MockOracle：价格完全由测试脚本自己设置，
 *  于是就能模拟任意行情（比如"BTC 从 20000 跌到 8000"）来验证清算逻辑。
 *
 *  【与真实预言机的区别】
 *  1. 权限用 onlyOwner（单个管理员），真实版用 validCall（多签）
 *  2. 没有 Chainlink 分支，只有一张手动价格表
 *  3. 没有小数位换算逻辑，取多少就是多少
 *
 *  【典型用法（见 tests/ 里的测试脚本）】
 *  部署 → setPrice(BTC地址, 20000e8) → 开池 → 存款 → 改价 → 验证清算
 * ============================================================================
 */
contract MockOracle is Ownable {

    // 代币 → 小数位（本 Mock 里其实没被使用，属于与真实版保持结构一致而保留的字段）
    mapping(uint256 => uint256) internal decimalsMap;
    // 代币地址 → 价格（本 Mock 的核心数据，测试脚本往这里写）
    mapping(address => uint256) internal priceMap;
    // 全局精度除数（同样未被使用）
    uint256 internal decimals = 1;

    /**
     * 【设置价格】只有 owner 能改（测试里通常就是部署脚本用的那个账号）
     * @param asset 代币地址
     * @param price 价格（1e8 精度）
     */
    function setPrice(address asset,uint256 price) public onlyOwner {
        priceMap[asset] = price;
    }

    /**
     * 【取价·按地址】直接返回设定好的价格
     */
    function getPrice(address asset) public view returns (uint256) {
        return priceMap[asset];
    }

    /**
     * 【取价·批量】传入一组代币，逐个查价返回
     * PledgePool.getUnderlyingPriceView 走的就是这条路径
     */
    function getPrices(uint256[]memory assets) public view returns (uint256[]memory) {
        uint256 len = assets.length;
        uint256[] memory prices = new uint256[](len);   // 新建等长数组装结果
        for (uint i=0;i<len;i++){
            prices[i] = getUnderlyingPrice(assets[i]);   // 逐个取价
        }
        return prices;
    }

     /**
      * 【取价·按整数 key】把整数转回地址再查表
      * 因为 PledgePool 传来的 key 是"地址转成的整数"，这里转回来才能对上 priceMap 的 key
      */
     function getUnderlyingPrice(uint256 underlying) public view returns (uint256) {
         return priceMap[address(underlying)];   // address(underlying) 把整数转回地址类型
     }
}
