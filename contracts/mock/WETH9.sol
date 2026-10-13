
/**
 * ════════════════════════════════════════════════════════════════════════════
 *  【本文件导读】WETH9.sol —— 包装原生币合约（测试用）
 * ════════════════════════════════════════════════════════════════════════════
 *  【什么是"包装原生币"】
 *  原生币（ETH/BNB）不符合 ERC20 标准，没法直接放进交易所的流动性池。
 *  于是有了"包装"机制：你存入 1 个 ETH，合约给你 1 个 WETH（符合 ERC20 的代币），
 *  反之也可以赎回。PancakeSwap 在 BSC 上部署的这个版本叫 WBNB。
 *
 *  【在本项目中的作用】
 *  PledgePool._getSwapPath 里有一句：
 *      path[0] = token0 == address(0) ? IUniswap.WETH() : token0;
 *  也就是说：当池子用的是原生币（地址写 0）时，兑换路径里要自动替换成包装币地址。
 *  本文件就是提供那个"包装币"的测试实现。
 *
 *  【阅读建议】★ 跳过 ★
 *  标准的 WETH9 实现（用 0.4.18 老编译器，来自以太坊官方版本），与业务逻辑无关。
 * ════════════════════════════════════════════════════════════════════════════
 */

pragma solidity ^0.4.18;

contract WETH9 {
    string public name     = "Wrapped Ether";
    string public symbol   = "WETH";
    uint8  public decimals = 18;

    event  Approval(address indexed src, address indexed guy, uint wad);
    event  Transfer(address indexed src, address indexed dst, uint wad);
    event  Deposit(address indexed dst, uint wad);
    event  Withdrawal(address indexed src, uint wad);

    mapping (address => uint)                       public  balanceOf;
    mapping (address => mapping (address => uint))  public  allowance;

    function() public payable {
        deposit();
    }
    function deposit() public payable {
        balanceOf[msg.sender] += msg.value;
        Deposit(msg.sender, msg.value);
    }
    function withdraw(uint wad) public {
        require(balanceOf[msg.sender] >= wad);
        balanceOf[msg.sender] -= wad;
        msg.sender.transfer(wad);
        Withdrawal(msg.sender, wad);
    }

    function totalSupply() public view returns (uint) {
        return this.balance;
    }

    function approve(address guy, uint wad) public returns (bool) {
        allowance[msg.sender][guy] = wad;
        Approval(msg.sender, guy, wad);
        return true;
    }

    function transfer(address dst, uint wad) public returns (bool) {
        return transferFrom(msg.sender, dst, wad);
    }

    function transferFrom(address src, address dst, uint wad)
        public
        returns (bool)
    {
        require(balanceOf[src] >= wad);

        if (src != msg.sender && allowance[src][msg.sender] != uint(-1)) {
            require(allowance[src][msg.sender] >= wad);
            allowance[src][msg.sender] -= wad;
        }

        balanceOf[src] -= wad;
        balanceOf[dst] += wad;

        Transfer(src, dst, wad);

        return true;
    }
}