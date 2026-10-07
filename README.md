# mac-fleet

把 M4 及以后的 Mac mini 配置成「断电自动恢复 + 多人远程使用」的主机，并能复制到 N 台机器。

- **接入 SOP（先看这个）**：[docs/SOP.md](docs/SOP.md)
- 管理员生成专属包：`bash admin/make-package.sh mm-us-01`（包内含主机名和一次性密钥）
- 服务端一条命令：`cd ~/Downloads && ditto -x -k mac-fleet-mm-us-01.zip . && cd mac-fleet && sudo bash bootstrap.sh`（预演：`bash bootstrap.sh --check`）
- 客户端一条命令：`bash client/connect-mac.sh <网络名> u_alice@mm-us-01`
- 方案与注意事项：[docs/mac-mini-remote-host-guide.md](docs/mac-mini-remote-host-guide.md)

## 用法

```sh
cp config/host.conf.example config/host.conf   # 每台机器一份，按注释填写
bash scripts/00-preflight.sh                    # 只读预检，并记录回滚基准
bash scripts/10-power.sh                        # 检查模式：只打印 [PLAN]
sudo bash scripts/10-power.sh --apply           # 确认后执行
# 依次执行 20 → 30 → 60 → 50 → (55) → 90
```

| 脚本 | 作用 | 需要人工 |
|---|---|---|
| `00-preflight` | 机型/系统/网络/UU 预检，记录当前设置 | — |
| `10-power` | 断电后自动开机、接通电源时开机、主机不睡眠；`--probe` 探测系统设置对应的 pmset 键 | 系统设置中确认 |
| `20-accounts` | 创建 console 与远程用户（标准账号），关闭访客，家目录 700 | `PASSWORD_MODE`：shared 只输一次；generate 零输入、随机密码在终端显示一次；prompt 逐个输入 |
| `30-remote-access` | SSH、屏幕共享，「仅这些用户」访问组，sshd 加固，管理员公钥 | 命令开不了时在系统设置中手动打开 |
| `50-console-uu` | UU 守护任务；方案 A 自动登录 console / 方案 B 关闭自动登录 | 在 console 里登录 UU、授权 |
| `55-filevault` | 按方案关闭（A）或开启（B）FileVault | 输入密码、保存恢复密钥 |
| `60-hardening` | 主机名、关闭自动安装 macOS 更新、防火墙 | 系统设置中确认 |
| `90-verify` | 只读巡检，逐项 PASS/FAIL，输出 JSON | — |
| `99-rollback` | 按最早的备份恢复本工具改过的设置；`--remove-users` 删除新建账号 | — |

## 约定

- 默认是检查模式，不改任何东西；`--apply` 才执行，并且需要 sudo。
- 可以重复运行：已经符合要求的项直接 PASS，不会重复修改。
- 兼容 macOS 自带的 bash 3.2。变量后面紧跟中文时必须写成 `${var}`，否则 bash 3.2 会把中文字符当成变量名的一部分。
- 密码和 FileVault 恢复密钥只在终端里输入或显示，不写进日志，也不写进配置。
- `logs/`、`state/` 是运行产物，不提交到仓库。
