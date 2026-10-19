# nnnu-auth — 校园网门户自动认证（OpenWrt）

**专门为 nnnu（武鸣校区）定制**：门户 `http://172.27.0.5`、BRAS `172.27.0.100`
（`ZAXSOFT-BRAS-WM`）都是写进默认值的，装上就能用，不用改。
其它校区/学校如果门户协议不一样，需要自己调整。

从抓包 `172.27.0.5.har` 逆向出认证协议后写成的 OpenWrt 路由器自动登录脚本。
认证成功后代拨上网、掉线自动重连。可以装成一个 opkg 软件包，在 **LuCI 里点着配置**，
也能像以前那样直接铺文件用。

现有验证：主脚本端到端断言 **59/59**、软件包脚本断言 **23/23**、LuCI 页面经 Lua 语法检查、
ipk 结构与执行位经构建校验，另外用**抓包里的真实门户 HTML** 跑通了完整流程。

---

## 1. 交付物

| 文件 | 用途 |
|---|---|
| `dist/nnnu-auth_1.2.3-1_all.ipk` | **程序包**：脚本 + uci 配置 + init/hotplug + 渲染与生效脚本 |
| `dist/luci-app-nnnu-auth_1.2.3-1_all.ipk` | **界面包**：LuCI「服务 → 校园网认证」设置页与状态页 |
| `dist/nnnu-auth.sh` | 主脚本本体（纯 POSIX sh，busybox 可用；包里的就是它） |
| `dist/nnnu-auth-1.2.3.tar.gz` | 不想用 opkg 时的一体包（含 `install.sh`） |
| `pkg/` | 两个包的源码树（`control/` + `data/`） |
| `tools/mkipk.py` | 纯 Python 的 ipk 打包器（**不需要 OpenWrt SDK**） |
| `tools/check_lua.py` | 用 luaparser 给 LuCI 的 `.lua` / `.htm` 做语法检查 |
| `tools/build-pkgs.sh` | 一键构建两个 ipk |
| `tests/` | 仿真门户端到端测试、包脚本测试、线上门户只读校验 |

最省事的用法：装两个 ipk，然后在 LuCI 里填学号密码（见下一节）。

---

## 2. 抓包逆向出的认证协议

门户是 **ZAXSOFT BOSS Web**（`http://172.27.0.5`，响应头 `Server: bossWebV1.0.1`）。
整个认证就 3 条请求：

```
① GET  http://<网关IP>/                  ← 任意 http 请求被 BRAS 劫持
   ← 302 Location: http://172.27.0.5/webauth.do?wlanacip=..&wlanacname=..&wlanuserip=..&mac=..&vlan=0&url=..
② GET  http://172.27.0.5/webauth.do?<上面那串参数>
   ← 200 登录页（含隐藏字段 pageid=6、templatetype=1… + Set-Cookie: JSESSIONID-BOSS-1=..）
③ POST 同一个 URL，表单体：userId=学号&passwd=密码&...（密码明文，无 token、无签名、无验证码）
   ← 200 结果页，成功时含 <input id="act" value="LOGINSUCC">
④ POST http://172.27.0.5/getAuthResult.do  体: userId=..&pageId=6
   ← {"check":"运营商网络拨号成功"}    ← 代拨结果，成功约需数秒
```

抓到的真实提交体（514 字节，脚本按同样顺序、同样编码构造）：

```
scheme=http&serverIp=tomcat_server%3A80&hostIp=http%3A%2F%2F127.0.0.1%3A8081%2F&loginType=
&auth_type=0&isBindMac1=0&pageid=6&templatetype=1&listbindmac=0&recordmac=1&isRemind=1
&loginTimes=&groupId=&distoken=&echostr=&url=http%3A%2F%2Fedge-http.microsoft.com%2F...
&isautoauth=&mobile=&notice_pic_loop2=%2Fportal%2F...%2Fbj.png&notice_pic_loop1=%2Fportal%2F...%2Flogo.png
&userId=你的学号&passwd=********&remInfo=on&isBindMac=bindmac
```

关键结论（决定了脚本怎么写）：

1. **`wlanuserip` / `mac` / `wlanacname` / `wlanacip` 必须来自 BRAS 的 302**，不能写死。
   裸访问 `/webauth.do`（不带参数）门户回 **「未知网关，请检查接入设备是否配置正确!」**——
   所以脚本用「探测 → 抓 302 → 提取参数」的方式拿这四个值。
2. **密码是明文提交**，页面上的 `jquery.md5.js` 只是给微信/其他模板用的，登录表单没有用到。
3. **没有 CSRF token / 时间戳 / 签名**，`distoken`、`echostr` 都是空值，所以脚本重放表单即可。
4. **表单里的 `pageid`、`templatetype`、`serverIp`、`notice_pic_loop*` 等从登录页实时解析**
   （页面改版时脚本自动跟着变，取不到才用抓包默认值）。
5. 这个账号是**运营商代拨**类型：认证成功后 BRAS 替用户拨号，页面提示
   「正在进行外网拨号请稍候...」，需要轮询 `getAuthResult.do` 直到「运营商网络拨号成功」。
   脚本把「代拨成功」和「真的能上网」都当判定条件（后者为准）。

---

## 3. 安装

### 方式 A：装成软件包（推荐，全程在 LuCI 里点）

```
dist/nnnu-auth_1.2.3-1_all.ipk             程序包（脚本 + 配置 + 服务）
dist/luci-app-nnnu-auth_1.2.3-1_all.ipk    界面包（LuCI 菜单与页面）
```

传上路由器装上（两个包都是 `Architecture: all`，任何固件都能装）：

```sh
scp dist/*.ipk root@192.168.1.1:/tmp/
ssh root@192.168.1.1
opkg update
opkg install /tmp/nnnu-auth_1.2.3-1_all.ipk /tmp/luci-app-nnnu-auth_1.2.3-1_all.ipk
```

装完刷新 LuCI，菜单里会多出 **服务 → 校园网认证**：

- **设置** 页：学号、密码、运行方式（cron / procd）、绑定 MAC、检查间隔、探测地址、门户参数
- **状态与诊断** 页：在线状态、当前运行方式、HTTP 客户端与 URL 编码器自检结果、最近 20 行日志，
  以及四个按钮：**立即认证 / 检查并补认证 / 诊断 / 注销下线**

保存时自动渲染配置并切换运行方式，不用 ssh。命令行仍然可用（`nnnu-auth.sh login|status|doctor`）。

> 密码存在 `/etc/config/nnnu-auth`（LuCI 的 uci 配置）里，会由 `render-conf.sh`
> 渲染成 `/etc/nnnu-auth.conf`（权限 600）供脚本读取。**uci 是唯一权威来源**，
> 那个 conf 是生成物，别手改——要改配置用 LuCI 或 `uci set nnnu-auth.main.*`。
> 从旧版（手写 conf）升级时，首次安装会自动把账号密码搬进 uci，不会丢。
>
> 若固件开启了强制签名校验而拒绝装未签名的本地包，改用下面的方式 B。

### 方式 B：直接铺文件（不用 opkg）

```sh
# 1) 把 nnnu-auth 目录传到路由器（Windows 用 winscp / scp 均可）
scp -r nnnu-auth root@192.168.1.1:/tmp/

# 2) 上路由器安装
ssh root@192.168.1.1
cd /tmp/nnnu-auth
sh dist/install.sh              # 默认：cron 每分钟检查（推荐）
# sh dist/install.sh service    # 或：procd 常驻守护（掉线秒级重连）
# sh dist/install.sh test       # 装完顺手打印一次诊断
```

然后填账号密码：

```sh
vi /etc/nnnu-auth.conf          # 改 USERNAME / PASSWORD 两行
/usr/bin/nnnu-auth.sh login     # 立刻认证一次
/usr/bin/nnnu-auth.sh status    # 确认在线
```

### 运行方式（两种，二选一）

| 方式 | 触发时机 | 适合 |
|---|---|---|
| cron `*/1`（默认） | 每分钟检查一次，掉线最多 1 分钟恢复 | 想要简单、省内存 |
| procd `service` | 常驻循环，默认 60s 一次 | 想更快恢复、日志集中在 logread |

另外 `hotplug` 会在 WAN 每次 up 后 3 秒主动认证一次，和上面两种方式可以共存。

### 自己重新构建软件包

改完 `dist/nnnu-auth.sh` 或 LuCI 页面后（**不需要 OpenWrt SDK**，只用 Python）：

```sh
sh tools/build-pkgs.sh     # 同步脚本 → 查 Lua 语法 → 打两个 ipk → 校验结构
sh tests/test_pkg.sh       # 验证 render-conf.sh 与 apply.sh 的分支逻辑
```

构建脚本会自动给带 shebang 的文件打上 755（Windows 上看不到执行位，不处理的话
init.d/hotplug 装上去不可执行，服务起不来——这个坑已经踩过并写进校验里）。

`.ipk` 的格式也踩过一个坑并写进了校验：**OpenWrt 的 ipk 是 `gzip(tar(./debian-binary, ./data.tar.gz, ./control.tar.gz))`**，
不是 Debian 那种裸 `ar` 归档。做错了 opkg 只会回一句 `Malformed package file`。
`tools/mkipk.py --verify` 会核对格式与每个文件的权限位，`--compare 官方.ipk` 可以对着官方包比对外层布局。

**LuCI 侧也踩过两个坑**，都做成规则写进了 `tools/check_lua.py`（`build-pkgs.sh` 会跑它）：

1. **不要写 `s.tabs = true` 再 `s:tab()`**。LuCI 的 `AbstractSection.tab()` 内部是
   `self.tabs = self.tabs or { }`，先赋成布尔值会被保留，随后当表用，页面直接崩在
   `cbi.lua:844: attempt to index a boolean value`。正确做法是只调 `s:tab(name, title)` 让它自己建表；
   本项目的设置页干脆用多个 `NamedSection` 分组，不依赖 tabs。
2. **模板里不要引 `<%+header%>` / `<%+footer%>`**。JS 版 LuCI（23.05+）的页面框架由前端提供，
   `luci-compat` 的 `luasrc/view/` 下只有 `cbi/`，没有页面级的 header/footer，引了会渲染失败。

---

## 4. 命令与配置

```sh
nnnu-auth.sh ensure     # 在线就退出，不在线才认证（cron 用这个）
nnnu-auth.sh login      # 强制认证一次
nnnu-auth.sh status     # 只查在线状态（在线=0，离线=1，可直接用于脚本判断）
nnnu-auth.sh logout     # 尝试注销下线（实验性）
nnnu-auth.sh monitor    # 常驻循环（procd 用这个）
nnnu-auth.sh doctor     # 诊断：接口/IP/MAC、302 参数、登录页字段，不发密码
加 -q 静默（只写日志）
```

常用配置项（`/etc/nnnu-auth.conf`，改完下次检查即生效）：

| 项 | 说明 |
|---|---|
| `USERNAME` / `PASSWORD` | 学号 / 密码 |
| `PROBE_URLS` | 探测地址，默认微软/谷歌/小米的 `generate_204`，被劫持时会 302 到门户 |
| `BIND_MAC=1` | 提交"绑定MAC"（与浏览器默认勾选一致）。若账号已绑在别的设备上，改成 `0` |
| `REMEMBER=1` | 提交"记住密码" |
| `INTERVAL` | monitor 检测间隔，默认 60s |
| `DIAL_WAIT` / `VERIFY_WAIT` | 等代拨结果 / 等真正联网的上限，默认各 60s |
| `WAN_IFACE` `WAN_IP` `WAN_MAC` | 留空自动探测，抓不到 302 兜底时才需要手填 |
| `PORTAL_HOST` `WLANACNAME` `WLANACIP` `DEFAULT_URL` | 兜底门户参数，一般不用动 |
| `LOG_FILE` | 默认 `/var/log/nnnu-auth.log`（超 256KB 自动截断） |

日志：

```sh
tail -f /var/log/nnnu-auth.log
# cron 模式下的输出：
logread | grep nnnu-auth
```

---

## 5. 排错

先跑 `/usr/bin/nnnu-auth.sh doctor`，它会打印：WAN 接口/IP/MAC、每个探测地址的状态码与 `Location`、
解析出的门户参数、登录页里取到的关键字段、当前在线状态、**最近 12 行日志**，以及上次失败时
门户返回页的落盘位置与从中提取到的提示。绝大多数问题看这一段就能定位。

认证失败时脚本会把门户的原话摊开，形如：

```
认证失败: act=无 errMessage=账号或密码错误 提示=账号或密码错误
   响应: HTTP 200
   门户返回页已存: /tmp/nnnu-auth-last-response.html
   → 检查 /etc/nnnu-auth.conf 里的 USERNAME / PASSWORD
```

| 现象 | 原因 / 处理 |
|---|---|
| 日志「门户返回【未知网关】」 | 门户参数不对。检查 `doctor` 里有没有抓到 `Location: .../webauth.do?...`；抓不到就手填 `WAN_IP`/`WAN_MAC` |
| 日志「门户返回【没有找到认证页面】」 | 同上，参数过期或不属于本机。脚本正常走 302 参数不会碰到 |
| 日志「账号或密码错误」 | 密码错了；或同一账号已在别的设备在线（校园网一般单会话） |
| 日志里出现「绑定 / MAC」字样 | **账号已被绑定到另一台设备**（例如电脑）。先去自助服务解绑，再让路由器认证；只想不绑定就把 `BIND_MAC` 改成 `0` |
| 「认证成功」但「探测仍不通」 | 代拨还在进行 → 把 `DIAL_WAIT`、`VERIFY_WAIT` 调大（如 180）；若一直不通，多半是账号欠费/被封 |
| 「找不到 HTTP 客户端」 | `opkg update && opkg install curl` |
| **日志里「提交认证: … (261 字节)」这种明显偏小的长度** | **URL 编码器坏了**（固件没有可用的 `od`），表单值全被编码成空串，账号密码根本没提交。v1.2 起会自动降级到 `hexdump`/纯 `awk` 并自检；旧版可临时 `opkg install coreutils-od` |
| 「已有实例在运行 / 锁仍很新，跳过」 | 正常防重入。真的卡住了：`rm -rf /tmp/nnnu-auth.lock` |
| 已认证但过一会儿又掉 | 换了 IP 或网关清了会话。cron/hotplug 会自动补认证；也可把 `INTERVAL` 调小 |

**判定"到底卡在哪一步"的一条命令**：

```sh
tail -25 /var/log/nnnu-auth.log
```

- 只到「门户参数」/「登录页已取到」→ 卡在提交（多半是账号密码或绑定问题）
- 出现「认证成功」但没有「已联网」→ 认证本身过了，是代拨/网关侧问题（调大等待时间）
- 出现「认证失败: …」→ 后面的 `errMessage=` 就是门户给的理由，照上表处理

**一个决定性的小实验**（判断是不是"同一账号已在别处在线"）：

```sh
# 在电脑/手机浏览器里点"下线"，然后立刻在路由器上执行：
/usr/bin/nnnu-auth.sh login
```

- 成功 → 之前就是账号被电脑占着（校园网单会话）。以后只让路由器认证即可
- 仍失败且提示含"绑定/MAC" → 去自助服务解绑该账号的 MAC，或把绑定转给路由器

**手动验证参数是否对**（不改任何东西，只发 GET）：

```sh
nnnu-auth.sh doctor
# 或者直接看网关到底把你 302 到哪
curl -sI http://edge-http.microsoft.com/captiveportal/generate_204 | grep -i location
```

---

## 6. 验证情况

| 验证 | 结果 |
|---|---|
| 主脚本端到端测试 `sh tests/run_tests.sh` | **59 项断言全过**：已在线直接退出、完整认证、cookie 透传、`pageid` 变化、代拨轮询、密码错误、无 302 兜底、`status`、互斥锁、`doctor`、无 curl 的 wget 通道、**纯 awk 编码器 + 中文密码**、**"od 坏掉"的 Kwrt 现场复现** |
| 软件包脚本测试 `sh tests/test_pkg.sh` | **23 项断言全过**：`render-conf.sh` 的取值与单引号转义（含引号/`$`/中文密码）、`apply.sh` 的 cron / procd / 未配置账号 / 已禁用 四种分支，且重复 apply 不叠加 cron 行 |
| LuCI 页面 `python tools/check_lua.py pkg` | 2 个 `.lua` + 2 个 `.htm`（拼接跨块的 Lua 后）全部通过语法检查；另有两条"已知会炸"的规则（`.tabs = true`、`<%+header%>`）也校验；检查器自身用故意写坏的与写在注释里的样例验证过，只抓真代码 |
| ipk 产物 `python tools/mkipk.py ... --verify` | 外层格式（必须 gzip+tar）、`control` 字段、**每个文件的权限位**（脚本 755 / 配置 644）逐一核对；`--compare` 与官方 ipk 比对过布局 |
| 用**抓包里的真实门户 HTML** 回归（`tests/fixtures/`） | 通过：真实登录页里 20 个隐藏字段全部解析正确，真实成功页的 `act=LOGINSUCC` 被识别 |
| 对**线上门户** `172.27.0.5` 只读比对（`tests/check_live_portal.sh`） | `pageid=6`、`templatetype=1`、`serverIp`、`hostIp`、`notice_pic_loop*`、`url` 等与抓包一致 |
| 表单体字节级比对 | 脚本构造的 POST 体与浏览器抓包**同结构同顺序**，仅 `url` 长度不同（492 + 22 = 514 字节，与抓包完全一致） |
| HTTP 客户端 | `curl` 通道实测通过；`uclient-fetch`/`wget` 用 busybox 格式仿真验证通过（仍建议装 curl） |
| 真机登录 | **未做**：本机在 VMware NAT 段且当前已在线，拿不到未认证状态的门户 302。上路由器第一次跑请先 `doctor`，再 `login` |

---

## 7. 注意事项

- **`/etc/nnnu-auth.conf` 里是明文密码**，务必 `chmod 600`（安装脚本已设置），别提交到公开仓库。
- **绑定 MAC**：默认按浏览器行为提交 `isBindMac=bindmac`，会把账号绑到路由器 WAN 口 MAC 上。
  如果这个账号还要在手机/电脑上直接用，建议把 `BIND_MAC` 改成 `0`，或先去自助服务解绑。
- 路由器认证的是**路由器自己的 WAN 口 IP/MAC**，LAN 侧设备共享这一条已认证会话（NAT），
  所以别再在电脑上单独登录同一账号，容易互相踢下线。
- `logout` 是照 `webdisconn.do` 推的，属实验性功能，不保证所有模板都生效；日常不需要注销。
- 门户改版时，脚本会优先用页面上解析到的字段，通常无需改动；若表单结构大改，
  用 `doctor` 看字段、再对照 `build_login_data` 的字段列表调整即可。
