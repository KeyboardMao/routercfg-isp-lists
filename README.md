# RouterOS 运营商 Address List 全自动更新部署指南

适用环境：

- RouterOS v7，版本不低于 `7.24.4`，版本标记为 `stable` 或 `long-term`；
- 已部署本目录上级工程中的“联通独有 / 移动独有”策略；普通未知目标可保持原来的联通/PCC 模式，也可按第 8.1 节切换为移动优先；
- 下列两条 Mangle 规则各存在且仅存在一条：
  - `routercfg ISP affinity: ordinary Unicom-only destination`
  - `routercfg ISP affinity: ordinary Mobile-only destination`
- 路由表 `to_unicom`、`to_mobile` 各存在一张；
- 当前静态列表为：
  - `routercfg-isp-unicom-only-20260917`，预期 1,520 项；
  - `routercfg-isp-mobile-only-20260917`，预期 948 项。

Address List 自动更新不会修改 NAT、Filter、队列、普通 PCC、VPS 配对、PT 专用规则或未知目标兜底。它只维护两组专用 A/B Address List，并只切换上述两条 Mangle 规则的 `dst-address-list`。第 8.1 节的未知目标切换是一次性、独立操作，之后每天更新地址库不会覆盖它。

## 1. 方案边界

### 1.1 自动完成的工作

1. GitHub Actions 每天读取上游联通、移动 IPv4 列表；
2. 校验每一行必须是严格、可路由的公网 IPv4 CIDR；
3. 归并重复和相邻范围；
4. 从联通和移动双方同时剔除全部重叠地址；
5. 校验生成结果完全互斥；
6. 对原始条目数、结果条目数和相邻版本变化幅度设置熔断条件；
7. 生成 RouterOS A/B 两个槽位的 `.rsc` 数据文件和小于 4 KiB 的清单；
8. 通过 GitHub Pages 发布；
9. RouterOS 每天只下载小清单；版本变化时才下载大数据文件；
10. 将数据导入非活动槽，校验通过后切换两条策略规则；
11. 下载、导入、数量、规则身份或切换失败时保留原活动槽；
12. 记录成功、无更新和错误日志。

默认时序为北京时间每天 `00:00` 启动 GitHub Actions，RouterOS 在 `00:10` 检查发布结果。十分钟间隔用于避免 RouterOS 在 Pages 新版本尚未发布完成时读取上一版；两端均按每日周期运行。

### 1.2 有意保留的人工控制

- 第一次安装和第一次切换；
- 上游条目数单次变化超过 25% 时的审核；
- RouterOS 跨主版本升级、切换到测试通道或低于最低版本时的兼容性复核；
- 是否清理原始 2026-09-17 静态列表；
- 是否回滚到静态列表。

### 1.3 未知目标改为移动后的完整影响边界

`set-unknown-default-mobile.rsc` 只修改六个既有 Mangle 对象：把一条普通未知目标兜底的连接标记改为 `conn_mobile` 并启用它，同时禁用五条普通 2:3 PCC 规则。脚本不会新增、删除或移动任何规则，也不会清空 Connection Tracking。

实际匹配优先级如下：

| 优先级 | 流量 | 结果 | 是否受未知目标切换影响 |
|---:|---|---|---|
| 1 | 从联通或移动 PPPoE 进入的连接 | 按进入线路标记，回包保持同一 WAN | 不受影响 |
| 2 | 路由器本机、RFC1918、LAN、光猫管理网、IKEv2 网段 | 在互联网策略分类前 `accept` | 不受影响 |
| 3 | 两个 VPS 目的地址 | 继续使用 VPS A/B 当前配对及两条主表 `/32` 路由 | 不受影响 |
| 4 | `192.168.99.4` 的 Tracker 和 PT 流量 | Tracker 固定联通；其他 PT 新连接按 1/5 联通、4/5 移动 | 不受影响 |
| 5 | OpenWrt 到 `202.99.96.68`、`211.137.160.5` | 分别固定联通、移动 | 不受影响 |
| 6 | 联通独有、移动独有目的 | 分别固定到对应运营商；A/B 地址库更新继续生效 | 不受影响 |
| 7 | 其余普通 LAN 新 IPv4 连接 | 标记为 `conn_mobile`，进入 `to_mobile` | 改为移动优先 |
| 8 | 已有连接 | 保留原 `connection-mark`，直到自然断开重建 | 不会立即迁移 |

`to_mobile` 的主默认路由是移动 `distance=51`，备用是联通 `distance=151`。移动 PPPoE 接口或对应路由失效时，策略表可以改走联通并由联通 Masquerade 出口。该机制根据接口/路由活动状态切换；如果 PPPoE 仍显示在线但运营商上游黑洞，它不会主动探测业务可达性。

端口映射仍只允许从联通 PPPoE 进入，WAN 入站连接标记和路由器本机 `output` 回包规则保持回程对称。Hairpin 使用 `dst-address-type=local`，在未知兜底的 `!local` 条件之外。IKEv2 客户端进入的接口不是 `LAN01`，VPN/LAN/光猫管理目标也被 RFC1918 规则提前绕过。QoS 根据实际 PPPoE 出接口标记数据包；未知流量转到移动后会计入移动队列。IPv6 不经过这些 IPv4 Address List 和 IPv4 Mangle 规则。

切换脚本在首次修改前核对以上依赖，包括规则属性和顺序、两张策略表的主备默认路由、每条 WAN 的通用 Masquerade、VPS `/32` 路由、公共端口映射、Hairpin、VPN 放行、QoS 以及 FastTrack 状态。任何对象缺失、重复或漂移都会报错并停止。

## 2. 安全模型

自动执行远程 `.rsc` 等同于信任发布该文件的仓库和 GitHub Pages。应遵守以下要求：

- 使用自己控制的专用仓库；列表本身不含秘密，建议使用公开仓库；
- 为 GitHub 账号启用双重验证；
- 保护 `main` 分支，要求 Pull Request 和 Actions 成功后才能合并；
- 不在生成文件、工作流或 RouterOS 脚本中放入令牌、PPPoE 密码或其他凭据；
- RouterOS Fetch 必须使用 HTTPS 和 `check-certificate=yes-without-crl`；
- 路由器时间和 DNS 必须正确，否则证书验证会失败；
- 不直接自动导入第三方仓库提供的脚本；本方案只从自己的 Pages 地址下载生成结果；
- GitHub Actions 依赖由 Dependabot 每周检查，升级通过 PR 审核完成。

RouterOS 会检查下载文件的精确字节数、导入结果数量和版本标记。发布清单还记录 SHA-512，供人在 GitHub 或其他计算机上审计。更新器不在路由器中读取整个大文件计算 SHA-512，因此路由器侧的传输信任边界是经过证书校验的 HTTPS Pages 站点。

## 3. 文件说明

```text
.github/workflows/publish.yml       GitHub Actions 构建和 Pages 发布
.github/dependabot.yml              Actions 依赖更新检查
generator/generate.py               无第三方 Python 依赖的生成器
generator/test_*.py                 集合运算、URL、版本策略和安全门测试
generator/validate_bundle.py        模板和发布文件静态检查
generator/prepare_installer.py       安全生成含 Pages URL 的安装文件
AUDIT-ROUTEROS-7.24.4-20260930.md    本次策略、命令和版本兼容性审计报告
routeros/install-template.rsc       RouterOS 安装模板
routeros/remove-automation.rsc      只移除自动化，保留当前列表和选路
routeros/rollback-to-legacy-20260917.rsc
                                    切回静态列表并移除自动化
routeros/set-unknown-default-mobile.rsc
                                    将普通未知/重叠目的切为移动优先
routeros/restore-unknown-default-previous.rsc
                                    恢复切换前记录的联通或普通 PCC 模式
```

## 4. 建立 GitHub 发布仓库

### 4.1 创建仓库

在 GitHub 创建一个专用仓库，例如：

```text
routeros-isp-lists
```

不要把完整 RouterOS 导出、密码、Token 或证书私钥放入该仓库。

把本目录中的内容作为新仓库根目录上传。仓库根目录应直接包含 `.github`、`generator` 和 `routeros`，不要额外再套一层 `isp-list-auto-update`。

### 4.2 启用 GitHub Pages

进入仓库：

```text
Settings → Pages → Build and deployment → Source → GitHub Actions
```

随后进入：

```text
Actions → Build and publish RouterOS ISP lists → Run workflow
```

第一次运行保持 `allow_large_change=false`。

成功后 Pages 地址通常为：

```text
https://<GitHub用户名>.github.io/<仓库名>
```

打开以下三个地址，必须都能访问：

```text
https://<用户名>.github.io/<仓库名>/manifest.json
https://<用户名>.github.io/<仓库名>/slot-a.rsc
https://<用户名>.github.io/<仓库名>/slot-b.rsc
```

`manifest.json` 中应包含：

- `schema` 为 `routercfg.isp-affinity-lists`；
- `schema_version` 为 `1`；
- 16 位十六进制 `version`；
- 联通、移动生成条目数；
- 两个槽位文件名、字节数和 SHA-512；
- 原始数据来源和 SHA-256。
- RouterOS 最低版本、支持的主版本和发布通道。

发布版本号由最终生效的“联通独有”和“移动独有”CIDR 内容生成。上游文件只改变注释或顺序时不会无意义重建；生成逻辑造成有效列表变化时，即使条目数相同，也会得到新版本并触发 RouterOS 更新。

### 4.3 启用相邻版本变化检查

第一次 Pages 发布成功后，进入：

```text
Settings → Secrets and variables → Actions → Variables → New repository variable
```

创建：

```text
Name:  PAGES_BASE_URL
Value: https://<用户名>.github.io/<仓库名>
```

末尾不要带 `/`。

以后工作流会读取当前线上 `manifest.json`。如果清单无法获取、超过 4 KiB 或格式无效，构建会安全失败，不会绕过相邻版本检查。如果任一列表的条目数或覆盖 IPv4 地址总量相对上一版变化超过 25%，定时发布失败并保留线上旧版本。确认上游变化真实合理后，手动运行工作流并将 `allow_large_change` 设为 `true`。

## 5. 发布端本地验证

在提交到 GitHub 前，可先本地运行。生成器仅使用 Python 标准库。

Linux/macOS：

```bash
cd isp-list-auto-update/generator
python3 -m unittest -v
cd ..
python3 generator/generate.py --output public
python3 -m json.tool public/manifest.json
```

Windows PowerShell：

```powershell
Set-Location .\isp-list-auto-update\generator
python -m unittest -v
Set-Location ..
python .\generator\generate.py --output .\public
python -m json.tool .\public\manifest.json
```

生成器默认使用上游项目提供的 GitHub Pages 镜像：

```text
https://gaoyifan.github.io/china-operator-ip/unicom.txt
https://gaoyifan.github.io/china-operator-ip/cmcc.txt
```

如需用固定文件复核：

```powershell
python .\generator\generate.py `
  --unicom-file ..\unicom-source-20260917.txt `
  --mobile-file ..\cmcc-source-20260917.txt `
  --output .\public-local
```

## 6. RouterOS 变更前检查

通过可靠的 LAN WinBox/终端连接执行。先保存并下载备份：

```routeros
/export terse file=before-isp-list-auto-redacted
/system backup save name=before-isp-list-auto
/system resource print
/system clock print
/ip dns print
```

确认版本、现有列表、规则和路由表：

```routeros
/system resource print
/ip firewall address-list print count-only as-value where list="routercfg-isp-unicom-only-20260917"
/ip firewall address-list print count-only as-value where list="routercfg-isp-mobile-only-20260917"
/ip firewall mangle print detail without-paging where comment="routercfg ISP affinity: ordinary Unicom-only destination"
/ip firewall mangle print detail without-paging where comment="routercfg ISP affinity: ordinary Mobile-only destination"
/routing table print detail where name="to_unicom"
/routing table print detail where name="to_mobile"
/system history print count-only where floating-undo=yes
```

进入下一步前必须满足：

- RouterOS 为 v7，版本不低于 `7.24.4`，并显示 `(stable)` 或 `(long-term)`；
- 静态联通列表为 `1520` 项；
- 静态移动列表为 `948` 项；
- 两条 Mangle 规则各一条、均启用；
- 联通规则是 `mark-connection → conn_unicom`；
- 移动规则是 `mark-connection → conn_mobile`；
- 两张策略路由表各一张；
- `floating-undo` 为 `0`；
- 路由器时间正确，DNS 可解析 GitHub Pages 域名。

如果现网已改变，不要修改安装脚本绕过检查；应重新获取脱敏导出并重新审查规则身份。

## 7. 生成 RouterOS 安装文件

不要直接上传 `install-template.rsc`。使用随附生成器把 Pages 基础地址写入安装文件。URL 必须是无账号、密码、查询参数和尾部 `/` 的标准 HTTPS 地址。生成的 `routeros/install.rsc` 已加入 `.gitignore`，不会误提交包含实际站点地址的部署副本。

跨平台推荐命令：

```text
python generator/prepare_installer.py \
  --base-url https://<用户名>.github.io/<仓库名> \
  --output routeros/install.rsc
```

Windows PowerShell 可写成一行：

```powershell
python .\generator\prepare_installer.py --base-url https://<用户名>.github.io/<仓库名> --output .\routeros\install.rsc
```

以下为没有 Python 时的手工替代方法。

PowerShell 示例：

```powershell
$baseUrl = 'https://<用户名>.github.io/<仓库名>'
$template = Get-Content -Raw .\routeros\install-template.rsc
$prepared = $template.Replace('BASE_URL_REPLACE_ME', $baseUrl)
if ($prepared.Contains('BASE_URL_REPLACE_ME')) { throw 'URL placeholder remains' }
Set-Content -LiteralPath .\routeros\install.rsc -Value $prepared -Encoding ascii
```

Linux/macOS 示例：

```bash
base_url='https://<用户名>.github.io/<仓库名>'
sed "s|BASE_URL_REPLACE_ME|${base_url}|g" \
  routeros/install-template.rsc > routeros/install.rsc
! grep -q 'BASE_URL_REPLACE_ME' routeros/install.rsc
```

检查生成文件中两个 `:local baseUrl` 值完全相同。不要在 URL 中放查询参数、令牌或用户密码。

## 8. 安装 RouterOS 更新器

将生成的 `routeros/install.rsc` 上传到 RouterOS Files 根目录。

先做语法检查：

```routeros
/import file-name=install.rsc verbose=yes dry-run
```

确认无错误后，在同一 LAN 终端按 `Ctrl+X` 进入 Safe Mode，再执行：

```routeros
/import file-name=install.rsc verbose=yes
/system script print detail where name="routercfg-isp-list-update"
/system scheduler print detail where name="routercfg-isp-list-update"
```

首次安装时必须满足：

- 更新脚本只有一个；
- Scheduler 只有一个；
- Scheduler 为 `disabled=yes`；
- 间隔为一天；
- 更新脚本和 Scheduler 的策略均包含 `ftp,read,write,test,policy`，其中 `ftp` 用于下载、读取和清理 Files 中的临时文件；
- 当前 Mangle 仍指向 2026-09-17 静态列表；
- 尚未出现 `routercfg-isp-*-auto-a/b` 列表。

安装器也用于升级旧版受管更新器：它只接受名称和注释均精确匹配的现有脚本与 Scheduler，确认更新任务未运行后才替换它们；替换后的 Scheduler 一律保持禁用，必须重新完成人工运行和业务验收后再启用。名称相同但注释不同的对象会使安装停止。

确认后按 `Ctrl+X` 提交 Safe Mode。若任何检查失败，按 `Ctrl+D` 放弃并重新登录检查。

### 8.1 将普通未知目标切换为移动优先

把下列两个文件上传到 RouterOS Files 根目录：

```text
set-unknown-default-mobile.rsc
restore-unknown-default-previous.rsc
```

先保存当前文本导出，并进行只读语法和前置条件检查：

```routeros
/export file=before-unknown-default-mobile
/import file-name=set-unknown-default-mobile.rsc verbose=yes dry-run
```

`dry-run` 必须完整结束且没有 `error`。随后从可靠的 LAN 管理终端按 `Ctrl+X` 进入 Safe Mode，再执行：

```routeros
/import file-name=set-unknown-default-mobile.rsc verbose=yes
/ip firewall mangle print detail without-paging where comment~"^routercfg ISP affinity: ordinary"
/ip firewall mangle print detail without-paging where comment~"^PCC weighted"
/ip route print detail without-paging where routing-table="to_mobile" and dst-address="0.0.0.0/0"
```

应看到：

- 未知规则注释以 `ordinary unknown destination via Mobile` 开头，`disabled=no`，`new-connection-mark=conn_mobile`；
- 五条 `PCC weighted` 均为 `disabled=yes`；
- 联通独有和移动独有两条规则仍启用；
- `to_mobile` 中移动主路由和联通备用路由均存在。

不要清空整个 Connection Tracking。用一台非 `192.168.99.4` 的普通 LAN 主机新建连接，分别测试未知目的、联通独有目的、移动独有目的、两个 VPS、两台运营商 DNS、内网管理地址和 Hairpin 服务。检查规则计数、连接标记、实际出口和现有入站端口映射。全部通过后按 `Ctrl+X` 提交 Safe Mode；失败时按 `Ctrl+D` 断开，让 Safe Mode 自动撤销。

脚本会把切换前状态记录在兜底规则注释中。如果需要恢复，在 Safe Mode 中执行：

```routeros
/import file-name=restore-unknown-default-previous.rsc verbose=yes dry-run
/import file-name=restore-unknown-default-previous.rsc verbose=yes
```

原状态是未知默认联通时，回滚会恢复该规则；原状态是普通 2:3 PCC 时，回滚会重新启用五个 PCC 桶并禁用兜底。重复执行切换或回滚会先验证完整状态，不会叠加规则。

切换和回滚脚本会捕获运行期错误，把原始错误详情写入 RouterOS 系统日志，然后继续以失败状态退出，不会把错误吞掉。查看本功能的开始、成功和失败记录：

```routeros
/log print without-paging where message~"routercfg unknown-default-Mobile"
```

失败记录包含固定的 `FAILED:` 标记，例如：

```text
routercfg unknown-default-Mobile FAILED: Mobile-table Unicom backup changed
```

每天运行的 Address List 更新器使用独立前缀：

```routeros
/log print without-paging where message~"ISP list updater"
```

RouterOS 默认系统日志容量有限，旧记录会轮换。如果需要跨重启、长期保存或告警，应另外配置远程 Syslog；本项目不自动修改现有 Logging action，避免影响其他日志策略。

自动更新器在最外层捕获任何未处理错误，把原始原因写成 `ISP list updater FAILED: ...` 后重新以失败状态退出。内部下载、导入和策略切换仍保留各自的清理或回滚；因此 Scheduler 无人值守运行失败时，可以用上面的日志命令定位准确阶段。

## 9. 第一次手工更新和切换

第一次运行会创建约数千条 Address List，不能放在 RouterOS Safe Mode 中执行；Safe Mode 的历史动作容量不适合这种批量导入。A/B 设计保证生成失败时活动静态列表不被删除。

在低峰期、可靠 LAN 管理连接上执行：

```routeros
/system script run routercfg-isp-list-update
```

完成后检查日志：

```routeros
/log print without-paging where message~"ISP list updater"
```

第一次成功应出现类似：

```text
ISP list updater: switched from legacy to a; version=...; Unicom=...; Mobile=...
```

检查规则实际指向同一个槽：

```routeros
/ip firewall mangle print detail without-paging where comment="routercfg ISP affinity: ordinary Unicom-only destination"
/ip firewall mangle print detail without-paging where comment="routercfg ISP affinity: ordinary Mobile-only destination"
```

第一次通常应分别指向：

```text
routercfg-isp-unicom-auto-a
routercfg-isp-mobile-auto-a
```

检查四个自动槽位的数量：

```routeros
/ip firewall address-list print count-only as-value where list="routercfg-isp-unicom-auto-a"
/ip firewall address-list print count-only as-value where list="routercfg-isp-mobile-auto-a"
/ip firewall address-list print count-only as-value where list="routercfg-isp-unicom-auto-b"
/ip firewall address-list print count-only as-value where list="routercfg-isp-mobile-auto-b"
```

活动槽数量必须与 Pages 上 `manifest.json` 完全一致；另一个槽第一次运行时应为空。

立即再运行一次验证幂等性：

```routeros
/system script run routercfg-isp-list-update
/log print without-paging where message~"ISP list updater"
```

应记录：

```text
ISP list updater: already current
```

Address List 数量和 Mangle 指向不应变化。

## 10. 业务验收

不要清空整个 Connection Tracking 表。现有连接继续保留原 `connection-mark`，新连接才使用新列表。

重置三条本方案 Mangle 规则计数：

```routeros
/ip firewall mangle reset-counters [find where comment~"^routercfg ISP affinity: ordinary"]
```

从一台非 `192.168.99.4`、非 OpenWrt DNS 固定出口主机分别发起新请求：

```powershell
nslookup www.amap.com 202.99.96.68
nslookup www.amap.com 211.137.160.5
```

再访问一个未分类目标。然后检查：

```routeros
/ip firewall mangle print stats without-paging where comment~"^routercfg ISP affinity: ordinary"
/ip firewall connection print detail without-paging where connection-mark="conn_unicom"
/ip firewall connection print detail without-paging where connection-mark="conn_mobile"
/ip firewall nat print stats without-paging where dynamic=yes
/system resource print
```

验收项目：

- 联通、移动两条分类规则和当前启用的未知/PCC模式均能在对应测试中增加计数；
- 新连接的 `connection-mark` 与目标分类一致；
- VPS A/B、PT、Tracker 和 DNS pin 行为未改变；
- 常用网站、管理连接和 DNS 正常；
- CPU、内存没有持续异常；
- 没有新增重复脚本、Scheduler 或临时 `.rsc` 文件。

## 11. 启用定时更新

完成第一次运行和业务验收后启用：

```routeros
/system scheduler enable [find where name="routercfg-isp-list-update"]
/system scheduler print detail where name="routercfg-isp-list-update"
```

确认：

```text
disabled=no
interval=1d
start-time=00:10:00
```

每天只获取小清单。上游数据未变化时不会下载或重建大列表；版本变化时导入非活动槽并在末尾切换。

## 12. 日常监控

每周检查一次：

```routeros
/system scheduler print detail where name="routercfg-isp-list-update"
/system script job print where script="routercfg-isp-list-update"
/log print without-paging where message~"ISP list updater"
/ip firewall mangle print detail without-paging where comment~"^routercfg ISP affinity: ordinary (Unicom|Mobile)"
/system resource print
```

GitHub 侧检查：

- 最近一次定时工作流成功；
- Pages 的 `manifest.json` 可以访问；
- 没有待处理的 Dependabot 安全更新；
- 没有因为 25% 变化门限而失败的工作流；
- 手动 `allow_large_change=true` 只在核对上游变化后使用。

## 13. 故障行为

| 故障 | 自动行为 | 人工处理 |
|---|---|---|
| DNS、GitHub Pages或TLS失败 | 当前活动列表保持不变，脚本报错 | 检查路由器时间、DNS和出口 |
| Manifest 无效或超过4 KiB | 停止 | 检查 Pages 内容和工作流 |
| 条目数超出安全范围 | 停止 | 审核上游和生成器 |
| Payload 下载不完整 | 删除临时文件，停止 | 等下次重试 |
| 非活动槽导入中断 | 活动槽不变；非活动槽可残留部分数据 | 下次运行会先清理非活动槽 |
| 两条 Mangle 缺失或重复 | 停止 | 恢复经审核的现网规则 |
| 管理员在更新中修改规则 | 停止，活动槽不切换 | 检查变更来源 |
| 第二条规则切换失败 | 尝试把两条规则恢复到旧槽 | 立即检查日志和两条规则 |
| RouterOS v7 低于7.24.4、不是stable/long-term，或主版本不是v7 | 在下载和导入前停止，现有列表继续工作 | 恢复支持的版本/通道；跨主版本先完成兼容审查 |

不要通过删除检查条件来“修复”失败；错误表示现网假设或发布数据已经变化。

## 14. 回滚与卸载

### 14.1 只停止自动更新，保持当前列表

上传并执行：

```routeros
/import file-name=remove-automation.rsc verbose=yes dry-run
/import file-name=remove-automation.rsc verbose=yes
```

该脚本移除 Scheduler、更新脚本和临时下载文件，保留当前 A/B Address List 以及两条 Mangle 的现有指向。

### 14.2 完整切回2026-09-17静态列表

前提是两张旧静态列表仍保留且数量分别为 1,520、948。上传并执行：

```routeros
/import file-name=rollback-to-legacy-20260917.rsc verbose=yes dry-run
/import file-name=rollback-to-legacy-20260917.rsc verbose=yes
```

脚本会：

1. 确认更新器未运行；
2. 校验旧静态列表；
3. 禁用 Scheduler；
4. 将两条 Mangle 切回旧列表；
5. 移除更新脚本和 Scheduler；
6. 保留 A/B 列表供诊断。

回滚后重新执行第 10 节业务验收。

### 14.3 清理未引用的列表

稳定观察至少七天后才能考虑删除旧静态列表。删除前必须确认没有任何 Mangle、NAT 或 Filter 规则引用：

```routeros
/ip firewall mangle print where dst-address-list="routercfg-isp-unicom-only-20260917"
/ip firewall mangle print where dst-address-list="routercfg-isp-mobile-only-20260917"
/ip firewall nat print where dst-address-list="routercfg-isp-unicom-only-20260917"
/ip firewall nat print where dst-address-list="routercfg-isp-mobile-only-20260917"
/ip firewall filter print where dst-address-list="routercfg-isp-unicom-only-20260917"
/ip firewall filter print where dst-address-list="routercfg-isp-mobile-only-20260917"
```

一旦删除旧静态列表，第 14.2 节的快速回滚文件将不可再用；必须先从备份或原始 `.rsc` 恢复旧列表。

不要删除当前活动 A/B 槽。Payload 自身也会拒绝覆盖任何仍被 Mangle 引用的槽位。

## 15. RouterOS 升级

更新器读取 `/system resource get version` 的完整值并逐段比较版本号。支持范围为：

- 主版本必须是 v7；
- 版本必须不低于 `7.24.4`；
- 通道标记必须是 `(stable)` 或 `(long-term)`。

本次命令兼容性审计日期为 2026-09-30。MikroTik 官方发布记录中的当前稳定版是 `7.24.4 (stable)`，与本项目实际基线一致；当前长期维护版 `7.23.7 (long-term)` 低于最低版本，因此会被脚本明确拒绝。导入前先确认设备返回值：

```routeros
:put [/system resource get version]
```

当前目标设备应显示：

```text
7.24.4 (stable)
```

本次使用的命令均适用于该版本：

- `/import ... verbose=yes dry-run` 从 RouterOS 7.16 起提供；
- `:onerror <变量> in={...} do={...}`、`:log error`、`:error` 可用于保留错误详情并失败退出；
- `/routing table ... fib`、`/routing rule`、routing mark 属于 RouterOS v7 策略路由接口；
- Mangle 的 `mark-connection`、`mark-routing`、`connection-state=new`、`connection-mark=no-mark`、PCC 和 `passthrough` 均为当前支持属性；
- `/export file=...` 默认隐藏敏感信息；`print count-only as-value` 和 `where` 过滤均受支持。

根目录中名称带 `7.24.2`、旧 `7.24.4` 精确版本检查的历史部署脚本用于说明既有配置的形成过程，不应在当前设备上重新批量导入。新的 Address List 安装器、更新器、未知目标移动切换和回滚脚本使用统一的数字版本检查。

因此，从 `7.24.4` 升级到后续 v7 稳定版或长期维护版后，已安装的新版更新器会继续按计划自动更新列表，不需要每次修改脚本。版本比较按数字段进行，例如 `7.24.10` 高于 `7.24.4`，不会发生字符串比较错误。

升级 RouterOS 时仍应：

1. 导出配置并保存二进制备份；
2. 升级并重启后检查 `/system resource print`；
3. 检查 Scheduler 最近一次运行状态和 `ISP list updater` 日志；
4. 手工运行一次更新器并执行第 9～10 节验收。

`testing`、`development`、预发布格式、v6、未来 v8 或无法解析的版本会在 Fetch 和 Import 之前安全停止，当前活动 Address List、Mangle 指向和既有连接保持不变。未来 v8 需要先核对 Fetch、JSON 反序列化、Import、Mangle、脚本权限和文件属性，再发布明确支持 v8 的更新器；不能在未知主版本上自动放行。

如果路由器中已经安装了旧的“只允许 7.24.4”脚本，先使用本项目最新模板重新生成 `install.rsc`，按第 8 节在 Safe Mode 中导入。安装器会验证并替换旧的受管脚本和 Scheduler，且将 Scheduler 保持禁用。随后按第 9～10 节手工验收，再按第 11 节启用 Scheduler。这是一次性迁移；迁移完成后，后续受支持的 v7 升级无需重复安装。

## 16. 上游与文档

- 数据源：[gaoyifan/china-operator-ip](https://github.com/gaoyifan/china-operator-ip)
- RouterOS Fetch：[MikroTik Fetch](https://help.mikrotik.com/docs/spaces/ROS/pages/8978514/Fetch)
- RouterOS 脚本：[MikroTik Scripting](https://help.mikrotik.com/docs/spaces/ROS/pages/47579229/Scripting)
- RouterOS 导入：[MikroTik Configuration Management](https://help.mikrotik.com/docs/spaces/ROS/pages/328155/Configuration%2BManagement)
- RouterOS Scheduler：[MikroTik Scheduler](https://help.mikrotik.com/docs/spaces/ROS/pages/40992881/Scheduler)
- GitHub Pages Actions：[GitHub Pages deployment](https://docs.github.com/en/get-started/start-your-journey/deploying-your-website-automatically)
