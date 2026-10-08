#!/bin/bash
# 50 UU 与自动登录：UU 装在管理员账号里运行（实测：UU 只在安装它的管理员账号里能正常被控）。
#   方案 A：开机自动登录管理员 → UU 自动上线；显示器关闭后立即锁屏，现场的人只能看到锁屏。
#   方案 B：不自动登录；断电后经 Tailscale 屏幕共享连到登录界面，远程登录管理员后 UU 才上线。
# 用法：bash scripts/50-uu.sh  →  sudo bash scripts/50-uu.sh --apply  [--plan=A]
# 方案 A 需要管理员密码（写入自动登录凭据、开启锁屏）：bootstrap 会事先问一次并通过 ADMIN_PASSWORD 传入；
# 单独运行时会在终端提示输入。UU 的登录、屏幕录制/辅助功能授权只能人工完成，脚本最后会列出清单。

# shellcheck disable=SC2015  # pass/fail 恒返回 0
. "$(dirname "$0")/lib.sh"
fleet_init "$@"
require_backup

ADMIN_HOME="$(user_home "$ADMIN_USER")"
WD="$ADMIN_HOME/Library/LaunchAgents/${WATCHDOG_LABEL}.plist"

admin_password() {
	if [ -z "${ADMIN_PASSWORD:-}" ]; then
		printf '输入管理员 %s 的登录密码（用于自动登录和锁屏设置，输入时不显示）：' "$ADMIN_USER" >/dev/tty
		read -rs ADMIN_PASSWORD </dev/tty
		printf '\n' >/dev/tty
	fi
	dscl . -authonly "$ADMIN_USER" "$ADMIN_PASSWORD" >/dev/null 2>&1 || { echo "  密码不对"; return 1; }
}

render_watchdog() {
	# 只检查本账号自己的 UU 进程（-U 当前 uid）
	cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${WATCHDOG_LABEL}</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/sh</string>
		<string>-c</string>
		<string>pgrep -xq -U "\$(id -u)" ${UU_PROC} || open -a "${UU_APP}"</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>StartInterval</key>
	<integer>${WATCHDOG_INTERVAL}</integer>
	<key>LimitLoadToSessionType</key>
	<string>Aqua</string>
</dict>
</plist>
EOF
}

install_watchdog() {
	local src="$1" uid
	mkdir -p "$(dirname "$WD")"
	install -m 644 -o "$ADMIN_USER" -g staff "$src" "$WD"
	plutil -lint "$WD" >/dev/null || return 1
	uid="$(user_uid "$ADMIN_USER")"
	if launchctl print "gui/$uid" >/dev/null 2>&1; then
		launchctl bootout "gui/$uid/$WATCHDOG_LABEL" 2>/dev/null
		launchctl bootstrap "gui/$uid" "$WD"
	fi
	return 0
}

install_uu() { sudo -u "$ADMIN_USER" -H env HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_ENV_HINTS=1 "$BREW" install --quiet --cask "$UU_CASK"; }

# sysadminctl 的返回值不可靠，设置后以实际状态判断成败
set_autologin() {
	admin_password || return 1
	sysadminctl -autologin set -userName "$ADMIN_USER" -password "$ADMIN_PASSWORD" >/dev/null 2>&1
	[ "$(autologin_user)" = "$ADMIN_USER" ]
}

# 显示器关闭（或屏保）后立即要求密码；sysadminctl 要以该用户身份、提供其密码
set_screenlock() {
	admin_password || return 1
	as_admin sysadminctl -screenLock immediate -password "$ADMIN_PASSWORD" >/dev/null 2>&1
	case "$(screenlock_state)" in *immediate* | 0 | "0 seconds") return 0 ;; *) return 1 ;; esac
}
screenlock_state() { as_admin sysadminctl -screenLock status 2>&1 | sed -n 's/.*screenLock delay is \(.*\)$/\1/p; s/.*[Ss]creen[Ll]ock is \(.*\)$/\1/p' | head -1; }

step "UU 远程"
if [ -d "$UU_APP" ]; then
	pass "UU 已安装：$UU_APP"
elif [ -x "$BREW" ]; then
	change "用 Homebrew 安装 UU 远程（brew install --cask ${UU_CASK}）" install_uu
	[ "$MODE" = "apply" ] && { [ -d "$UU_APP" ] && pass "UU 安装完成" || fail "UU 安装失败：到 https://uuyc.163.com 手动下载"; }
else
	fail "未安装 UU，也没有 Homebrew：到 https://uuyc.163.com 手动下载安装"
fi

step "UU 守护任务（管理员账号的 LaunchAgent：登录时启动 UU，崩溃后 ${WATCHDOG_INTERVAL}s 内拉起）"
tmp="$(mktemp)"
render_watchdog >"$tmp"
if [ -f "$WD" ] && cmp -s "$tmp" "$WD"; then
	pass "守护任务已是最新：$WD"
else
	change "安装守护任务 $WD" install_watchdog "$tmp"
fi
rm -f "$tmp"

step "自动登录（方案 ${FILEVAULT_PLAN}）"
cur="$(autologin_user)"
if [ "$FILEVAULT_PLAN" = "A" ]; then
	if ! fv_is_off; then
		fail "方案 A 需要先关闭 FileVault（当前：$(fv_status)）：先运行 55-filevault.sh --apply --plan=A"
	elif [ "$cur" = "$ADMIN_USER" ]; then
		pass "开机自动登录 $ADMIN_USER"
	else
		change "设置开机自动登录 ${ADMIN_USER}（当前：${cur:-无}）" set_autologin && [ "$MODE" = "apply" ] && pass "自动登录已设为 $ADMIN_USER"
	fi
	step "锁屏（自动登录后，显示器关闭即锁定，现场的人只能看到锁屏）"
	ls_now="$(screenlock_state)"
	case "$ls_now" in
	*immediate* | 0 | "0 seconds") pass "显示器关闭后立即锁屏（${ls_now}）" ;;
	*)
		change "设置显示器关闭后立即锁屏（当前：${ls_now:-未知}）" set_screenlock && [ "$MODE" = "apply" ] && pass "已设为显示器关闭后立即锁屏"
		;;
	esac
	info "UU 手机端 → 安全：开启「自动解锁被控端」（录入 $ADMIN_USER 的密码），锁屏时也能远程进入"
else
	if [ -z "$cur" ]; then
		pass "方案 B：不自动登录（断电后经 Tailscale 屏幕共享远程登录）"
	else
		change "方案 B：关闭自动登录（当前：${cur}）" sysadminctl -autologin off
	fi
fi

step "UU 需要在 $ADMIN_USER 的桌面里手动完成（只做一次）"
info "1. 打开 UU 远程，登录你的 UU 账号"
info "2. 系统设置 → 隐私与安全性：「屏幕与系统音频录制」「辅助功能」里打开 UU 远程，然后重启 UU"
info "3. UU → 设置中心：勾选「开机自动启动」「防止电脑休眠」，安全里打开「允许本设备被控」"
info "4. 用手机 UU 连进来，确认能看到画面、能操作"

summary
