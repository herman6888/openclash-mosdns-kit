# TASKLIST — DNS 优化项目（de_GWD 移植 + 内容流水线 + 引流私信）

> 跨上下文压缩的权威进度表。每完成一步立即更新本文件。
> 最后更新：2026-09-16 13:55 HKT

## 关键坐标（别丢）
- 路由器：iStoreOS 24.10.8 @ 192.168.8.1（root 免密 SSH 可达）
- 线上 mosdns 配置：`/etc/mosdns/config-final.yaml`（监听 127.0.0.1:5350）
- 线上 OpenClash 钩子：`/etc/openclash/custom/openclash_custom_overwrite.sh`
- 回滚备份：`/root/dns-backup-20260916-110644`
- 群聊房间：「DNS优化内容流水线」id=`mu3o96vd0z2zml` inviteCode=`DNSOPT2026X7K2`
- 群成员 agent：烧卖-PM(pm) / 阿研(researcher) / 阿写(writer) / 阿编(editor)
- 群聊客户端：`/home/herman/Projects/content-dns/gc.js`
  用法：`node gc.js send DNSOPT2026X7K2 mu3o96vd0z2zml "烧卖-调度3" "<text>" --wait N`
  ⚠️ 成员名冲突：复用固定名"烧卖-调度3"+持久 uid（.gc_uid），勿换新名
- 文章主素材：`/home/herman/Projects/content-dns/brief-dns-optimization.md`
- 工单：`/home/herman/Projects/content-dns/workorder-01.md`
- GitHub 仓库：https://github.com/herman6888/openclash-mosdns-kit（已建，待填内容）
- gbrain 日志：`agent/journal/2026-09-16.md`（已 commit aa7463b + sync + embed）
- gbrain 攻略存档：`drafts/2026-09-16-openwrt-dns-guide-standalone.md`（commit f3d76ee）

---

## 任务清单

### ✅ 已完成
- [x] T1 de_GWD 源码审计，定位"丝滑"来源（mosdns 双 sequence + resp_ip 防污染）
- [x] T2 路由器线上部署 P1+P2（redir-host + mosdns 竞速），实测验证通过
- [x] T3 回答 Pi-hole：不需要（订阅 7276 条拦截规则已覆盖广告屏蔽）
- [x] T4 写 gbrain 日志（含 4 条选题候选）
- [x] T5 写纯 DNS 零代理攻略（standalone，已实测 5352 隔离端口验证）
- [x] T6 建群聊「DNS优化内容流水线」+ 四角色 agent
- [x] T7 打通群聊程序化通道（gc.js，inviteCode 握手→join→@mention 唤醒 agent）
- [x] T8 派发工单 01 给烧卖-PM（双平台改写，红线零代理词汇）
- [x] T9 建 GitHub 仓库 openclash-mosdns-kit

### 🔄 进行中
- [ ] T10 writer 流水线出稿（PM 已接单，待派阿写→阿编审查→回报）
      检查方式：`cd /home/herman/Projects/content-dns && node gc.js watch DNSOPT2026X7K2 mu3o96vd0z2zml "烧卖-调度3" --wait 90`
      或读工作区文件：xhs-dns.md / wechat-dns.md
      状态：14:00 仍未出稿，PM 接单后未派阿写，需催

### ✅ 已完成（续）
- [x] T11 kit README.md（架构图 + 实测数据 + de_GWD 对比表）
- [x] T12 kit install.sh（arch 自适应 + 订阅域名自动探测防死锁 + 幂等 + 备份）
      ⚠️ 探测逻辑修正：只抓订阅 address 的 host（防死锁刚需），代理节点 server 交 mosdns 境外序列
- [x] T12b kit uninstall.sh（停服务 + 还原钩子/UCI + 删文件 + 重启）
- [x] T13 kit push + 验证可 clone（/tmp/kit-verify 实测通过）
      仓库：https://github.com/herman6888/openclash-mosdns-kit
      文件：install.sh / uninstall.sh / README.md / TASKLIST.md

### ⬜ 待办
- [ ] T14 私信自动回复方案研究结论 + 给 Herman 决策建议（见下方"私信研究"）
- [ ] T15 文章里"回复想要→私信"引导语的落地方式（取决于 T14 结论）

---

## 私信研究（T14 进行中，已查明的事实）
- opencli xiaohongshu **无 DM/私信命令**（只有 notifications/comments/creator-* 读命令）
- `hermes send` 仅支持 telegram/discord/slack/signal，**不支持小红书**
- 小红书平台规则（web 查证）：
  * 2026-01-07 起专业号私信自动回复组件**禁止留微信/电话**，只能用"社媒名片"导流
  * 自动私信/频繁留联系方式 = 禁言/限流/封号高风险
  * "回复想要→私信发链接"若私信内容含外部链接/联系方式，踩红线
- 待给 Herman 的选项：
  A. 不做自动私信，改用"评论区置顶 + 个人主页/群聊引导"（合规，但转化弱）
  B. 私信只发"已关注请查收站内信/加群"不含外链联系方式，人工兜底（中风险）
  C. 用小红书官方"群聊/粉丝群"功能承接，AI 在群内发 repo 链接（相对合规）
  D. 坚持自动私信发 GitHub 链接 = 高封号风险，不建议
- 结论待整理成决策点交 Herman 拍板（发布/私信属人工批准范围）

---

## 下一步立即要做
1. 填 kit 仓库 README + install.sh + uninstall.sh（T11/T12）
2. push 验证（T13）
3. 轮询群聊看 writer 出稿（T10）
4. 整理私信决策点（T14）
