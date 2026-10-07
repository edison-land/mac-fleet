#!/bin/bash
# mac-fleet 服务端一键接入：把一台 Mac mini 配成「断电自启 + UU 救援 + Tailscale SSH」主机。
#
# 用法（在 Mac mini 的管理员账号里，解压后进入目录执行）：
#   sudo TS_AUTHKEY=tskey-auth-… bash bootstrap.sh
#   可选：HOST_NAME=mm-us-01（默认取序列号后 6 位）  FILEVAULT_PLAN=B（默认 A）  BOOTSTRAP_YES=1（跳过开头确认）
#
# 需要人工的地方（macOS 限制，脚本做不了）：
#   1. sudo 密码
#   2. 关闭 FileVault 时输入管理员账号和密码（只有 FileVault 开着时才会问）
#   3. UU 首次登录与「屏幕录制」「辅助功能」授权——由管理员事后经 Tailscale 屏幕共享远程完成，现场不用管

set -u
SRC="$(cd "$(dirname "$0")" && pwd)"
INSTALL="/usr/local/mac-fleet"

# 管理员用 admin/make-package.sh 生成的专属包里带有 config/site.env（主机名 + 认证密钥）
SITE_ENV="$SRC/config/site.env"
if [ -f "$SITE_ENV" ]; then
	# shellcheck source=/dev/null
	. "$SITE_ENV"
	export HOST_NAME TS_AUTHKEY
fi

# 预演：bash bootstrap.sh --check（不用 sudo，不做任何修改，逐步打印将要做的事）
if [ "${1:-}" = "--check" ]; then
	cd "$SRC" || exit 2
	for s in 00-preflight 55-filevault 10-power 20-accounts 30-remote-access 40-tailscale 60-hardening 50-console-uu; do
		printf '\n######## %s（预演）########\n' "$s"
		bash "scripts/$s.sh" 2>&1 | grep -E '^(\[(PLAN|FAIL|WARN)\]|== 汇总)'
	done
	exit 0
fi

if [ "$(id -u)" -ne 0 ]; then echo "请用 sudo 运行：sudo bash bootstrap.sh"; exit 2; fi
if [ -z "${SUDO_USER:-}" ] || [ "$SUDO_USER" = "root" ]; then echo "请在管理员账号里用 sudo 运行，不要直接以 root 登录"; exit 2; fi

# 装到固定位置，以后可以经 SSH 远程重跑：sudo bash /usr/local/mac-fleet/scripts/90-verify.sh
if [ "$SRC" != "$INSTALL" ]; then
	mkdir -p "$INSTALL"
	rsync -a --exclude logs --exclude state --exclude 'config/host.conf' --exclude 'config/site.env' "$SRC/" "$INSTALL/"
	chown -R root:wheel "$INSTALL"
	chmod -R go-w "$INSTALL"
fi
cd "$INSTALL" || exit 2

# 读一次默认值，用于开头的说明
# shellcheck source=config/defaults.sh
. "$INSTALL/config/defaults.sh"
export HOST_NAME FILEVAULT_PLAN
TS_HOSTNAME="${TS_HOSTNAME:-$(echo "$HOST_NAME" | tr '[:upper:]' '[:lower:]')}"

tty_say() { printf '%s\n' "$*" >/dev/tty; }

# ---- 前置：Homebrew（安装 Tailscale 和 UU 需要） ----
if [ ! -x /opt/homebrew/bin/brew ]; then
	tty_say "这台 Mac 还没有 Homebrew。请先在管理员账号里（不要 sudo）执行下面这条，装完再重新运行本脚本："
	# shellcheck disable=SC2016  # 原样打印给用户复制，不在这里展开
	tty_say '  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
	exit 2
fi

# ---- 开头一次性确认 ----
fv_now="$(fdesetup status 2>/dev/null | head -1)"
tty_say ""
tty_say "================ mac-fleet 服务端接入 ================"
tty_say "主机名：${HOST_NAME}（Tailscale 中显示为 ${TS_HOSTNAME}）"
tty_say "管理员：$SUDO_USER"
tty_say "FileVault 方案：${FILEVAULT_PLAN}（当前：${fv_now}）"
if [ "$FILEVAULT_PLAN" = "A" ]; then
	tty_say "  → 会关闭 FileVault，开机自动登录空的标准账号 console，断电恢复后 UU 与 Tailscale 全自动上线"
fi
tty_say "Tailscale：$([ -n "${TS_AUTHKEY:-}" ] && echo "使用传入的认证密钥加入" || echo "没有传入密钥，加入时会显示二维码，需用管理员账号扫码批准")"
tty_say "将依次执行：预检 → FileVault → 电源 → 账号 → 系统 SSH/屏幕共享 → Tailscale → 加固 → console 与 UU → 巡检"
tty_say "====================================================="
if [ "${BOOTSTRAP_YES:-0}" != "1" ]; then
	printf '输入 yes 开始：' >/dev/tty
	read -r ans </dev/tty
	[ "$ans" = "yes" ] || { tty_say "已取消"; exit 1; }
fi

# 没有专属包、命令里也没给密钥时，在这里问一次
if [ -z "${TS_AUTHKEY:-}" ]; then
	printf '粘贴管理员发给你的认证密钥（tskey-auth-…，输入时不显示）；没有就直接按回车，稍后扫码：' >/dev/tty
	read -rs TS_AUTHKEY </dev/tty
	printf '\n' >/dev/tty
fi

# console 的密码：由这里生成，账号创建和自动登录都用它，结束时显示一次（不进日志）
if ! dscl . -read /Users/"$CONSOLE_USER" UniqueID >/dev/null 2>&1; then
	CONSOLE_PASSWORD="$(LC_ALL=C tr -dc 'A-HJ-NP-Za-km-z2-9' </dev/urandom | head -c 20)"
	export CONSOLE_PASSWORD
	NEW_CONSOLE=1
else
	NEW_CONSOLE=0
fi
export TS_AUTHKEY="${TS_AUTHKEY:-}"

FAILED=""
run() {
	local name="$1"
	shift
	printf '\n\n######## %s ########\n' "$name"
	bash "scripts/$name.sh" "$@" || FAILED="$FAILED $name"
}

run 00-preflight
case "$FAILED" in *00-preflight*)
	tty_say ""
	tty_say "预检没有通过（见上面的 [FAIL]）。确认要继续的话，用 BOOTSTRAP_FORCE=1 重新运行"
	[ "${BOOTSTRAP_FORCE:-0}" = "1" ] || exit 1
	;;
esac
run 55-filevault --apply --yes
run 10-power --apply --yes
run 20-accounts --apply --yes
run 30-remote-access --apply --yes
run 40-tailscale --apply --yes
run 60-hardening --apply --yes
run 50-console-uu --apply --yes
printf '\n\n######## 90-verify ########\n'
bash scripts/90-verify.sh   # 巡检结果不计入失败：console 自动登录、UU 在线要等重启和远程配置 UU 之后才会 PASS

# 认证密钥是一次性的，用过就删掉包里的副本
[ -f "$SITE_ENV" ] && rm -f "$SITE_ENV"

# ---- 结束说明（只显示在终端） ----
TS_CLI=/opt/homebrew/bin/tailscale
ts_name="$("$TS_CLI" status --json 2>/dev/null | plutil -extract Self.DNSName raw - 2>/dev/null)"
ts_ip="$("$TS_CLI" ip -4 2>/dev/null | head -1)"
tty_say ""
tty_say "==================== 完成 ===================="
tty_say "Tailscale：${ts_name:-未加入} ${ts_ip}"
[ -n "$FAILED" ] && tty_say "有问题的步骤：${FAILED}（见上方 [FAIL]，修好后可以直接重跑本脚本，已完成的会自动跳过）"
tty_say "巡检里「console 自动登录」「UU 在运行」两项，要等重启并远程配好 UU 之后才会通过，现在 FAIL 属正常"
if [ "$NEW_CONSOLE" = "1" ]; then
	tty_say ""
	tty_say "console 账号密码（只显示这一次，请立刻存进密码管理器）：$CONSOLE_PASSWORD"
fi
tty_say ""
tty_say "现场的工作到此结束。接下来由管理员远程完成 UU："
tty_say "  1. 在管理员电脑上：open vnc://${ts_name%.}  （以 console 和上面的密码登录屏幕共享）"
tty_say "  2. 打开 UU 远程 → 登录 UU 账号 → 授权「屏幕与系统音频录制」「辅助功能」→ 设置中心勾选「开机自动启动」「防止电脑休眠」"
tty_say "=============================================="
