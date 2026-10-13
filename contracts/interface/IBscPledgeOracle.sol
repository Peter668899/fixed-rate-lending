// SPDX-License-Identifier: MIT
// 开源许可证：MIT

pragma solidity 0.6.12;
// 编译器版本锁定 0.6.12


/**
 * ============================================================================
 *  IBscPledgeOracle —— 价格预言机接口
 * ============================================================================
 *  PledgePool 用它来查"贷款币"和"抵押币"的价格，进而计算：
 *   - settle()            抵押品能支撑多少贷款（按抵押率折算）
 *   - checkoutLiquidate()  抵押品是否跌破清算线
 *
 *  真实实现见 pledge/BscPledgeOracle.sol：
 *  优先读 Chainlink 聚合器的实时喂价，没配聚合器时退回读管理员手动设置的价格。
 *
 *  【价格单位统一约定】1e8 精度：200000000 表示 2.00
 * ============================================================================
 */
interface IBscPledgeOracle {
    /**
      * @notice retrieves price of an asset
      * @dev function to get price for an asset
      * @param asset Asset for which to get the price
      * @return uint mantissa of asset price (scaled by 1e8) or zero if unset or contract paused
      */
    function getPrice(address asset) external view returns (uint256);
    // 按代币地址查单个价格（本项目主流程没直接用它，主流程用下面的批量版）

    function getUnderlyingPrice(uint256 cToken) external view returns (uint256);
    // 按"整数形式的 key"查价。注意参数名 cToken 是从别的项目抄来的历史遗留命名，
    // 在本项目里它其实代表"代币地址转成的整数"

    function getPrices(uint256[] calldata assets) external view returns (uint256[]memory);
    // ★ PledgePool 实际使用的就是它：一次传两个币（贷款币、抵押币），一次拿回两个价格
    //   calldata 表示参数放在"调用数据区"（省 gas，只读场景的推荐写法）
    //   真实实现里写的是 memory，两种写法在此处兼容
}
