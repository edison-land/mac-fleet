#!/bin/bash
# shellcheck disable=SC2015  # pass/fail/warn 恒返回 0，A && B || C 在这里等价于 if-else
# 50 console 账号与 UU：安装 UU 守护任务；按方案设置自动登录（A＝自动登录 console，B＝关闭自动登录）。
# 用法：bash scripts/50-console-uu.sh  →  sudo bash scripts/50-console-uu.sh --apply  [--plan=A]
# UU 的登录、屏幕录制/辅助功能授权只能人工完成，脚本最后会列出清单。

. "$(dirname "$0")/lib.sh"
fleet_init "$@"
require_backup

render_watchdog() {
	# 只检查 console 自己的 UU 进程（-U 当前 uid），日常账号里的 UU 不算数
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
	local src="$1" dst="$2" uid
	mkdir -p "$(dirname "$dst")"
	chown "$CONSOLE_USER":staff "$(dirname "$dst")"
	install -m 644 -o "$CONSOLE_USER" -g staff "$src" "$dst"
	plutil -lint "$dst" >/dev/null || return 1
	uid="$(user_uid "$CONSOLE_USER")"
	# console 正在登录时立即加载；否则下次登录时由 launchd 自动加载
	if launchctl print "gui/$uid" >/dev/null 2>&1; then
		launchctl bootout "gui/$uid/$WATCHDOG_LABEL" 2>/dev/null
		launchctl bootstrap "gui/$uid" "$dst"
	fi
	return 0
}

set_autologin() {
	if [ -n "${CONSOLE_PASSWORD:-}" ]; then
		sysadminctl -autologin set -userName "$CONSOLE_USER" -password "$CONSOLE_PASSWORD" 2>&1 | grep -v -E -- '-{10,}'
		return 0
	fi
	echo "  输入 $CONSOLE_USER 的登录密码（用于写入自动登录凭据，输入时不显示）："
	sysadminctl -autologin set -userName "$CONSOLE_USER" -password - </dev/tty
}

install_uu() {
	# Homebrew 拒绝以 root 运行，用管理员身份安装
	sudo -u "$ADMIN_USER" -H env HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_ENV_HINTS=1 "$BREW" install --quiet --cask "$UU_CASK"
}

step "前提"
if user_exists "$CONSOLE_USER"; then
	pass "$CONSOLE_USER 存在（uid $(user_uid "$CONSOLE_USER")）"
	console_home="$(user_home "$CONSOLE_USER")"
else
	[ "$MODE" = "apply" ] && die "$CONSOLE_USER 不存在：先运行 20-accounts.sh"
	warn "$CONSOLE_USER 尚未创建（20-accounts 执行后才能安装），以下按 /Users/$CONSOLE_USER 预演"
	console_home="/Users/$CONSOLE_USER"
fi
if [ -d "$UU_APP" ]; then
	pass "UU 已安装：$UU_APP"
elif [ -x "$BREW" ]; then
	change "用 Homebrew 安装 UU 远程（brew install --cask ${UU_CASK}）" install_uu
	[ "$MODE" = "apply" ] && { [ -d "$UU_APP" ] && pass "UU 安装完成" || fail "UU 安装失败：到 https://uuyc.163.com 手动下载"; }
else
	fail "未安装 UU，也没有 Homebrew：到 https://uuyc.163.com 手动下载安装"
fi
user_exists "$CONSOLE_USER" && is_admin "$CONSOLE_USER" && fail "$CONSOLE_USER 是管理员，应为标准用户（重跑 20-accounts）"

step "UU 守护任务（console 的 LaunchAgent）"
dst="$console_home/Library/LaunchAgents/${WATCHDOG_LABEL}.plist"
tmp="$(mktemp)"
render_watchdog >"$tmp"
plutil -lint "$tmp" >/dev/null || fail "生成的 plist 校验失败"
if [ -f "$dst" ] && cmp -s "$tmp" "$dst"; then
	pass "守护任务已是最新：$dst"
else
	change "安装守护任务 ${dst}（每 ${WATCHDOG_INTERVAL}s 检查，console 登录时也会启动 UU）" install_watchdog "$tmp" "$dst"
fi
rm -f "$tmp"

step "自动登录（方案 ${FILEVAULT_PLAN}）"
cur="$(autologin_user)"
if [ "$FILEVAULT_PLAN" = "A" ]; then
	if ! fv_is_off; then
		fail "方案 A 需要先关闭 FileVault（当前：$(fv_status)）：先运行 55-filevault.sh --apply --plan=A"
	elif [ "$cur" = "$CONSOLE_USER" ]; then
		pass "自动登录已是 $CONSOLE_USER"
	else
		change "设置开机自动登录 ${CONSOLE_USER}（当前：${cur:-无}）" set_autologin
		[ "$MODE" = "apply" ] && { [ "$(autologin_user)" = "$CONSOLE_USER" ] && pass "自动登录已设为 $CONSOLE_USER" || fail "自动登录设置未生效"; }
	fi
else
	if [ -z "$cur" ]; then
		pass "方案 B：自动登录已关闭"
	else
		change "方案 B：关闭自动登录（当前：${cur}）" sysadminctl -autologin off
	fi
fi

step "其他账号里的 UU"
others="$(uu_procs | awk -v c="$CONSOLE_USER" '$2 != c {print $2}' | sort -u | tr '\n' ' ')"
if [ -n "$others" ]; then
	warn "这些账号也在运行 UU：${others}—— 同一台机器两个 UU 实例是否冲突待实测"
	todo "console 的 UU 跑通后，在日常账号的 UU 设置里关掉「开机自动启动」并退出"
else
	pass "没有其他账号在运行 UU"
fi

step "需要你在 console 账号里手动完成（只做一次）"
todo "1. 用 console 登录桌面（菜单栏右上角的快速用户切换，或注销后登录）"
todo "2. 打开 UU 远程，登录你的 UU 账号"
todo "3. 系统设置 → 隐私与安全性：「屏幕与系统音频录制」「辅助功能」里打开 UU 远程"
todo "4. UU → 设置中心：勾选「开机自动启动」「防止电脑休眠」"
todo "5. UU 手机端 → 安全：开启「自动解锁被控端」（录入 console 的密码），以及「远程结束后，被控端自动锁屏」"
todo "6. 用另一台设备通过 UU 连进来，确认能看到画面、能操作鼠标键盘"
todo "完成后切回管理员账号，运行 bash scripts/90-verify.sh"

summary
