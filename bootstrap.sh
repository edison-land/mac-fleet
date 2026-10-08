#!/bin/bash
# mac-fleet 服务端一键接入：把一台 Mac mini 配成「断电自启 + UU 救援 + Tailscale SSH」主机。
# 可以反复执行：已经完成的项会自动跳过，缺什么补什么（包括自动安装 Homebrew）。
#
# 推荐用 install.sh 下载并启动（见 docs/SOP.md）；也可以解压后在目录里执行：
#   sudo HOST_NAME=mm-us-01 bash bootstrap.sh
#   可选：TS_AUTHKEY=tskey-auth-…（不传则执行时提示粘贴）  FILEVAULT_PLAN=B（默认 A）  BOOTSTRAP_YES=1（跳过开头确认）
#   预演（只读）：bash bootstrap.sh --check
#
# 需要人工的地方（macOS 限制）：sudo 密码；方案 A 首次执行时输一次管理员密码；
# FileVault 开着时，关闭它要再输一次账号和密码；UU 的首次登录和授权（结束时会列出）。

set -u
SRC="$(cd "$(dirname "$0")" && pwd)"
INSTALL="/usr/local/mac-fleet"
BREW_BIN="/opt/homebrew/bin/brew"
TS_CLI="/opt/homebrew/bin/tailscale"

if [ -t 1 ]; then R=$'\033[1;31m' G=$'\033[32m' B=$'\033[1m' N=$'\033[0m'; else R="" G="" B="" N=""; fi
say() { printf '%s\n' "$*" >/dev/tty; }
say_red() { printf '%s%s%s\n' "$R" "$*" "$N" >/dev/tty; }

# 管理员用 admin/make-package.sh 生成的专属包里带有 config/site.env（主机名 + 认证密钥）
SITE_ENV="$SRC/config/site.env"
if [ -f "$SITE_ENV" ]; then
	# shellcheck source=/dev/null
	. "$SITE_ENV"
	export HOST_NAME TS_AUTHKEY
fi

# ---------- 预演：只读，逐步打印将要做的事 ----------
if [ "${1:-}" = "--check" ]; then
	cd "$SRC" || exit 2
	[ -x "$BREW_BIN" ] || say_red "[注意] 没有 Homebrew：正式执行时会自动安装（需要几分钟）"
	for s in 00-preflight 55-filevault 10-power 20-accounts 30-remote-access 40-tailscale 60-hardening 50-uu; do
		printf '\n%s######## %s（预演）########%s\n' "$B" "$s" "$N"
		FLEET_COLOR=1 bash "scripts/$s.sh" 2>&1 | grep -E $'^(\033\\[[0-9;]*m)*(\\[(PLAN|FAIL|WARN|TODO)\\]|== 汇总)'
	done
	exit 0
fi

if [ "$(id -u)" -ne 0 ]; then echo "请用 sudo 运行：sudo bash bootstrap.sh"; exit 2; fi
if [ -z "${SUDO_USER:-}" ] || [ "$SUDO_USER" = "root" ]; then echo "请在管理员账号里用 sudo 运行，不要直接以 root 登录"; exit 2; fi
if ! dsmemberutil checkmembership -U "$SUDO_USER" -G admin 2>/dev/null | grep -q "is a member"; then
	say_red "$SUDO_USER 不是管理员：请用这台 Mac 的管理员账号执行"
	exit 2
fi

# 装到固定位置，以后可以经 SSH 远程重跑：sudo bash /usr/local/mac-fleet/scripts/90-verify.sh
if [ "$SRC" != "$INSTALL" ]; then
	mkdir -p "$INSTALL"
	rsync -a --exclude logs --exclude state --exclude 'config/host.conf' --exclude 'config/site.env' "$SRC/" "$INSTALL/"
	chown -R root:wheel "$INSTALL"
	chmod -R go-w "$INSTALL"
fi
cd "$INSTALL" || exit 2

# shellcheck source=config/defaults.sh
. "$INSTALL/config/defaults.sh"
export HOST_NAME FILEVAULT_PLAN
TS_HOSTNAME="${TS_HOSTNAME:-$(echo "$HOST_NAME" | tr '[:upper:]' '[:lower:]')}"

ts_state() { [ -x "$TS_CLI" ] && "$TS_CLI" status --json 2>/dev/null | plutil -extract BackendState raw - 2>/dev/null; }
screenlock_now() { sudo -u "$SUDO_USER" sysadminctl -screenLock status 2>&1 | sed -n 's/.*screenLock delay is \(.*\)$/\1/p'; }
autologin_now() { defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>/dev/null; }

# ---------- 开头一次性确认 ----------
fv_now="$(fdesetup status 2>/dev/null | head -1)"
say ""
say "${B}================ mac-fleet 服务端接入 ================${N}"
say "主机名：${HOST_NAME}（Tailscale 中显示为 ${TS_HOSTNAME}）"
say "管理员：$SUDO_USER"
say "FileVault 方案：${FILEVAULT_PLAN}（当前：${fv_now}）"
if [ "$FILEVAULT_PLAN" = "A" ]; then
	say_red "  → 方案 A：关闭 FileVault，开机自动登录管理员 ${SUDO_USER}（显示器关闭后立即锁屏），断电恢复后 UU 与 Tailscale 全自动上线"
fi
[ -x "$BREW_BIN" ] || say_red "  → 没有 Homebrew：会先自动安装（可能还会安装 Xcode 命令行工具，需要几分钟到十几分钟）"
if [ "$(ts_state)" = "Running" ]; then
	say "Tailscale：已在网络中，跳过加入"
elif [ -n "${TS_AUTHKEY:-}" ]; then
	say "Tailscale：使用传入的认证密钥加入"
else
	say "Tailscale：还没加入，稍后提示粘贴认证密钥（直接回车则显示二维码扫码）"
fi
say "将依次执行：预检 → FileVault → 电源 → 账号 → 系统 SSH/屏幕共享 → Tailscale → 加固 → UU 与自动登录 → 巡检"
say "${B}=====================================================${N}"
if [ "${BOOTSTRAP_YES:-0}" != "1" ]; then
	printf '输入 yes 开始：' >/dev/tty
	read -r ans </dev/tty
	[ "$ans" = "yes" ] || { say "已取消"; exit 1; }
fi

# ---------- 需要的输入：只在还没完成时才问 ----------
if [ "$(ts_state)" != "Running" ] && [ -z "${TS_AUTHKEY:-}" ]; then
	printf '粘贴认证密钥（tskey-auth-…，输入时不显示）；没有就直接按回车，稍后扫码：' >/dev/tty
	read -rs TS_AUTHKEY </dev/tty
	printf '\n' >/dev/tty
fi
export TS_AUTHKEY="${TS_AUTHKEY:-}"

# 方案 A 用管理员密码写入自动登录凭据、开启锁屏；两项都已完成就不再问
if [ "$FILEVAULT_PLAN" = "A" ] && [ -z "${ADMIN_PASSWORD:-}" ]; then
	case "$(screenlock_now)" in *immediate* | "0 seconds") sl_ok=1 ;; *) sl_ok=0 ;; esac
	if [ "$(autologin_now)" != "$SUDO_USER" ] || [ "$sl_ok" = "0" ]; then
		while :; do
			printf '输入管理员 %s 的登录密码（用于开机自动登录和锁屏，输入时不显示）：' "$SUDO_USER" >/dev/tty
			read -rs ADMIN_PASSWORD </dev/tty
			printf '\n' >/dev/tty
			dscl . -authonly "$SUDO_USER" "$ADMIN_PASSWORD" >/dev/null 2>&1 && break
			say_red "密码不对，重新输入"
		done
		export ADMIN_PASSWORD
	fi
fi

# ---------- 前置：Homebrew（安装 Tailscale、UU 需要） ----------
# Homebrew 的安装器必须以普通用户运行，并且要能免密 sudo；安装期间临时给管理员加一条免密授权，装完立即删除
BREW_SUDOERS="/etc/sudoers.d/zz-mac-fleet-brew"
cleanup_sudoers() { rm -f "$BREW_SUDOERS"; }
trap cleanup_sudoers EXIT
trap 'cleanup_sudoers; exit 130' INT TERM
if [ ! -x "$BREW_BIN" ]; then
	printf '\n%s######## 安装 Homebrew ########%s\n' "$B" "$N"
	printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$SUDO_USER" >"$BREW_SUDOERS"
	chmod 440 "$BREW_SUDOERS"
	if visudo -cf "$BREW_SUDOERS" >/dev/null; then
		HB_URL="https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh"
		sudo -u "$SUDO_USER" -H env NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL "$HB_URL")"
	fi
	cleanup_sudoers
	if [ -x "$BREW_BIN" ]; then
		say "${G}[PASS]${N} Homebrew 安装完成"
	else
		say_red "[FAIL] Homebrew 安装失败（见上面的输出）。检查网络后重新运行本命令即可，已完成的步骤会跳过"
		exit 1
	fi
fi

# ---------- 逐步执行 ----------
ATTN="$(mktemp)"
export FLEET_ATTENTION_FILE="$ATTN"
FAILED=""
run() {
	local name="$1"
	shift
	printf '\n\n%s######## %s ########%s\n' "$B" "$name" "$N"
	bash "scripts/$name.sh" "$@" || FAILED="$FAILED $name"
}

run 00-preflight
case "$FAILED" in *00-preflight*)
	say_red "预检没有通过（见上面红色的 [FAIL]）。确认要继续的话，用 BOOTSTRAP_FORCE=1 重新运行"
	[ "${BOOTSTRAP_FORCE:-0}" = "1" ] || exit 1
	;;
esac
run 55-filevault --apply --yes
run 10-power --apply --yes
run 20-accounts --apply --yes
run 30-remote-access --apply --yes
run 40-tailscale --apply --yes
run 60-hardening --apply --yes
run 50-uu --apply --yes
printf '\n\n%s######## 90-verify ########%s\n' "$B" "$N"
FLEET_ATTENTION_FILE="" bash scripts/90-verify.sh

# 认证密钥是一次性的，用过就删掉包里的副本
[ -f "$SITE_ENV" ] && rm -f "$SITE_ENV"

# ---------- 结束：需要注意的事项（红字） ----------
ts_name="$("$TS_CLI" status --json 2>/dev/null | plutil -extract Self.DNSName raw - 2>/dev/null)"
ts_ip="$("$TS_CLI" ip -4 2>/dev/null | head -1)"
say ""
say "${B}==================== 完成 ====================${N}"
say "Tailscale：${ts_name:-未加入} ${ts_ip}"
[ -n "$FAILED" ] && say_red "有问题的步骤：${FAILED}。修好后直接重新运行同一条命令，已完成的会自动跳过"
if [ -s "$ATTN" ]; then
	say ""
	say_red "需要你注意 / 处理的事项："
	awk '!seen[$0]++' "$ATTN" | while IFS= read -r l; do say_red "  • $l"; done
fi
rm -f "$ATTN"
say ""
say "UU 只需配置一次（在 ${SUDO_USER} 的桌面里；可以本机操作，也可以在管理员电脑上 open vnc://${ts_name%.} 远程登录 ${SUDO_USER}）："
say "  1. 打开 UU 远程 → 登录 UU 账号"
say "  2. 授权「屏幕与系统音频录制」「辅助功能」，然后重启 UU"
say "  3. UU → 设置中心：勾选「开机自动启动」「防止电脑休眠」，安全里打开「允许本设备被控」"
[ "$FILEVAULT_PLAN" = "A" ] && say "  4. 手机 UU → 安全：开启「自动解锁被控端」（录入 ${SUDO_USER} 的密码），锁屏时也能远程进入"
say "${B}==============================================${N}"
