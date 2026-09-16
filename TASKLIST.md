# TASKLIST — DNS 优化项目（mosdns 竞速分流 + 内容流水线 + 引流私信）

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
- [x] T1 DNS 竞速方案源码审计，定位"丝滑"来源（mosdns 双 sequence + resp_ip 防污染）
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
- [x] T11 kit README.md（架构图 + 实测数据 + 方案对比表）
- [x] T12 kit install.sh（arch 自适应 + 订阅域名自动探测防死锁 + 幂等 + 备份）
      ⚠️ 探测逻辑修正：只抓订阅 address 的 host（防死锁刚需），代理节点 server 交 mosdns 境外序列
- [x] T12b kit uninstall.sh（停服务 + 还原钩子/UCI + 删文件 + 重启）
- [x] T13 kit push + 验证可 clone（/tmp/kit-verify 实测通过）
      仓库：https://github.com/herman6888/openclash-mosdns-kit
      文件：install.sh / uninstall.sh / README.md / TASKLIST.md

### ✅ 已完成（续）
- [x] T10 writer 流水线出稿 + 阿编五问审查 + 3 条必改全修
      审查结论：撞题不撞点（mosdns 生态都是组合方案角度，本文"零代理单程序"差异化）
      修复：①wechat"不需要任何插件"→"除 mosdns 外无其他插件"（消矛盾）
            ②wechat 补双层缓存段，正文 1583 字过 1500 下限
            ③xhs"十几分钟"→"10 分钟左右"对齐简报
            ④口径统一 10 站点→7 站点（与实测表严格一致，三文件同步）
      ⚠️ 发布前必删两稿尾部【平台自检】【需补查】区块（含禁词字面"代理"）
- [x] T14 私信研究 → Herman 拍板 A+B 合规方案
- [x] T15 引流机制落地（A+B）：
      脚本 ~/.hermes/scripts/xhs-want-watch/detect_wants.py
      链路：search 自己笔记标题→新鲜 xsec_token 签名 URL→comments→匹配"想要"词→飞书提醒人工
      cron b3cba8048cbc 每 30m，--no-agent 模式，无新评论静默，有则投飞书 DM
      合规：不自动私信、不发外链，只提醒 Herman 人工私信引导进官方粉丝群
      配置 ~/.hermes/scripts/xhs-want-watch/config.json（author/note_keywords/send_target）
      发布 DNS 笔记后：把笔记标题加进 config.json 的 note_keywords 即纳入监控

## 发布前检查清单（Herman 手动发布时）
1. 删 xhs-dns.md / wechat-dns.md 尾部【平台自检】【需补查】区块
2. 小红书正文零外链，引流话术指向公众号
3. 公众号文末放 kit repo 链接（公众号可放外链）
4. 开小红书官方粉丝群，群内发 repo
5. 发布后把笔记标题加进 detect_wants.py 的 config.json note_keywords
6. 收到飞书"想要"提醒后，人工私信引导进粉丝群（勿发外链）

---

## 私信研究（T14 已完成研究，待 Herman 拍板）
### 技术可行性（实测 opencli + 平台规则查证）
- opencli xiaohongshu 命令全集：ask/comments/creator-*/download/draft-*/feed/follow/liked/login/note/notifications/publish/saved/search/unfollow/user/whoami
  → **无 DM/私信/回复评论/发消息命令**。检测"想要"可行（comments/notifications 读），发送侧 opencli 不支持
- hermes send 仅 telegram/discord/slack/signal，**不支持小红书**
- 要发私信/回评只能走浏览器自动化（opencli browser eval / browser_exec 操作 creator 后台或 xiaohongshu.com/im），脆弱且易触发风控
### 平台规则（web 查证，2026 现行）
- 2026-01-07 起专业号私信自动回复组件**禁止留微信/电话**，只能用"社媒名片"导流
- 自动私信/频繁留联系方式 = 禁言/限流/封号高风险；GitHub 外链本身也算"导流第三方"
- 第三方工具（油猴 XHS-YYDS、影刀 RPA、语聚AI）均存在但都带封号风险，非官方接口
### 给 Herman 的选项（风险递增）
- A 合规·转化弱：不做自动私信。文末引导"关注+点赞+收藏"，repo 链接放公众号（公众号可放外链），小红书只引流到公众号
- B 合规·中转化：开小红书官方"粉丝群/群聊"，AI 在群内发 repo（站内功能，相对安全）
- C 中风险：浏览器自动化检测"想要"→评论区回复（不含外链，引导看主页/公众号），不碰私信
- D 高风险·不建议：自动私信发 GitHub 链接 = 踩 2026 导流红线，封号风险高
### 我的建议
A + B 组合：小红书正文零外链引流到公众号，公众号文末放 kit repo；想要即时获取的引导进官方粉丝群。cron 只做"检测想要评论→提醒我人工回"，不自动发。

---

## 下一步立即要做
1. 填 kit 仓库 README + install.sh + uninstall.sh（T11/T12）
2. push 验证（T13）
3. 轮询群聊看 writer 出稿（T10）
4. 整理私信决策点（T14）
