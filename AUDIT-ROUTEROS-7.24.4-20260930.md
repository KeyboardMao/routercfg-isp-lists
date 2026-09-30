# RouterOS 7.24.4 未知目标移动优先变更审计

审计日期：2026-09-30

目标版本：RouterOS `7.24.4 (stable)`
审计对象：

- `routeros/set-unknown-default-mobile.rsc`
- `routeros/restore-unknown-default-previous.rsc`
- Address List 自动更新器与既有双 WAN 策略的交互

## 1. 结论

在目标设备确实运行 `7.24.4 (stable)`、现网仍符合已知 phase-6、ISP affinity 和 Address List 自动更新布局的前提下，本次命令可用。切换脚本只修改一个普通未知目标兜底规则和五个普通 PCC 桶的启停状态，不新增、删除或移动 Mangle 规则。

脚本在第一个修改命令前完成全部前置检查。任何身份、数量、属性、顺序或依赖漂移都会写入错误日志并停止。最终仍必须在目标 RouterOS 上执行 `verbose=yes dry-run`；本地静态检查无法证明设备在最后一次导出之后没有被人工或其他脚本修改。

本轮审计实际发现并修复了变量兼容性问题：回滚脚本的 `mode`、更新器的 `version`、卸载脚本的 `script`，以及策略顺序检查中的 `position`、循环索引 `n` 都可能与 RouterOS 内置属性名冲突。它们已改为项目专用变量名；静态验证器现在扫描所有受管 `.rsc` 的局部变量和循环变量，防止这些名称再次出现。

## 2. RouterOS 版本与命令适用性

MikroTik 官方发布记录显示，审计日的当前稳定版是 `7.24.4`，当前长期维护版是 `7.23.7`。项目最低版本是 `7.24.4`，所以：

| 设备版本 | 结果 |
|---|---|
| `7.24.4 (stable)` | 支持，也是本次实际审计基线 |
| 后续 v7 `stable`，版本不低于 7.24.4 | 版本门允许；升级后仍须重新 dry-run 和业务验收 |
| v7 `long-term`，版本不低于 7.24.4 | 版本门允许；当前尚无符合条件的 long-term 版本 |
| 当前 `7.23.7 (long-term)` | 明确拒绝，低于最低版本 |
| `testing`、`development`、RC、beta | 明确拒绝 |
| v6、未来 v8、无法解析的版本字符串 | 明确拒绝 |

本次使用的命令和属性在 7.24.4 上均有官方接口依据：

- `/import file-name=... verbose=yes dry-run`：7.16 起提供；
- `/export file=...`：当前 Export 命令，未加 `show-sensitive` 时默认隐藏敏感信息；
- `:onerror ... in={...} do={...}`、`:log error`、`:error`：当前脚本错误处理；
- `/routing table`、`fib`、`/routing rule`、routing mark：RouterOS v7 策略路由；
- Mangle `mark-connection`、`mark-routing`、`connection-state`、`connection-mark`、`passthrough`；
- PCC 的 `both-addresses` 和 `both-addresses-and-ports`；
- `print count-only as-value where ...`、`get`、`find`。

版本检查按 major、minor、patch 数字段比较，不使用字符串大小比较。`7.24.10` 会被正确判断为高于 `7.24.4`。

## 3. 实际修改集合

应用脚本只允许出现下列写操作：

1. 把受管兜底规则的 `new-connection-mark` 改为 `conn_mobile`，并记录原状态；
2. 启用该兜底规则；
3. 禁用五个普通 PCC 桶。

回滚脚本只执行其逆操作，并按照注释中记录的 `rollback=Unicom` 或 `rollback=PCC` 恢复精确原模式。静态验证器会拒绝两个文件中出现 Mangle `add`、`remove`、Connection Tracking 清理或额外写操作。

## 4. Mangle 优先级与闭集检查

脚本检查以下顺序：

1. 联通、移动 PPPoE 入站连接标记；
2. 路由器本机目的和 `Lan_ip` RFC1918 绕过；
3. 两个 VPS 的连接标记和路由标记；
4. PT Tracker；
5. `192.168.99.4` 的五个 PT PCC 桶；
6. OpenWrt 两个 DNS 固定出口；
7. 联通独有、移动独有目的分类；
8. 普通未知目标兜底；
9. 五个普通 PCC 桶；
10. 通用 `conn_unicom`、`conn_mobile` 路由标记消费者。

相对顺序检查之外，脚本把整个 `prerouting` 策略面视为闭集：必须精确为 27 条规则，包括 21 个 `mark-connection` 分类器（19 个 LAN 分类器和 2 个 PPPoE 入站分类器）、4 个 `mark-routing` 规则和 2 个 `accept` 私网绕过，而且每条注释必须属于审核白名单。这样可以发现插入在两个已知锚点之间的未审核 `accept`、`drop` 或其他动作，也能发现没有 `in-interface=LAN01` 的历史残留规则。

## 5. 现有策略影响

| 对象 | 审计结果 |
|---|---|
| VPS A/B | 更早匹配；连接标记、路由标记与主表 `/32` 网关必须一致 |
| VPS QoS | 两个 `qos_priority_vps` 条目和 28 个 QoS 分类器必须存在 |
| PT | `192.168.99.4` 被普通 ISP/未知规则排除；五个专用桶保持 1/5 联通、4/5 移动 |
| Tracker | TCP 80/443、UDP 443 继续标记为联通 |
| OpenWrt DNS | `202.99.96.68` 联通、`211.137.160.5` 移动 |
| ISP 独有列表 | 两条分类规则保持启用；允许自动更新器在 A/B 列表名间切换 |
| 普通未知/重叠目的 | 新 IPv4 连接改为 `conn_mobile` |
| 已有连接 | 保留原 connection mark，不批量清理 |
| LAN、光猫、VPN 私网 | 路由器本机和三段 RFC1918 前置绕过 |
| 公网入站与端口映射 | PPPoE 入站连接标记保持回程对称；九条公共映射仍绑定联通 |
| Hairpin | 八条 `dst-address-type=local` 映射和一条 LAN source NAT 保留 |
| IKEv2 | 进入接口不是 `LAN01`；互联网 forward 许可必须存在 |
| RouterOS 本机流量 | 使用独立 output 回程规则；新建本机流量继续使用 main 表 |
| NAT | 每个 PPPoE 必须恰好有一条启用的通用 Masquerade |
| FastTrack | 必须没有启用的 FastTrack，避免绕过策略和队列 |
| IPv6 | 不经过本次 IPv4 Mangle 和 IPv4 Address List |

## 6. 策略表与故障切换

脚本要求：

- `to_unicom` 主路由：联通，distance 50；备用：移动，distance 150；
- `to_mobile` 主路由：移动，distance 51；备用：联通，distance 151；
- 两张表均为 FIB 表；
- 两条 routing rule 均使用 `action=lookup`，且没有 `min-prefix=0` 抑制默认路由；
- 两条实际 PPPoE 出口均有通用 Masquerade。

该设计能够在 PPPoE 接口或相应路由失效时使用备用线路。它没有递归探测或 `check-gateway`，因此 PPPoE 仍显示在线但运营商上游黑洞时，不会主动切换。

## 7. Address List 自动更新的交互

自动更新器只根据固定注释寻找联通独有和移动独有两条规则，并只改变两者的 `dst-address-list`。未知兜底规则使用独立注释，不会被自动更新器选中。

切换脚本不锁定当前 A/B 槽名，只要求两条 ISP 规则引用不同的非空列表，所以地址库每天切换槽位后仍可重复执行检查。

RouterOS 端通过 HTTPS 证书校验、固定文件名、精确字节数、目标槽条目数和版本标记确认下载结果。清单中的 SHA-512 由 GitHub 构建验证器和外部审计使用；当前更新器不会把约 180 KiB 的完整 Payload 读入 RouterOS 变量计算全文件 SHA-512。因此设备端信任边界仍是自己控制的 GitHub 仓库和经证书校验的 Pages 站点，不能把仓库写权限交给不受信任主体。

## 8. 错误、Safe Mode 与回滚

- 所有运行期错误由 `:onerror` 捕获；
- 系统日志写入 `routercfg unknown-default-Mobile ... FAILED:` 和原始原因；
- Address List 更新器也在最外层记录 `ISP list updater FAILED:` 和原始原因，然后保持失败退出；
- 错误随后通过 `:error` 重新抛出，不会被吞掉；
- Safe Mode 下失败后应按 `Ctrl+D` 或断开会话撤销；
- 不在 Safe Mode 中执行时，RouterOS 不提供脚本事务回滚，因此禁止跳过 Safe Mode；
- 回滚脚本记录并恢复切换前的联通兜底或普通 PCC 模式。

## 9. 上机前最终检查

```routeros
:put [/system resource get version]
/import file-name=set-unknown-default-mobile.rsc verbose=yes dry-run
/log print without-paging where message~"routercfg unknown-default-Mobile"
```

只有第一条显示 `7.24.4 (stable)` 且 dry-run 没有任何错误，才进入 Safe Mode 正式导入。

## 10. 审计限制

- 没有连接目标 RouterOS，因此没有读取本次操作时刻的实时 `/export`；
- 本地环境没有 MikroTik RouterOS/CHR 解释器，不能替代目标设备的 dry-run；
- 当前浏览器没有登录 GitHub，能核实公开的 Actions/Pages 成功状态，但不能读取仓库私有的 `PAGES_BASE_URL` 变量值；
- 严格前置检查可以发现已知布局漂移，但不能证明 ISP 外部链路质量；
- 默认内存日志会轮换，长期留存需要单独配置远程 Syslog。

## 11. 官方依据

- [MikroTik 7.24 版本发布记录](https://mikrotik.com/download/changelogs?channelFilter=&versionFilter=7.24)
- [RouterOS Configuration Management](https://manual.mikrotik.com/docs/getting-started/configuration-management/)
- [RouterOS Scripting](https://manual.mikrotik.com/docs/developer-guides/scripting/)
- [RouterOS Mangle CLI](https://manual.mikrotik.com/docs/cli-reference/ip/firewall/mangle/)
- [RouterOS Routing Decision](https://manual.mikrotik.com/docs/user-guides/routing-and-networking-protocols/routing-decision/)
- [RouterOS Routing Table CLI](https://manual.mikrotik.com/docs/cli-reference/routing/table/)
- [RouterOS PCC](https://manual.mikrotik.com/docs/high-availability-solutions/load-balancing/per-connection-classifier/)
- [RouterOS WAN Failover](https://manual.mikrotik.com/docs/high-availability-solutions/load-balancing/failover-wan-backup/)
- [RouterOS Fetch CLI](https://manual.mikrotik.com/docs/cli-reference/tool/fetch/)
