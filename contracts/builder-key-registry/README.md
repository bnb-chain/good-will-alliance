# Builder Key Registry

[Contract usage guide (English)](docs/usage.md) — interfaces, limits, ownership, and integration behavior.

BSC MEV builder 签名 key 的链上注册表。MEV-Sentry 定期读取 `getBuilders()` 并替换本地 allowlist，
取代目前各 validator 手工维护的 `[[Builders]]` 配置。设计背景见 [good-will-alliance#15](https://github.com/bnb-chain/good-will-alliance/issues/15)。

本 README 同时是一份面向没有合约开发经验的读者的流程说明：每个环节先讲「为什么」，再给命令。

---

## 1. 合约做什么

| 能力 | 接口 |
|---|---|
| 读取全部 key（sentry 每轮全量读） | `getBuilders()` |
| 分页读取（名单很大时备用；翻页须固定同一块高） | `getBuildersRange(offset, limit)` |
| 单个查询 | `isBuilder(addr)`、`getBuilder(addr)`、`builderCount()` |
| 新增（地址已存在则 revert） | `addBuilder(addr, url, name)`、`addBuilders(Builder[])` |
| 修改已有记录的 `url` / `name`（地址不存在则 revert） | `updateBuilder(addr, url, name)` |
| 原子轮换：同一交易内删旧 key、加新 key，沿用原 `name`，满额时也可用 | `replaceBuilder(oldAddr, newAddr, url)` |
| 删 | `removeBuilder(addr)` |
| 每个 builder 的 key 上限 | `defaultMaxKeys()`、`maxKeys(name)`、`keyCount(name)`、`setDefaultMaxKeys(n)`、`setMaxKeys(name, n)` |
| admin 转移（两步：提议 + 接受） | `transferOwnership(addr)` → 新 owner 调 `acceptOwnership()` |
| 升级实现合约 | `upgradeToAndCall(newImpl, "")` |

字段长度：`url` ≤ 256 字节，`name` ≤ 64 字节（`MAX_URL_LENGTH` / `MAX_NAME_LENGTH`），超出 `FieldTooLong` revert。
这把 `getBuilders()` 的返回体积限制在 `builderCount × 约 400 字节` 以内。

数据结构：

```solidity
struct Builder {
    address addr;   // bid 签名 key，allowlist 的主键
    string  url;    // builder 端点，validator / sentry 用它发 mev_reportIssue
    string  name;   // 运营主体，如 "blockrazor"，同名 key 一起计入上限
}
```

上限规则：`addBuilder` 新增 key 时若该 `name` 的数量已达上限则 revert；删除永不受限；
调低上限不会删掉已有 key，只阻止继续新增。上限按 admin 填写的 `name` 计数，合约无法验证 key 的真实归属，
所以它防的是误操作并提供链上可验证性，不是对 admin 的约束。

`name` 格式：只允许小写字母、数字、`-`、`_`，其他字符（含大写）一律 `InvalidName` revert。
原因是计数按 `keccak256(name)` 进行，若允许大写，`BlockRazor` 和 `blockrazor` 会被算成两个 builder，上限就能被无意绕过。

`renounceOwnership()` 已禁用（调用即 `RenounceDisabled` revert）。放弃 owner 会让合约永久失去 admin 和升级能力，
换 admin 只能走两步转移。

`Builder` 结构体布局是**冻结**的：它是存储数组的元素类型，增删字段会改变每个元素占用的 slot 数，
升级后旧数据会被读错位，同时也会改变 `getBuilders()` 的 ABI 编码。以后要给 key 附加信息，
在现有状态变量之后追加一个 `mapping(address => ...)`，不要动结构体。

---

## 2. 目录结构

```
contracts/builder-key-registry/
├── foundry.toml            # 编译器版本、依赖路径映射、RPC 别名
├── src/BuilderKeyRegistry.sol
├── test/BuilderKeyRegistry.t.sol
├── script/
│   ├── Deploy.s.sol        # 部署实现 + 代理 + 初始化 + 批量灌入
│   ├── Upgrade.s.sol       # 升级实现合约
│   ├── gen-builders.py     # 把 mev-info/*/builder-list.toml 转成部署脚本读的 JSON
│   └── input/bsc-mainnet/builders.json
└── lib/                    # 依赖（git submodule）：forge-std、OpenZeppelin
```

---

## 3. 开发环境

用的是 [Foundry](https://book.getfoundry.sh/)：`forge`（编译/测试/部署脚本）、`cast`（命令行调合约）、`anvil`（本地链）。
安装：

```bash
curl -L https://foundry.paradigm.xyz | bash && foundryup
```

克隆仓库后拉依赖（依赖是 submodule，不是 npm 包）：

```bash
git submodule update --init --recursive
```

---

## 4. 日常循环：编译 → 测试

```bash
cd contracts/builder-key-registry
forge build          # 编译 src/ test/ script/
forge test           # 跑 test/ 下所有测试
forge test -vvv      # 失败时看调用栈
forge fmt            # 格式化
```

**测试是 Solidity 写的**（`test/BuilderKeyRegistry.t.sol`），每个 `test_*` 函数是一个用例，`testFuzz_*` 会被随机输入跑几百次。
几个常用的作弊码（cheatcode）：

- `vm.prank(addr)`：下一次调用以 `addr` 身份发出，用来测 `onlyOwner`。
- `vm.expectRevert(...)`：断言下一次调用会以指定错误 revert。
- `vm.expectEmit(...)` + `emit X(...)`：断言下一次调用会发出该事件。
- `makeAddr("label")`：生成一个确定性的测试地址。

---

## 5. 理解代理（proxy）与升级

部署时链上有**两个**合约：

```
调用方 ──► Proxy（地址固定，保存所有状态） ──delegatecall──► Implementation（只有代码）
```

- 用户和 sentry 永远只配置 **Proxy 地址**。
- 升级 = 部署新的 Implementation，然后让 Proxy 指向它。状态留在 Proxy 里不动。
- 本项目用 UUPS 模式：升级函数 `upgradeToAndCall` 在 Implementation 里，受 `onlyOwner` 保护。

由此带来两条规矩：

1. **不用 constructor 初始化，用 `initialize()`。** constructor 只在 Implementation 自己的部署里跑一次，Proxy 看不到。
   `initialize()` 通过 Proxy 调一次，`initializer` 修饰符保证不能调第二次。实现合约的 constructor 里调了
   `_disableInitializers()`，防止有人直接初始化实现合约。
2. **升级时只能在状态变量末尾追加，不能重排、删除、改类型。** 否则新代码会把旧数据读错位。

测试里 `test_upgrade_preservesStateAndAddsLogic` 演示了完整的升级流程。

---

## 6. 本地链上试一遍

开一个本地链（另开终端，保持运行）：

```bash
anvil
```

anvil 会打印 10 个预置账户和私钥。用第一个部署（这是公开的测试私钥，只能用于本地）：

```bash
OWNER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 \
DEFAULT_MAX_KEYS=7 \
BUILDERS_JSON=script/input/bsc-mainnet/builders.json \
forge script script/Deploy.s.sol \
  --rpc-url http://127.0.0.1:8545 \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
  --broadcast
```

输出里 `proxy (use this address)` 就是 registry 地址。用 `cast` 读一读：

```bash
PROXY=<上面打印的 proxy 地址>
cast call $PROXY "builderCount()(uint256)" --rpc-url http://127.0.0.1:8545
cast call $PROXY "keyCount(string)(uint256)" blockrazor --rpc-url http://127.0.0.1:8545
cast call $PROXY "getBuilders()((address,string,string)[])" --rpc-url http://127.0.0.1:8545
```

写一笔（以 owner 身份加一把 key）：

```bash
cast send $PROXY "addBuilder(address,string,string)" \
  0x1111111111111111111111111111111111111111 https://example.builder test \
  --rpc-url http://127.0.0.1:8545 \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
```

---

## 7. 部署到 BSC 测试网（Chapel）

### 7.1 准备账户

不要把私钥写进 `.env` 或命令行历史。把部署账户导入 Foundry 的加密 keystore：

```bash
cast wallet import deployer --interactive     # 粘贴私钥，设置一个口令
cast wallet address --account deployer        # 确认地址，给它充一点测试 BNB
```

### 7.2 配置环境变量

```bash
cp .env.example .env
# 编辑 .env：填 OWNER（最终持有 admin 的多签地址）、RPC、BSCSCAN_API_KEY
source .env
```

### 7.3 生成初始名单

```bash
python3 script/gen-builders.py ../../mev-info/bsc-mainnet/builder-list.toml \
  > script/input/bsc-mainnet/builders.json
```

脚本会在 stderr 打印每个 builder 的 key 数。**`DEFAULT_MAX_KEYS` 必须不小于其中的最大值**，否则批量灌入会 revert；
部署脚本在模拟阶段就会检查并报错。当前名单最大是 7，所以初始部署用 7，缩减完成后再 `setDefaultMaxKeys(4)`。

### 7.4 先模拟，再广播

`forge script` 不带 `--broadcast` 只做本地模拟，不花 gas，用它检查一切正常：

```bash
forge script script/Deploy.s.sol --rpc-url bsc_testnet --account deployer
```

确认无误后加 `--broadcast`，可选 `--verify` 顺带在 BscScan 上验证源码：

```bash
forge script script/Deploy.s.sol --rpc-url bsc_testnet --account deployer --broadcast --verify
```

部署脚本的行为：

1. 部署 Implementation。
2. 部署 Proxy 并调 `initialize(deployer, DEFAULT_MAX_KEYS)`，**deployer 先做 owner**。
3. 如果给了 `BUILDERS_JSON`，调 `addBuilders` 一次性灌入。
4. 如果 `OWNER != deployer`，调 `transferOwnership(OWNER)`。**OWNER 必须自己调一次 `acceptOwnership()` 才真正接管。**

交易记录在 `broadcast/Deploy.s.sol/97/run-latest.json`，里面有所有地址和 tx hash，应当提交进仓库作为部署记录。

### 7.5 部署后公布

- Proxy 地址（每个网络一个）和 chainId
- ABI：`forge inspect BuilderKeyRegistry abi > abi/BuilderKeyRegistry.json`
- 初始名单和 admin 地址、类型（多签成员、阈值）
- 变更流程：见第 9 节

---

## 8. 升级

改完 `src/BuilderKeyRegistry.sol`（遵守第 5 节的存储规矩）并通过测试后：

```bash
PROXY=<proxy 地址> forge script script/Upgrade.s.sol --rpc-url bsc_testnet --account deployer --broadcast
```

广播账户必须是当前 owner。如果 owner 是多签，改为用 `Upgrade.s.sol` 只部署新 Implementation，
再在多签里发起 `upgradeToAndCall(newImpl, 0x)`。

---

## 9. 日常运维（admin 操作）

以下用 `cast send`，owner 是多签时换成在多签界面发起同样的调用。

| 操作 | 命令 |
|---|---|
| 新增 key | `cast send $PROXY "addBuilder(address,string,string)" <addr> <url> <name> ...` |
| 更新已有 key 的 URL 或 name | `cast send $PROXY "updateBuilder(address,string,string)" <addr> <url> <name> ...` |
| 轮换 key（一笔交易，删旧加新） | `cast send $PROXY "replaceBuilder(address,address,string)" <old> <new> <url> ...` |
| 删除 key | `cast send $PROXY "removeBuilder(address)" <addr> ...` |
| 调整某 builder 上限 | `cast send $PROXY "setMaxKeys(string,uint256)" flashblock 2 ...` |
| 调整默认上限 | `cast send $PROXY "setDefaultMaxKeys(uint256)" 4 ...` |
| 转移 admin | `cast send $PROXY "transferOwnership(address)" <new> ...`，然后新 owner 执行 `acceptOwnership()` |

操作顺序规则（来自 validator 节点侧仍有一份静态名单这一事实）：

- **新增**：先通知 validator 把 key 加进节点配置，确认后再上链。
- **删除**：先上链，validator 节点侧随时清理。
- **轮换**：需要新旧 key 重叠期时按「新增 → 删除」两步执行（满额时先临时调高上限）；
  不需要重叠期时用 `replaceBuilder` 一笔完成，链上不会出现「旧 key 已删、新 key 未加」的中间状态。
  两种方式都要先让 validator 节点配置里有新 key。

---

## 10. 常见问题

- **`vm.parseJson` 解析失败 / 字段错位**：JSON 对象的 key 必须按字母序（`addr, name, url`），并与脚本里 `Entry` 结构体字段顺序一致。`gen-builders.py` 已保证这一点。
- **`KeyCapReached`**：该 `name` 已达上限。看 `keyCount(name)` 和 `maxKeys(name)`。
- **`BuilderExists`**：`addBuilder` / `addBuilders` 遇到已注册地址。想改记录用 `updateBuilder`；想换 key 用 `replaceBuilder`。批量灌入时出现这个错误通常是 JSON 里有重复地址。
- **`FieldTooLong`**：`url` 超 256 字节或 `name` 超 64 字节。
- **`OwnableUnauthorizedAccount`**：调用账户不是 owner。如果刚转移过 admin，确认新 owner 已经 `acceptOwnership()`。
- **`InvalidInitialization`**：试图对已初始化的 proxy 或对 implementation 本体调 `initialize`。
