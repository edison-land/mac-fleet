# Mac mini 远程主机部署指南：断电自启 + 远程接入

版本：v0.1 · 2026-10-06
适用：放在第三方场地（朋友家）、无人值守、供多人远程使用的 Apple Silicon Mac mini。

> **状态说明**
> 本文依据 Apple / 网易 UU 远程官方文档整理，命令在本机 macOS 26.6.2（arm64）上核对过语法。**尚未在目标 Mac mini 上部署验收。**
> 标 `[待实测]` 的条目必须在第一台机器上验证后再写进脚本。

---

## 1. 目标与恢复链路

两件事：

1. **机器层**：意外断电、死机后，机器能自己回到「可远程连接」的状态，不需要人到现场。
2. **入口层**：管理员（你）和若干远程用户（朋友）能连进来，而且**用户之间相互隔离**。

断电恢复是一条串行链路，任何一环卡住，远程都连不上：

```text
来电 ─▶ Mac 自动开机 ─▶ [FileVault 解锁] ─▶ macOS 启动 ─▶ 系统服务（SSH / 屏幕共享 / Tailscale）
                                                 └─▶ 自动登录 console 账号 ─▶ UU 远程启动并在线
```

- 系统服务（SSH、屏幕共享、Tailscale 系统版）**不需要有人登录桌面**就能运行。
- UU 远程是桌面应用，**必须有用户登录桌面**才会启动，所以需要自动登录。
- FileVault 开启时，链路会停在「解锁」这一步，后面全部不会发生。

---

## 2. 先做两个决策

### 2.1 FileVault：开还是关

| | 方案 A：关闭 FileVault + 自动登录 | 方案 B：保留 FileVault |
|---|---|---|
| 断电后 | 通电即全自动恢复，UU 自动上线 | 停在解锁界面，需要远程解锁 |
| 远程解锁手段 | 不需要 | IP KVM，或 macOS 26 的 SSH 预启动解锁（需局域网内可达，Tailscale 此时未运行） |
| 防的是 | —— | 有人在现场接显示器、或整机被拿走时读取数据 |
| 风险 | 现场任何人开机即进入自动登录账号；所有用户的数据安全只剩各账号密码 | 恢复链路更长，多一套硬件或跳板 |
| 适合 | 数据不敏感，场地可信 | 存放朋友的敏感数据，或对外提供服务 |

**FileVault 只管「物理接触」这一种威胁，不管用户之间能不能互相看。** 用户隔离靠账号和权限（第 5 节），两种方案都需要做。

方案 A 的关键缓解措施：**自动登录的不是管理员，而是一个空的、低权限的 `console` 账号。** 现场有人开机，也只能进入这个空账号。

> 本文默认采用**方案 A**。走方案 B 时，第 6 节自动登录不做，改按上面那份 KVM 操作单执行。

### 2.2 远程入口怎么分工

| 入口 | 本质 | 多用户隔离 | 给谁用 |
|---|---|---|---|
| **UU 远程** | 共享当前这一块屏幕 | ❌ 所有人进的是同一个桌面、同一个账号 | 只给管理员，作为图形救援入口 |
| **SSH**（经 Tailscale） | 每人用自己账号登录命令行 | ✅ 可多人同时使用 | 管理员 + 需要命令行的用户 |
| **macOS 屏幕共享**（经 Tailscale） | 每人用自己账号登录**独立的图形会话** | ✅ 可多人同时使用，互相看不到屏幕 | 需要图形界面的用户 |
| **IP KVM**（可选） | 外接硬件，充当显示器和键鼠 | —— | 管理员；方案 B 必需 |

**不要把 UU 账号给朋友用。** 朋友通过 UU 连进来，看到的就是 `console` 的桌面，所有人共用一个会话，等于没有隔离，还会互相抢鼠标。

---

## 3. 现场与硬件

| 项 | 要求 | 原因 |
|---|---|---|
| 网络 | 优先**网线**直连路由器，Wi-Fi 也可以（见下方 3.1）；在路由器上做 DHCP 地址保留 | 网线少一个故障点；不在 Mac 上手动改 IP，避免把自己锁在外面 |
| 智能插座（推荐） | **只接 Mac**；插座的「断电恢复后状态」设为「通电」或「记忆」 | Mac 死机时远程断电再上电，触发自动开机。很多插座默认来电后保持「关」 |
| 路由器 / 光猫 | 确认来电后能自己恢复上网 | 现场整体停电后，网络也要自己回来 |
| UPS（可选） | 给路由器 + Mac 供电 | 扛住短时闪断，减少意外断电次数 |
| IP KVM（方案 B 必需） | 独立供电、独立接网，经 HDMI / USB 连 Mac | 系统起不来或卡在解锁界面时，仍能看到画面、操作键盘 |

交代朋友：**不要按电源键关机，不要拔网线**；需要挪动机器时先告诉你。

### 3.1 只用 Wi-Fi 时

可以用。整套方案不依赖网线，只是多了几个需要注意的地方：

| 项 | 要求 | 原因 |
|---|---|---|
| 开机即联网 | Wi-Fi 密码要在**系统钥匙串**里。用管理员账号在「系统设置 → Wi-Fi」里加入网络时默认就存在这里；`00-preflight` 会检查 | 自动登录之前、SSH 和 Tailscale 系统服务启动时，Wi-Fi 就要能连上 |
| 加密方式（方案 B） | **WPA2 个人版**或开放网络。WPA3 不在 Apple 列出的支持范围内；WPA2/WPA3 混合模式要实测 | 停在 FileVault 解锁界面时，预启动环境只能连这两类 Wi-Fi。连不上就无法用 SSH 远程解锁 |
| SSID / 密码不能改 | 交代朋友：不要改 Wi-Fi 名称和密码，不要换路由器；要改的话先告诉你 | 一改就失联，而且远程修不了 |
| 精简已保存网络 | 只保留现场这一个 Wi-Fi，删掉其他已保存的网络和手机热点 | 防止信号波动时自动跳到别的网络 |
| 信号 | 信号 / 噪声的差值最好在 25 dB 以上（比如 -60 / -90）；`90-verify` 会记录 | 信号弱的话，屏幕共享和 UU 会卡，也容易掉线 |
| 路由器先断电 | Mac 开机比路由器快时，会先找不到网络；macOS 会自动重试，但要实测多久能连回来 | 整体停电恢复后，Mac 和路由器同时上电是最常见的情况 |
| 网络唤醒 | Wi-Fi 下基本不可用 | 本方案主机不睡眠，不依赖这个功能 |

---

## 4. 断电后自动开机

### 4.1 系统设置

系统设置 → 能源：
- 打开「停电后自动启动」
- 打开「显示器关闭时，防止自动进入睡眠」
- 如果是 **2024 年及以后的 Mac mini + macOS 26.5 及以后**：把「接通电源时启动」设为「**始终**」

### 4.2 命令

```sh
sudo pmset -a autorestart 1                  # 断电恢复后自动开机
sudo pmset -a sleep 0 disksleep 0 womp 1     # 系统不睡眠；允许网络唤醒
sudo pmset -a displaysleep 10                # 显示器可以关，主机不睡
sudo pmset -a autorestartatconnect 1 autorestart 0   # 「接入电源时启动 → 始终」（已在 M4 实测）
pmset -g custom                              # 查看结果
```

**已在 M4 Mac mini（macOS 26.5.2）上实测**：系统设置里「接入电源时启动」是三选一。从不 = autorestart 0 + autorestartatconnect 0；断电后 = 1 + 0；**始终 = 0 + 1**（含断电后）。两个都设成 1 时，系统设置会把 autorestart 改回 0。另外，系统设置窗口不会自动刷新，要 ⌘Q 后重新打开才能看到命令改过的值。

### 4.3 注意

- **「断电恢复」和「关机后再通电」是两回事。** 老机型通常只支持前者；正常关机后拔插电源，不一定会开机。「始终」选项只在 2024+ Mac mini、macOS 26.5+ 上有。
- 用插座强制重启时，断电和上电之间**间隔约 30 秒**（Apple 建议），让电源充分放电。
- 正常维护用 `sudo shutdown -r now`，插座断电只作为最后手段。

---

## 5. 账号规划与用户隔离

### 5.1 账号规划

| 账号 | 类型 | 用途 | 自动登录 | 远程入口 |
|---|---|---|---|---|
| `admin_xxx`（你） | 管理员 | 日常维护 | 否 | SSH、屏幕共享 |
| `console` | 标准用户 | 开机自动登录，只运行 UU；**不存放任何数据** | 是（方案 A） | UU（仅你使用） |
| `u_<name>` | 标准用户 | 每个朋友一个 | 否 | 按需开 SSH / 屏幕共享 |

### 5.2 创建

```sh
sudo sysadminctl -addUser console  -fullName "Console" -password -
sudo sysadminctl -addUser u_alice  -fullName "Alice"   -password -
# 不加 -admin 即为标准用户；"-password -" 会提示输入，避免密码出现在命令历史里
sudo sysadminctl -guestAccount off
```

**Secure Token**（只和方案 B 有关）：只有持有 Secure Token 的账号能解锁 FileVault。用户账号**不应该**有解锁权限；管理员账号必须有。可用 `sysadminctl -secureTokenStatus <user>` 检查。

### 5.3 收紧家目录

**实测（M4 Mac mini，macOS 26.5.2）**：新建用户的家目录是 `drwxr-x---`（750，staff 组可读），而默认**所有本地用户的主组都是 `staff`**。所以远程用户能进入管理员的家目录，读取所有组可读的文件；管理员家目录下所有组可读的配置、项目和工具目录都会暴露。

**做法：不动管理员账号，把远程用户移出 staff 组。** 给远程用户建一个专用组（`fleetusers`），作为他们的主组。这样他们对管理员家目录来说就是「其他人」，750 会直接拒绝。远程用户自己的家目录再设成 700，彼此之间也读不到。

```sh
sudo dseditgroup -o create -i 600 -r "mac-fleet remote users" fleetusers
sudo dscl . -create /Users/u_alice PrimaryGroupID 600
sudo chown -R u_alice:fleetusers /Users/u_alice && sudo chmod 700 /Users/u_alice
```

`20-accounts.sh` 会自动完成这些：新建账号时直接放进 `fleetusers`，已有账号则改掉它的主组。

`/Users/Shared` 是所有人可写的公共目录，告诉用户不要往里放私人文件。

### 5.4 无法隔离的部分（要提前告诉朋友）

- **管理员能读所有人的数据。** 这个没办法用技术手段隔离，朋友需要信任管理员。
- CPU、内存、磁盘空间、网络带宽和出口 IP 都是共享的。有人占满资源会影响所有人；有人做违规的事，出口 IP 是同一个。
- APFS 没有简单的按用户磁盘配额，只能靠监控。
- 需要更强的隔离（每人一套独立系统）时，用虚拟机。注意 Apple 许可限制：一台 Mac 同时最多运行 **2 个** macOS 虚拟机；Linux 虚拟机没有这个限制。

---

## 6. 自动登录与锁屏（方案 A）

```sh
fdesetup status                                       # 查看 FileVault 状态
sudo fdesetup disable                                 # 关闭；等解密完成（fdesetup status 会显示进度）
sudo sysadminctl -autologin set -userName console -password -
sudo sysadminctl -autologin status
```

图形界面：系统设置 → 用户与群组 → 「自动以此身份登录」→ `console`。

锁屏有两种做法，选一种，**都要实测**：

1. **保留锁屏，用 UU 自动解锁**（推荐）：UU 手机端 → 操作 → 安全 → 「自动解锁被控端」，录入 `console` 的开机密码。再开启「远程结束后，被控端自动锁屏」。**[待实测]**：锁屏状态下是否真能远程解锁。
2. **关闭 console 的锁屏**：以 `console` 身份执行 `sysadminctl -screenLock off -password -`。因为 console 是空账号，风险可以接受。

---

## 7. 远程入口配置

### 7.1 网络层：Tailscale（不在公网暴露任何端口）

SSH（22）和屏幕共享（5900）**不做路由器端口映射**，只通过 Tailscale 内网访问。

```sh
# 系统服务版：开机即运行，不需要有人登录
brew install --formula tailscale
sudo brew services start tailscale
sudo tailscale up --hostname mm-01
tailscale ip -4
```

- 用 Tailscale ACL 控制谁能连哪台机器的哪个端口。例如给主机打上 `tag:mac-host`，每个朋友只允许访问指定主机的 22 / 5900。
- 朋友有自己的 Tailscale 网络时，也可以用「设备分享」只把这一台机器分享给他。
- **[待实测]**：从中国大陆实际线路访问 Tailscale 的连通性和延迟。不通的话需要自建中继或换方案。
- 不要和 Tailscale 的 App Store / Standalone GUI 版同时安装。

### 7.2 SSH（远程登录）

图形界面：系统设置 → 通用 → 共享 → 远程登录 → 打开，「允许访问」选「仅这些用户」，加入需要的账号。

```sh
sudo systemsetup -setremotelogin on    # [待实测] 新版 macOS 要求终端有「完全磁盘访问权限」
# 「仅这些用户」对应 com.apple.access_ssh 组
sudo dseditgroup -o edit -a admin_xxx -t user com.apple.access_ssh   # [待实测] 增删成员是否立即生效
```

只允许密钥登录：

```sh
# /etc/ssh/sshd_config.d/200-hardening.conf
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
```

本机核对过：macOS 的 `sshd_config` 会 `Include /etc/ssh/sshd_config.d/*`，系统自带一个 `100-macos.conf`，所以自定义文件用更大的编号。

⚠️ 方案 B 依赖「SSH 密码认证解锁 FileVault」。关闭密码登录之前，必须先验证预启动阶段的解锁还能不能用。

### 7.3 macOS 屏幕共享（给需要图形界面的朋友）

图形界面：系统设置 → 通用 → 共享 → 屏幕共享 → 打开，选「仅这些用户」（对应 `com.apple.access_screensharing` 组）。

```sh
# [待实测] 新版本可能必须在系统设置里手动打开
sudo launchctl enable system/com.apple.screensharing
sudo launchctl bootstrap system /System/Library/LaunchDaemons/com.apple.screensharing.plist
```

朋友在自己的 Mac 上打开「屏幕共享」App，连接 `vnc://<tailscale-ip>`，**用自己的账号登录**。

- 已经有其他人在用时，会弹窗让你选「共享显示器」或「登录」。**选「登录」**：使用自己的账号和独立屏幕，互相看不到。
- 高性能模式下，如果以「当前已登录的那个用户」身份连接，机器本身的显示器会被黑屏，其他人也不能同时使用。
- **[待实测]**：同时能撑住几个图形会话；Windows / 非 Apple 的 VNC 客户端能不能用「独立会话」。

### 7.4 UU 远程（管理员的图形救援入口）

以下都在 **`console` 账号**里操作：

1. 安装 UU 远程（`/Applications/UURemote.app`，进程名 `UURemote`），登录**你的** UU 账号。首次登录需要手机验证码，只能人工完成。
2. 系统设置 → 隐私与安全性 → 打开「屏幕与系统音频录制」和「辅助功能」两项权限。**只能人工点击**，脚本授不了。
3. UU 菜单 → 设置中心 → 勾选「**开机自动启动**」和「**防止电脑休眠**」。
4. 手机端 → 安全 → 「自动解锁被控端」、「远程结束后，被控端自动锁屏」（见第 6 节）。
5. 双保险：系统设置 → 通用 → 登录项，也把 UU 远程加进去。
6. 崩溃自动拉起：在 `console` 账号里装一个 LaunchAgent，每 5 分钟检查一次：

```xml
<!-- /Users/console/Library/LaunchAgents/local.uu-watchdog.plist -->
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>local.uu-watchdog</string>
  <key>ProgramArguments</key>
  <array><string>/bin/sh</string><string>-c</string>
    <string>pgrep -xq UURemote || open -a UURemote</string></array>
  <key>RunAtLoad</key><true/>
  <key>StartInterval</key><integer>300</integer>
</dict></plist>
```

```sh
# 以 console 身份加载
launchctl bootstrap gui/$(id -u console) /Users/console/Library/LaunchAgents/local.uu-watchdog.plist
```

---

## 8. 系统加固：别把自己锁在外面

| 项 | 做法 | 原因 |
|---|---|---|
| macOS 自动更新 | 系统设置 → 通用 → 软件更新 → 自动更新：**关闭「安装 macOS 更新」**；「安全响应和系统文件」可以保留 | 大版本更新可能让 UU 的权限失效，或卡在更新界面。更新改为手动、有人看着时做 |
| 防火墙 | 打开；保持「自动允许内建软件」 | 打开后要验证 SSH / 屏幕共享仍然能连 |
| 不用的共享 | 关闭文件共享、AirPlay 接收器、远程 Apple 事件等 | 缩小攻击面 |
| 主机名 | `sudo scutil --set ComputerName mm-01`（`HostName`、`LocalHostName` 同样设置） | N 台机器统一命名，与清单对应 |
| 改网络 / 防火墙 / SSH 配置 | **改之前确认至少还有一条其他入口可用**；改完立刻新开一个连接验证，旧连接不要关 | 防止一次改错就失联 |

---

## 9. 验收清单（朋友在场时完成）

| # | 场景 | 操作 | 期望结果 | 结果 / 用时 |
|---|---|---|---|---|
| 1 | 意外断电 | 拔电源，等 30 秒，插回 | 自动开机 → console 自动登录 → UU 在线；Tailscale 在线；能 SSH 连上 | |
| 2 | 正常重启 | `sudo shutdown -r now` | 同 1 | |
| 3 | 关机后通电 | 正常关机 → 插座断电 30 秒 → 通电 | 2024+ / 26.5+ 机型应自动开机；老机型记录实际表现 | |
| 4 | 插座远程重启 | App 里关插座，30 秒后开 | 同 1 | |
| 5 | UU 崩溃 | `pkill -x UURemote` | 5 分钟内自动拉起 | |
| 6 | 锁屏解锁 | 锁屏后通过 UU 连接 | 能自动解锁（或已按第 6 节关闭锁屏） | |
| 7 | 多人图形会话 | 两个朋友同时用屏幕共享「登录」 | 各自独立桌面，互相看不到 | |
| 8 | 文件隔离 | u_alice 执行 `ls /Users/u_bob` | Permission denied | |
| 9 | 提权 | u_alice 执行 `sudo -v` | 被拒绝 | |
| 10 | 真实线路 | 从你和朋友的实际网络连 UU / SSH / 屏幕共享 | 记录延迟和可用性 | |
| 11 | 网络恢复 | 路由器断电再恢复 | Mac 自动重连，Tailscale 恢复在线 | |
| 12 | 拔掉显示器 | 去掉测试用显示器后重做第 1 项 | 结果不变（无显示器时屏幕共享仍正常） | |

---

## 10. 故障时的升级顺序

```text
UU 连不上 ──▶ 用 SSH 连进去：pgrep UURemote / 以 console 身份 open -a UURemote / sudo shutdown -r now
SSH 也连不上 ──▶ 看 Tailscale 后台机器是否在线 ──▶ 不在线：插座断电 30 秒再通电
插座重启后仍不上线 ──▶（有 KVM 的话）用 KVM 看画面 ──▶ 请朋友到现场：检查网线、电源指示灯、外接显示器看画面
```

---

## 11. 走向 N 台：自动化边界与 SOP 结构

### 11.1 哪些能写成脚本

| 能用脚本完成 | 只能人工 | 需要 MDM 才能统一管理 |
|---|---|---|
| pmset 电源设置、主机名 | 开机向导、首个管理员账号 | 强制配置描述文件（防止被改回去） |
| 创建账号、收紧家目录权限、关闭访客 | UU 首次登录（手机验证码） | 预先授权「辅助功能」等隐私权限（PPPC 描述文件） |
| 自动登录、关闭 FileVault | **屏幕录制权限**（MDM 也无法静默授予，最多允许标准用户自己批准） | 统一管控系统更新 |
| sshd 配置、SSH 访问组 | 部分版本中打开屏幕共享 / 远程登录 `[待实测]` | |
| 安装 Tailscale 并启动服务（`tailscale up` 可用 auth key） | 智能插座、路由器设置 | |
| UU 守护 LaunchAgent、防火墙 | 方案 B 的 FileVault 恢复密钥保管 | |
| **巡检脚本**（输出每台机器的状态报告） | 第 9 节的物理验收 | |

结论：Shell 脚本能覆盖大约 70% 的工作，剩下的人工步骤做成**每台机器的勾选清单**。机器超过 5–10 台，或需要防止配置被改动时，再评估 MDM（Apple Business Manager + MDM 服务）。

> 脚本实现见本仓库 `scripts/`、`bootstrap.sh`、`client/` 与 `docs/SOP.md`。

### 11.2 建议的仓库结构

```text
mac-fleet/
├── docs/
│   └── mac-mini-remote-host-guide.md     # 本文
├── inventory/
│   └── hosts.csv                          # 主机名、序列号、型号、系统版本、场地、Tailscale IP、方案 A/B、用户列表（不含密码）
├── scripts/
│   ├── lib.sh                             # 日志、check/apply/verify 公共函数、--dry-run
│   ├── 00-preflight.sh                    # 检查机型、芯片、系统版本、FileVault、网络；不满足条件就退出
│   ├── 10-power.sh                        # 第 4 节
│   ├── 20-accounts.sh                     # 第 5 节
│   ├── 30-tailscale.sh                    # 第 7.1 节
│   ├── 40-remote-access.sh                # 第 7.2、7.3 节
│   ├── 50-console-uu.sh                   # 第 6、7.4 节中能自动化的部分
│   ├── 60-hardening.sh                    # 第 8 节
│   └── 90-verify.sh                       # 只读巡检，输出 JSON
├── checklists/
│   └── manual-steps.md                    # 人工步骤 + 第 9 节验收表
└── bootstrap.sh                           # 在目标机上按顺序执行，或在管理端通过 ssh 推送执行
```

### 11.3 脚本约定

- **幂等**：每一步按「检查 → 不符合才修改 → 再验证」执行，可以重复跑。
- **`--dry-run`**：只打印将要做的修改，不实际执行。
- **密码和密钥不进仓库，也不进命令行参数**：用 `-password -` 交互输入，或从 1Password CLI / 钥匙串读取。Tailscale auth key 用短期、一次性的。
- **危险操作单独确认**：`fdesetup disable`、sshd 配置、防火墙这几项在脚本里需要二次确认。sshd 改完先用 `sshd -t` 校验，再新开连接验证。
- **巡检脚本 `90-verify.sh`** 至少输出以下字段：机型、系统版本、`autorestart`、`autorestartatconnect`、FileVault 状态、自动登录用户、sshd / 屏幕共享 / Tailscale 状态、UURemote 进程、管理员组成员、各家目录权限。N 台机器的状态汇总就靠它。

---

## 12. 待实测问题（第一台机器上逐项关闭）

1. ~~`pmset autorestartatconnect` 是否对应「接通电源时启动 → 始终」~~ ✅ 已确认：始终 = autorestart 0 + autorestartatconnect 1（见第 4.2 节）。
2. 目标机型与系统版本下，「正常关机后再通电」的实际表现。
3. `systemsetup -setremotelogin on`、屏幕共享的 `launchctl` 启用方式在 macOS 26 上是否可用。
4. 修改 `com.apple.access_ssh` / `access_screensharing` 组成员是否立即生效。
5. UU「自动解锁被控端」在 macOS 26 锁屏状态下是否可用。
6. UU 所需的 macOS 权限清单（官方文档未写，目前按屏幕录制 + 辅助功能处理）。
7. 屏幕共享能同时支撑几个图形会话；非 Apple 客户端的表现。
8. 从中国大陆真实线路访问 Tailscale、UU 的连通性和延迟。
9. 防火墙开启后，SSH 和屏幕共享是否需要单独放行。
10. 关闭自动更新的配置项在 macOS 26 上的实际名称（系统设置与 `defaults` 两种方式）。
11. 只用 Wi-Fi 时：方案 B 的预启动 SSH 解锁能否通过 Wi-Fi 完成；路由器和 Mac 同时断电再上电后，Mac 多久能重新连上 Wi-Fi。

---

## 参考资料

- Apple：[Start up when power is connected（2024+ Mac mini，macOS 26.5+）](https://support.apple.com/en-us/125517)
- Apple：[Share the screen of another Mac（并发登录不同用户）](https://support.apple.com/guide/mac-help/share-the-screen-of-another-mac-mh14066/mac)
- Apple：[Screen sharing type options（高性能模式）](https://support.apple.com/guide/mac-help/screen-sharing-type-options-on-mac-mchl1883115d/mac)
- Apple：[Intro to FileVault（Apple Silicon SSH 预启动解锁）](https://support.apple.com/guide/deployment/intro-to-filevault-dep82064ec40/web)
- Tailscale：[tailscaled on macOS](https://github.com/tailscale/tailscale/wiki/Tailscaled-on-macOS)
- 网易 UU 远程：[如何实现 UU 远程全自动](https://uuyc.163.com/blog/guide-auto-20250527.html)
- 网易 UU 远程：[Mac 端防窥锁屏等功能](https://uuyc.163.com/blog/20260821-shemeibangyun.html)
- 本机核对：`man pmset`、`sysadminctl` 用法、`/etc/ssh/sshd_config` 的 Include 机制、家目录默认权限（macOS 26.6.2）
