# openclash-mosdns-kit

给 **OpenClash** 加一层 [mosdns](https://github.com/IrineSistiana/mosdns)：国内域名**并发竞速** + **污染自动识别丢弃** + **本地缓存**，把网页 DNS 解析从"单线路傻等超时"变成"多路并发取最快"。

灵感来自已停更的 [jacyl4/de_GWD](https://github.com/jacyl4/de_GWD)（2019–2025，478★）。本 kit 把它的 DNS 分流核心（`resp_ip` 网段比对防污染 + 竞速）单独抽出来，做成 OpenClash 一键安装，去掉了原项目的其他组件依赖。

> ⚠️ 本工具**只优化 DNS 解析路径**，不改变任何代理出口规则。装它不会让你"翻"得更快，它解决的是"解析慢、解析被带偏"。

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

## 一键安装

```sh
# 在路由器 SSH 里
wget https://github.com/herman6888/openclash-mosdns-kit/raw/main/install.sh -O /tmp/install.sh
sh /tmp/install.sh
```

脚本会：检测架构 → 下载 mosdns → 下载分流规则表 → 生成配置 → 注册 procd 服务 → 自动探测订阅域名 → 写 OpenClash 接管钩子 → 切 redir-host → 重启验证。**改前自动备份**到 `/root/openclash-mosdns-kit-backup-<时间戳>`。

国内访问 GitHub 受阻时，编辑脚本顶部 `GH_PROXY="https://gh-proxy.com"` 再加速。

## 卸载

```sh
sh uninstall.sh
```

停 mosdns、还原 OpenClash 钩子与 redir-host 设置、删 mosdns 文件、重启 OpenClash。

## 前置要求

- OpenWrt / iStoreOS，已安装 **OpenClash**
- root 权限
- `curl` 或 `wget`，`unzip`（缺则 `opkg update && opkg install unzip`）
- 建议 128MB+ 内存（mosdns 常驻约 50MB）

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
| `BAK_UP1/2` | 阿里 DoH / DNSPod DoH | 加密备份上游（国内可达，不依赖代理） |
| `RACE_THRESHOLD` | 100 | 竞速阈值(ms) |
| `GH_PROXY` | 空 | GitHub 加速前缀 |

## 已知边界

1. 只优化 DNS，不改变代理出口。
2. 污染判定依赖 `IPchnroute` 准确性，个别 CDN IP 变更会误判（表现为该域名重查慢 100ms，仍能拿到答案），定期更新规则表即可。
3. redir-host 模式下个别强依赖 fake-ip 的 APP 可能需要额外白名单。
4. 加密备份上游是国内服务器，纯国内环境即可连通。

## 与 de_GWD 的关系

| | de_GWD | 本 kit |
|---|---|---|
| 状态 | 已停更 | 维护中 |
| 形态 | Debian 网关全家桶 | OpenClash 单加层 |
| DNS 核心 | mosdns 双 sequence | 同款竞速 + resp_ip 防污染 |
| 广告屏蔽 | Pi-hole | 交给 OpenClash 订阅拦截规则 |
| 安装 | 交互式脚本 | 一键 + 卸载脚本 |

## License

MIT
