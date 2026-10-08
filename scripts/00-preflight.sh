#!/bin/bash
# 00 预检：只读。确认机器符合条件，并把当前设置记录到 state/backup-<时间>/，供 99-rollback 回滚。
# 用法：bash scripts/00-preflight.sh        （不需要 sudo，也没有 --apply）

. "$(dirname "$0")/lib.sh"
fleet_init "$@"
[ "$MODE" = "apply" ] && info "00-preflight 只读，--apply 不起作用"

step "机型与系统"
mname="$(model_name)"
mver="$(sw_vers -productVersion)"
info "机型 $mname ($(model_id)) · 芯片 $(chip_name) · 架构 $(uname -m)"
if [ "$mname" = "Mac mini" ]; then pass "机型是 Mac mini"; else fail "机型是「${mname}」，本方案只针对 Mac mini"; fi
if [ "$(chip_gen)" -ge "$MIN_CHIP_GEN" ]; then pass "芯片 M$(chip_gen) ≥ M$MIN_CHIP_GEN"; else fail "芯片 $(chip_name) 低于 M$MIN_CHIP_GEN"; fi
if version_ge "$mver" "$MIN_MACOS"; then pass "macOS $mver ≥ $MIN_MACOS"; else fail "macOS $mver 低于 ${MIN_MACOS}，「接通电源时启动」不可用"; fi

step "管理员账号"
if user_exists "$ADMIN_USER" && is_admin "$ADMIN_USER"; then pass "$ADMIN_USER 是管理员"; else fail "$ADMIN_USER 不存在或不是管理员"; fi
if has_secure_token "$ADMIN_USER"; then pass "$ADMIN_USER 有 Secure Token（可以开关 FileVault）"; else warn "$ADMIN_USER 没有 Secure Token：无法用它开关 FileVault"; fi

step "FileVault"
info "当前：$(fv_status)"
if [ "$FILEVAULT_PLAN" = "B" ]; then
	if fv_is_on; then pass "方案 B 要求 FileVault 开启：已开启"; else warn "方案 B 要求 FileVault 开启：当前未开启（55-filevault 可开启）"; fi
else
	if fv_is_off; then pass "方案 A 要求 FileVault 关闭：已关闭"; else warn "方案 A 要求 FileVault 关闭：当前未关闭（55-filevault 可关闭）"; fi
fi

step "网络"
eth="$(ethernet_device)"
wifi="$(wifi_device)"
info "IPv4：$(ipv4_list)"
info "默认路由网卡：$(default_iface)；内置以太网：${eth:-未找到}；Wi-Fi：${wifi:-未找到}"
case "$(net_mode)" in
ethernet)
	pass "使用以太网 $eth"
	;;
wifi)
	pass "使用 Wi-Fi ${wifi}（可以用；可靠性低于网线，详见指南第 3 节）"
	sec="$(wifi_security "$wifi")"
	info "加密方式：${sec:-未知}；信号/噪声：$(wifi_signal)"
	# 当前 SSID 被系统隐藏，按「已保存网络」逐个检查密码是否在系统钥匙串
	saved=0
	insys=0
	while read -r ssid; do
		[ -z "$ssid" ] && continue
		saved=$((saved + 1))
		wifi_in_system_keychain "$ssid" && insys=$((insys + 1))
	done <<<"$(wifi_preferred "$wifi")"
	info "已保存 Wi-Fi ${saved} 个，其中 ${insys} 个的密码在系统钥匙串"
	first="$(wifi_preferred "$wifi" | head -1)"
	if [ -n "$first" ] && wifi_in_system_keychain "$first"; then
		pass "优先级最高的 Wi-Fi「${first}」密码在系统钥匙串：开机后无人登录也能自动连上"
	else
		warn "优先级最高的 Wi-Fi「${first}」密码不在系统钥匙串：开机后可能要等有人登录才联网"
		todo "最好接网线；否则改连家里路由器自己的 Wi-Fi（WPA2 个人版），用管理员账号加入，并删掉公共热点（如 XFINITY / xfinitywifi）等其他已保存网络"
	fi
	case "$sec" in
	WPA2_PSK | NONE | "")
		[ "$FILEVAULT_PLAN" = "B" ] && info "方案 B：$sec 属于 Apple 列出的预启动 SSH 解锁支持范围（开放或 WPA2 个人版），仍需在阶段 6 实测"
		;;
	*)
		if [ "$FILEVAULT_PLAN" = "B" ]; then
			warn "方案 B：Apple 只列出开放和 WPA2 个人版 Wi-Fi 支持预启动 SSH 解锁，当前是 ${sec}，FileVault 锁着时可能连不上"
			todo "如需方案 B：把路由器的 Wi-Fi 加密改为 WPA2 个人版（或 WPA2/WPA3 混合）后在阶段 6 实测，或改用网线"
		fi
		;;
	esac
	;;
*)
	fail "没有检测到已连接的以太网或 Wi-Fi"
	;;
esac

step "磁盘"
free_gb="$(df -g / | awk 'NR == 2 {print $4}')"
info "系统盘剩余 ${free_gb}GB"
if [ "$free_gb" -ge 20 ]; then pass "剩余空间 ≥ 20GB"; else warn "剩余空间不足 20GB"; fi

step "UU 远程"
if [ -d "$UU_APP" ]; then
	pass "已安装 ${UU_APP}（版本 $(defaults read "$UU_APP/Contents/Info" CFBundleShortVersionString 2>/dev/null)）"
else
	fail "未找到 $UU_APP"
fi
procs="$(uu_procs)"
if [ -n "$procs" ]; then
	echo "$procs" | while read -r pid u secs; do info "进程 $UU_PROC pid=$pid 用户=$u 已运行 ${secs}s"; done
else
	warn "$UU_PROC 没有在运行"
fi

step "当前远程入口状态"
info "远程登录(SSH)：launchd=$(svc_state com.openssh.sshd) 端口22监听=$(port_listening 22 && echo 是 || echo 否)"
info "屏幕共享：launchd=$(svc_state com.apple.screensharing) 端口5900监听=$(port_listening 5900 && echo 是 || echo 否)"
info "SSH 访问组 ${ACL_SSH}：$(group_exists "$ACL_SSH" && echo "存在，$(acl_describe "$ACL_SSH")" || echo 不存在＝所有用户)"
info "屏幕共享访问组 ${ACL_SCREEN}：$(group_exists "$ACL_SCREEN" && echo "存在，$(acl_describe "$ACL_SCREEN")" || echo 不存在＝所有用户)"
info "自动登录：$(autologin_user || true)  当前控制台用户：$(console_user)"

step "家目录隔离"
info "管理员家目录 $(user_home "$ADMIN_USER") 权限 $(home_mode "$ADMIN_USER")（不会修改）"
info "macOS 新建家目录是 750（staff 组可读）；20-accounts 会把远程用户移出 staff，使其读不到管理员文件"

step "提醒"
info "建议：改动前确认这台 Mac 有近期的 Time Machine 备份"

step "记录当前设置（回滚用）"
BK="$FLEET_ROOT/state/backup-$TS"
mkdir -p "$BK"
{
	printf 'BK_TS=%q\n' "$TS"
	printf 'BK_COMPUTERNAME=%q\n' "$(scutil --get ComputerName 2>/dev/null)"
	printf 'BK_LOCALHOSTNAME=%q\n' "$(scutil --get LocalHostName 2>/dev/null)"
	printf 'BK_HOSTNAME=%q\n' "$(scutil --get HostName 2>/dev/null)"
	for k in autorestart autorestartatconnect sleep disksleep displaysleep womp; do
		printf 'BK_PM_%s=%q\n' "$k" "$(pmset_get "$k")"
	done
	printf 'BK_SSH_STATE=%q\n' "$(svc_state com.openssh.sshd)"
	printf 'BK_SS_STATE=%q\n' "$(svc_state com.apple.screensharing)"
	printf 'BK_ACL_SSH_EXISTS=%q\n' "$(group_exists "$ACL_SSH" && echo 1 || echo 0)"
	printf 'BK_ACL_SSH_MEMBERS=%q\n' "$(group_members "$ACL_SSH")"
	printf 'BK_ACL_SS_EXISTS=%q\n' "$(group_exists "$ACL_SCREEN" && echo 1 || echo 0)"
	printf 'BK_ACL_SS_MEMBERS=%q\n' "$(group_members "$ACL_SCREEN")"
	printf 'BK_ACL_SSH_NESTED=%q\n' "$(group_nested "$ACL_SSH")"
	printf 'BK_ACL_SS_NESTED=%q\n' "$(group_nested "$ACL_SCREEN")"
	printf 'BK_SSHD_DROPIN=%q\n' "$([ -f "$SSHD_DROPIN" ] && echo 1 || echo 0)"
	printf 'BK_AUTOLOGIN=%q\n' "$(autologin_user)"
	printf 'BK_FV=%q\n' "$(fv_status)"
	printf 'BK_NET_MODE=%q\n' "$(net_mode)"
	printf 'BK_TS_DAEMON=%q\n' "$([ -f "$TS_PLIST" ] && echo 1 || echo 0)"
	printf 'BK_FW=%q\n' "$(fw_state)"
	for k in AutomaticallyInstallMacOSUpdates CriticalUpdateInstall AutomaticDownload; do
		printf 'BK_SU_%s=%q\n' "$k" "$(su_get "$k")"
	done
	printf 'BK_ADMIN_HOME_MODE=%q\n' "$(home_mode "$ADMIN_USER")"
	printf 'BK_GUEST=%q\n' "$(guest_enabled && echo on || echo off)"
	printf 'BK_USERS=%q\n' "$(dscl . -list /Users | grep -v '^_' | tr '\n' ' ')"
} >"$BK/settings.env"
pmset -g custom >"$BK/pmset-custom.txt" 2>&1
pmset -g >"$BK/pmset.txt" 2>&1
launchctl print-disabled system >"$BK/launchd-disabled.txt" 2>&1
ls -l /etc/ssh/sshd_config.d/ >"$BK/sshd_config.d.txt" 2>&1
defaults read /Library/Preferences/com.apple.SoftwareUpdate >"$BK/softwareupdate.txt" 2>&1
[ -n "${SUDO_UID:-}" ] && chown -R "$SUDO_UID" "$BK"
pass "已写入 ${BK#"$FLEET_ROOT"/}/settings.env"

summary
