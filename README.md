# pledgeV2
pledge V2 contract

## 本地运行

```
npm install
npx hardhat compile
npx hardhat test
npx hardhat ignition deploy ./ignition/modules/PledgePool.js

```

## 部署 multiSignature 到 sepolia

敲黑板
!!! 需要先部署 multiSignature 到 sepolia ，然后 注意 那3管理员钱包地址，写你自己的，可以交互控制！！！
```js
// scripts/deploy/multiSignature.js
// 第五行代码开始！！！
let multiSignatureAddress = ["0x3D7155586d33a31851e28bd4Ead18A413Bc8F599",
                            "0xc3C6Ef79897Df94ddd86189A86BD9c5c7bB93Cf6",
                            "0x3B720fBacd602bccd65F82c20F8ECD5Bbb295c0a"];
let threshold = 2;
```

```shell
npx hardhat run scripts/deploy/multiSignature.js --network sepolia
```
这里，我们得到了一个多签名地址，然后 在 scripts/deploy/debtToken.js 中 使用这个地址
就叫 multiSignatureAddress

## 部署 debtToken 到 sepolia

敲黑板
！！！这里 multiSignatureAddress 取上面部署得到的地址！！！
```js
// scripts/deploy/debtToken.js
// 第10行代码开始！！！
let multiSignatureAddress = "0xa5D1E71aC4cE6336a70E8a0cb1B6DFa87BccEf4c";
```

```shell
npx hardhat run scripts/deploy/debtToken.js --network sepolia
```

## 部署 swapRouter 到 sepolia
npx hardhat run scripts/deploy/swapRouter.js --network sepolia

## 部署 pledgePool 到 sepolia
npx hardhat run scripts/deploy/pledgePool.js --network sepolia


```



WBNB:0xd0772b878adb5c739b878e2afa060cea4a3fbc14
https://sepolia.etherscan.io/address/0xd0772b878adb5c739b878e2afa060cea4a3fbc14#code

PancakeFactory
0x5e1B1049AB259cB09e341B4f0d9426896b89fA9f

PANCAKEROUTER 
0x3b75bC4e6dBAcd54023aFCB8dF0Bcd040086EabF
https://sepolia.etherscan.io/address/0x3b75bc4e6dbacd54023afcb8df0bcd040086eabf#code

multiSignature
0x1257F1804B73b8125f399A2c440763DF86FF6B50
https://sepolia.etherscan.io/address/0x1257f1804b73b8125f399a2c440763df86ff6b50#code

BscPledgeOracle
0xB574D61E7121320D708C6eC988c9CDEEc0cDDAEa
https://sepolia.etherscan.io/address/0xb574d61e7121320d708c6ec988c9cdeec0cddaea#code

PledgePool
0xbEd2F048532b859EA0272E87C07489ad7A1772DE
https://sepolia.etherscan.io/address/0xbed2f048532b859ea0272e87c07489ad7a1772de#code

DebtToken
Jpbtc 
0x3b80F1c05e331eb742Db0696038F349EEFEdae5d
https://sepolia.etherscan.io/address/0x3b80f1c05e331eb742db0696038f349eefedae5d#code

Jpbusd 
0x363a91fB59bEC3399a9f656A76304CDa9B34E66d
https://sepolia.etherscan.io/address/0x363a91fb59bec3399a9f656a76304cda9b34e66d



#### BSC TEST NETWORK CONTRACTS

- BUSD TOKEN : 0xE676Dcd74f44023b95E0E2C6436C97991A7497DA
- BTC TOKEN : 0xB5514a4FA9dDBb48C3DE215Bc9e52d9fCe2D8658
- DAI TOKEN : 0x490BC3FCc845d37C1686044Cd2d6589585DE9B8B
- BNB TOKEN : 0x0000000000000000000000000000000000000000 
  
- ORACLE ADDRESS: 0x272aCa56637FDaBb2064f19d64BC3dE64A85A1b2
- SWAP ADDRESS: 0xbe9c40a0eab26a4223309ea650dea0dd4612767e
- FEE ADDRESS： 0x0ff66Eb23C511ABd86fC676CE025Ca12caB2d5d4
- PLEDGE ADDRESS: 0x216f718A983FCCb462b338FA9c60f2A89199490c
- MULTISIGNATURE: 0xcdC5A05A0A68401d5FCF7d136960CBa5aEa990Dd
