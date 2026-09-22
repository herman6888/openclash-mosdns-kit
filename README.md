# openclash-mosdns-kit

给路由器加一层 [mosdns](https://github.com/IrineSistiana/mosdns)：国内域名**并发竞速** + **按回程 IP 验真防污染** + **本地缓存**，把网页 DNS 解析从"单线路傻等超时"变成"多路并发取最快"。

> 🔍 **自动检测 OpenClash，有无均可用**：脚本开机先探测 OpenClash 是否已安装且启用，自动选接管路径——装了就走 OpenClash DNS 接管，没装就直接接管 dnsmasq。同一份脚本，两种路由器都能用。

> ⚠️ 本工具**只优化 DNS 解析路径**，不改变任何代理出口规则。它解决的是"解析慢、解析被带偏"，不会改变你的网络出口。

> 🔄 **规则表自动更新**：CN 网段分流表由 GitHub Actions 每日自动同步至最新（不依赖任何个人机器在线），安装后路由器每日凌晨自动拉取并热重启 mosdns，无需手动维护。下载失败或表异常时自动保留旧表，绝不下发坏数据。

## 它解决什么问题

| 痛点 | 本 kit 的解法 |
|---|---|
| 运营商 DNS 慢，网页"转圈" | 5 路公共 DNS 并发竞速，谁快用谁 |
| DNS 污染（国内域名解析出境外假 IP） | `resp_ip` 比对 CN 网段表，假答案直接丢弃改走加密通道重查 |
| 域名名单不全导致子域走错通道 | **不依赖域名表完整性**：以回程 IP 是否在中国网段为最终裁判 |
| 单线路串行等待超时 | `always_standby` 双发并发，100ms 封顶 |
| 重复解析浪费 | 本地缓存 5 万条，二次打开 DNS 耗时归零 |
| 全屋设备同时唤醒 DNS 被打爆 | dnsmasq 并发 10000 + UDP 缓冲 128KB + 进程优先级调优 |

## 架构（v4：按回程 IP 验真）

```
LAN 设备
  │  DNS 查询
  ▼
dnsmasq:53  ──(转发)──►  mosdns:5350
                            │
                     先试国内（无条件）
                            │
                  5 路公共 DNS 竞速
                            │
                  resp_ip 比对 IPchnroute
                  答案在中国网段？
                    ├─ 是 → 采纳（国内域名，含名单缺失的子域）
                    └─ 否 → 判被带偏/真境外 → 兜底序列
                              │
                 ┌────────────┴────────────┐
          无 VPS：加密 DNS           有 VPS：自建 DoT
        （dnsmasq 模式用境外 DoH；    （install-vps.sh，
         OpenClash 模式国内 DNS 秒回，  境外解析全程加密出户）
         国外由 fake-ip+代理处理）
```

**为什么"按回程 IP"而不是"按域名名单"**：域名名单永远不全（如某东只收录主域名，子域不在名单）。按名单分流的旧方案会把名单缺失的国内子域错送境外通道。v4 以 IP 为裁判：国内 DNS 给出中国 IP 就采信，给不出才走加密重查——名单只是辅助，IP 才是裁判。

## 两个安装脚本，按你的情况选

| 你的情况 | 用哪个 | 要求 |
|---|---|---|
| 纯 DNS 提速（最常见） | `install.sh` | OpenWrt/iStoreOS，OpenClash 可有可无，自动适配 |
| 有境外 VPS，想让境外解析也加密 | `install-vps.sh` + `scripts/vps-server.sh` | **必须已装并启用 OpenClash 且配好订阅**，不满足会提示后退出，不改任何配置 |

### 一键安装（无 VPS）

```sh
# 在路由器 SSH 里
wget https://github.com/herman6888/openclash-mosdns-kit/raw/main/install.sh -O /tmp/install.sh
sh /tmp/install.sh
```

脚本会：检测 OpenClash → 选接管模式 → 检测架构 → 下载 mosdns → 下载网段表 → 生成配置 → 注册服务 → 内核调优 → 执行接管 → 部署每日同步 → 重启验证。**改前自动备份**到 `/root/openclash-mosdns-kit-backup-<时间戳>`。

国内访问 GitHub 受阻时，编辑脚本顶部 `GH_PROXY="https://gh-proxy.com"` 再加速。

### 进阶：自建 VPS 加密 DNS

**第 1 步**，在境外 VPS（Ubuntu/Debian）上：

```sh
# 家里电脑访问 https://ip.sb 查你家出口 IP
HOME_IP=你家出口IP bash scripts/vps-server.sh
```

得到：DoT :853 + DoH :443（自签证书 10 年）、systemd 常驻、nftables 默认 drop 只放行你家 IP。这台机器**只做缓存+转发，不做国内判断**（防污染校验必须放路由器侧，放服务端会把大站正确回程 IP 误判丢弃——作者踩过，见下文）。

**第 2 步**，回路由器：

```sh
VPS_IP=你的VPS地址 sh install-vps.sh
```

脚本先做三重预检（OpenClash 已启用 / 订阅已配置 / DoT 可达），任何一项不过直接退出并给出修复指引，**不会改你任何配置**。全过才接管。

> 家宽 PPPPoE 重拨后出口 IP 会变。境外解析变慢/超时？先到 VPS 改 `/etc/nftables.conf` 里的 `home_allow` 再 `systemctl restart nftables`。

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

自动识别安装模式：停 mosdns、删劫持规则（若有）、剥掉 VPS bypass 段（若有）、从备份还原 dnsmasq/dhcp 与 OpenClash 钩子、删 mosdns 文件、重启相关服务。

## 前置要求

- OpenWrt / iStoreOS（**OpenClash 可有可无**，`install.sh` 自动适配；`install-vps.sh` 必须有）
- root 权限
- `curl` 或 `wget`，`unzip`（缺则 `opkg update && opkg install unzip`）
- 建议 128MB+ 内存（mosdns 常驻约 50MB）
- 劫持模式额外需要 `nftables`（`opkg install nftables`）

## 实测数据

2026-09 在 iStoreOS 24.10.8 / aarch64 部署验证（VPS 模式，三轮清缓存重启 + 50 并发压测）：

| 域名 | 解析结果 | 耗时 |
|---|---|---|
| www.baidu.com | 真实 CN IP | 0-10ms |
| www.jd.com（含子域） | 真实 CN IP | ~10ms |
| www.xiaohongshu.com | 真实 CN IP | 0-10ms |
| github.com | 真实 IP（VPS DoT） | 30-50ms |
| www.google.com | 真实 IP（VPS DoT） | 40-50ms |

50 并发真实 CN 域名 0 错误；20 并发 VPS 路径 0 错误。内存占用约 50MB。

## 配置项

脚本顶部可调：

| 变量 | 默认 | 说明 |
|---|---|---|
| `CHN_UP1~5` | 阿里/腾讯/114/CNNIC/阿里备用 | 国内竞速上游（5 路并发，实测全部可达） |
| `BAK_UP1/2` | 按模式自动 | 兜底上游：OpenClash 模式用国内 DNS 快速应答（国外走 fake-ip+代理），dnsmasq 模式用境外 DoH（无代理时的唯一出路），VPS 模式用自建 DoT |
| `RACE_THRESHOLD` | 100 | 竞速阈值(ms) |
| `VPS_IP` | 空 | 自建 DoT 服务器地址（install-vps.sh 注入） |
| `GH_PROXY` | 空 | GitHub 加速前缀 |
| `HIJACK_LAN_DNS` | 0 | 无 OpenClash 模式下是否劫持局域网 53 端口（1=开启） |
| `LAN_IF` | br-lan | 劫持生效的局域网接口 |

## 已知边界

1. 只优化 DNS，不改变代理出口。
2. 验真依赖 `IPchnroute` 准确性，个别 CDN IP 变更会误判（表现为该域名重查慢 100ms，仍能拿到答案），每日同步自动修正。
3. OpenClash 模式保持 fake-ip：个别强依赖真实 IP 的 APP 需加入 OpenClash 的 fake-ip-filter 白名单（脚本已把订阅域名等自动放行）。
4. **防污染校验只放在路由器侧。** 放 VPS 侧会把大站的正确回程 IP 误判成污染丢掉，国内流量反而被送进代理——这是本 kit 用一次线上事故换来的设计约束，`vps-server.sh` 里写死了"只缓存+转发"。
5. 境外 DoT 通道的可用性取决于你的 VPS 线路质量；线路抖动时境外解析会慢，国内路径不受影响。

## License

MIT
