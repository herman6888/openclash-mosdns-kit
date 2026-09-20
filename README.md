# openclash-mosdns-kit

给路由器加一层 [mosdns](https://github.com/IrineSistiana/mosdns)：国内域名**并发竞速** + **污染自动识别丢弃** + **本地缓存**，把网页 DNS 解析从"单线路傻等超时"变成"多路并发取最快"。

> 🔍 **自动检测 OpenClash，有无均可用**：脚本开机先探测 OpenClash 是否已安装且启用，自动选接管路径——装了就走 OpenClash DNS 接管，没装就直接接管 dnsmasq。同一份脚本，两种路由器都能用。

> ⚠️ 本工具**只优化 DNS 解析路径**，不改变任何代理出口规则。它解决的是"解析慢、解析被带偏"，不会改变你的网络出口。

> 🔄 **规则表自动更新**：CN 网段/域名分流表由 GitHub Actions 每日自动同步至最新（不依赖任何个人机器在线），安装后路由器每日凌晨自动拉取并热重启 mosdns，无需手动维护。下载失败或表异常时自动保留旧表，绝不下发坏数据。

## 它解决什么问题

| 痛点 | 本 kit 的解法 |
|---|---|
| 运营商 DNS 慢，网页"转圈" | 阿里 + 腾讯 DNS 并发竞速，谁快用谁 |
| DNS 污染（国内域名解析出境外假 IP） | `resp_ip` 比对 CN 网段表，假答案直接丢弃改走加密通道重查 |
| 单线路串行等待超时 | `always_standby` 双发并发，100ms 封顶 |
| 重复解析浪费 | 本地缓存 5 万条，二次打开 DNS 耗时归零 |

## 架构

```
LAN 设备
  │  DNS 查询
  ▼
dnsmasq:53  ──(转发)──►  mosdns:5350
                            │
              ┌─────────────┴─────────────┐
              │  查 Domains.chn.txt 分流   │
              ▼                           ▼
        国内域名                       境外域名
              │                           │
     竞速：阿里/腾讯 DNS            加密备份上游
              │                     (阿里 DoH / DNSPod DoH)
              ▼                           │
     resp_ip 比对 IPchnroute              │
     答案在中国网段？                     │
       ├─ 是 → 采纳                       │
       └─ 否 → 判污染，丢弃 ─────────────┘
              │                           │
              └──────────► 真实 IP 返回 ◄──┘
```

OpenClash 侧通过 `openclash_custom_overwrite.sh` 钩子把 `dns.nameserver` 指向 mosdns，并删掉 clash 自带 fallback（避免与 mosdns 防污染逻辑冲突）。订阅地址 host 自动探测进 `nameserver-policy` 直连解析，防止"拉订阅本身要走代理"的死锁。

## 两种接管模式（自动选择）

脚本启动时探测三件事：`/etc/openclash` 目录、`/etc/init.d/openclash`、`uci get openclash.config.enable`，据此决定接管路径：

| 检测结果 | 接管模式 | 接管方式 |
|---|---|---|
| OpenClash 已装**且启用** | `openclash` | 写 OpenClash 钩子把 DNS 指向 mosdns + **保持 fake-ip** + 订阅域名直连策略 |
| OpenClash 装了但**未启用** | `dnsmasq` | dnsmasq 上游直连 mosdns；同时预写 OpenClash 钩子，日后启用自动接上 |
| **没装** OpenClash | `dnsmasq` | dnsmasq 上游直连 mosdns，缓存交给 mosdns，关 wan6 peerdns |

> **为什么必须分模式**：OpenClash 启用时自带 watchdog，会持续把 dnsmasq 上游改回 clash 的 DNS 端口。若无视检测强行接管 dnsmasq，配置会被反复覆盖、DNS 直接 REFUSED。所以"装了 OpenClash 就必须从 OpenClash 侧接管，没装才接管 dnsmasq"。

接管模式会记录在 `/etc/mosdns/.kit-mode`，卸载脚本据此判断该还原哪一侧。

## 一键安装

```sh
# 在路由器 SSH 里
wget https://github.com/herman6888/openclash-mosdns-kit/raw/main/install.sh -O /tmp/install.sh
sh /tmp/install.sh
```

脚本会：检测 OpenClash → 选接管模式 → 检测架构 → 下载 mosdns → 下载分流规则表 → 生成配置 → 注册 procd 服务 → 执行接管 → 部署每日同步 → 重启验证。**改前自动备份**到 `/root/openclash-mosdns-kit-backup-<时间戳>`。

国内访问 GitHub 受阻时，编辑脚本顶部 `GH_PROXY="https://gh-proxy.com"` 再加速。

### 可选：强制劫持局域网 DNS（无 OpenClash 模式）

有些设备在网卡上写死了第三方 DNS，普通接管管不到。加环境变量重装即可强制拽回：

```sh
HIJACK_LAN_DNS=1 LAN_IF=br-lan sh /tmp/install.sh
```

会追加 nftables 规则把局域网 53 端口流量重定向到 mosdns，并持久化到 `/etc/nftables.d/mosdnshijack.nft`。

## 卸载

```sh
sh uninstall.sh
```

自动识别安装模式：停 mosdns、删劫持规则（若有）、从备份还原 dnsmasq/dhcp 与 OpenClash 钩子、删 mosdns 文件、重启相关服务。

## 前置要求

- OpenWrt / iStoreOS（**OpenClash 可有可无**，脚本自动适配）
- root 权限
- `curl` 或 `wget`，`unzip`（缺则 `opkg update && opkg install unzip`）
- 建议 128MB+ 内存（mosdns 常驻约 50MB）
- 劫持模式额外需要 `nftables`（`opkg install nftables`）

## 实测数据

2026-09-16 在 iStoreOS 24.10.8 / aarch64 部署验证：

| 域名 | 解析结果 | 耗时 |
|---|---|---|
| www.baidu.com | 真实 IP | 76ms 首查 / 16ms 缓存 |
| www.qq.com | 真实 IP | 15ms |
| www.bilibili.com | 真实 IP（4 条） | 16ms |
| www.github.com | 真实 IP | 9ms |

内存占用约 50MB，无 swap 的 4GB 路由器无压力。

## 配置项

脚本顶部可调：

| 变量 | 默认 | 说明 |
|---|---|---|
| `CHN_UP1/2` | 阿里 / 腾讯 DNS | 国内竞速上游 |
| `BAK_UP1/2` | 按模式自动 | 兜底上游：OpenClash 模式用国内 DNS 快速应答（国外走 fake-ip+代理），dnsmasq 模式用境外 DoH（无代理时的唯一出路） |
| `RACE_THRESHOLD` | 100 | 竞速阈值(ms) |
| `GH_PROXY` | 空 | GitHub 加速前缀 |
| `HIJACK_LAN_DNS` | 0 | 无 OpenClash 模式下是否劫持局域网 53 端口（1=开启） |
| `LAN_IF` | br-lan | 劫持生效的局域网接口 |

## 已知边界

1. 只优化 DNS，不改变代理出口。
2. 污染判定依赖 `IPchnroute` 准确性，个别 CDN IP 变更会误判（表现为该域名重查慢 100ms，仍能拿到答案），定期更新规则表即可。
3. OpenClash 模式保持 fake-ip：个别强依赖真实 IP 的 APP 需加入 OpenClash 的 fake-ip-filter 白名单（脚本已把订阅域名等自动放行）。
4. 兜底上游按模式自动选择：OpenClash 模式为国内 DNS（纯国内环境即可连通），dnsmasq 模式为境外加密 DNS（需网络可达）。

## License

MIT
