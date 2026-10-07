#!/bin/bash
# 99 回滚：按 00-preflight 记录的备份，把本工具改过的设置恢复原样。FileVault 不在这里处理（用 55）。
# 用法：
#   bash scripts/99-rollback.sh                          检查：列出将要恢复的项
#   sudo bash scripts/99-rollback.sh --apply             执行
#   sudo bash scripts/99-rollback.sh --apply --remove-users   同时删除本工具新建的账号（连同其家目录）
# 默认使用最早的备份（第一次运行 00-preflight 时的原始状态）；用 FLEET_BACKUP=state/backup-xxx 指定其他备份。

ALLOWED_FLAGS="--remove-users"
. "$(dirname "$0")/lib.sh"
fleet_init "$@"

BK="${FLEET_BACKUP:-$(ls -1d "$FLEET_ROOT"/state/backup-* 2>/dev/null | head -1)}"
case "$BK" in /*) ;; *) BK="$FLEET_ROOT/$BK" ;; esac
[ -f "$BK/settings.env" ] || die "找不到备份 $BK/settings.env"
# shellcheck source=/dev/null
. "$BK/settings.env"
info "使用备份：${BK#"$FLEET_ROOT"/}"

set_acl_members() {
	local g="$1" want="$2" u
	for u in $(group_members "$g"); do in_list "$u" "$want" || dseditgroup -o edit -d "$u" -t user "$g"; done
	for u in $want; do in_list "$u" "$(group_members "$g")" || dseditgroup -o edit -a "$u" -t user "$g"; done
}

disable_service() {
	launchctl bootout "system/$1" 2>/dev/null
	launchctl disable "system/$1"
}

restore_fw_off() { /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate off >/dev/null; }

remove_watchdog() {
	local uid
	uid="$(user_uid "$ADMIN_USER")"
	launchctl bootout "gui/$uid/$WATCHDOG_LABEL" 2>/dev/null
	rm -f "$1"
}

step "电源"
for k in autorestart autorestartatconnect sleep disksleep displaysleep womp; do
	eval "old=\${BK_PM_$k:-}"
	cur="$(pmset_get "$k")"
	if [ -z "$old" ] || [ "$old" = "$cur" ]; then pass "$k 无需恢复（${cur:-未设置}）"; else change "pmset ${k}：$cur → $old" pmset -a "$k" "$old"; fi
done

step "自动登录"
cur="$(autologin_user)"
if [ "$cur" = "$BK_AUTOLOGIN" ]; then
	pass "自动登录与备份一致（${cur:-无}）"
elif [ -z "$BK_AUTOLOGIN" ]; then
	change "关闭自动登录（当前：${cur}）" sysadminctl -autologin off
else
	warn "备份时自动登录的是 ${BK_AUTOLOGIN}，需要密码才能恢复：sudo sysadminctl -autologin set -userName $BK_AUTOLOGIN -password -"
fi

step "UU 守护任务"
wd="$(user_home "$ADMIN_USER")/Library/LaunchAgents/${WATCHDOG_LABEL}.plist"
if [ -f "$wd" ]; then
	change "移除 $wd" remove_watchdog "$wd"
else
	pass "守护任务不存在，无需处理"
fi
# 以前版本把守护任务装在 console 账号里；如果还有 console 账号，提示可删除
user_exists console && info "还有旧版留下的 console 账号；确认不再需要可执行：sudo sysadminctl -deleteUser console"

step "sshd 加固片段"
if [ "$BK_SSHD_DROPIN" = "0" ] && [ -f "$SSHD_DROPIN" ]; then
	change "删除 $SSHD_DROPIN" rm -f "$SSHD_DROPIN"
else
	pass "无需处理"
fi

step "访问组"
restore_acl() {
	local g="$1" existed="$2" members="$3" name="$4"
	if [ "$existed" = "1" ]; then
		if [ "$(group_members "$g")" = "$members" ]; then pass "$name 成员与备份一致"; else change "$name 成员恢复为 [$members]" set_acl_members "$g" "$members"; fi
	elif group_exists "$g"; then
		change "删除访问组 ${g}（备份时不存在＝允许所有用户）" dseditgroup -o delete "$g"
	else
		pass "$name 无需处理"
	fi
}
restore_acl "$ACL_SSH" "$BK_ACL_SSH_EXISTS" "$BK_ACL_SSH_MEMBERS" "远程登录"
restore_acl "$ACL_SCREEN" "$BK_ACL_SS_EXISTS" "$BK_ACL_SS_MEMBERS" "屏幕共享"

step "远程服务开关"
if [ "$BK_SS_STATE" != "enabled" ] && [ "$(svc_state com.apple.screensharing)" = "enabled" ]; then
	change "关闭屏幕共享" disable_service com.apple.screensharing
else
	pass "屏幕共享无需处理"
fi
if [ "$BK_SSH_STATE" != "enabled" ] && [ "$(svc_state com.openssh.sshd)" = "enabled" ]; then
	if [ -n "${SSH_CONNECTION:-}" ]; then
		warn "你正通过 SSH 运行本脚本，跳过关闭 SSH（会断开自己）；请在本机执行"
	else
		change "关闭远程登录（SSH）" disable_service com.openssh.sshd
	fi
else
	pass "SSH 无需处理"
fi

step "Tailscale"
if [ "${BK_TS_DAEMON:-0}" = "0" ] && [ -f "$TS_PLIST" ]; then
	change "退出私有网络并卸载 tailscaled 系统服务（Homebrew 里的程序保留）" sh -c "\"$TS_CLI\" logout; \"$TSD_SRC\" uninstall-system-daemon"
else
	pass "Tailscale 无需处理"
fi

step "防火墙与系统更新"
if [ "$BK_FW" = "0" ] && [ "$(fw_state)" != "0" ]; then change "关闭防火墙（恢复备份状态）" restore_fw_off; else pass "防火墙无需处理"; fi
for k in AutomaticallyInstallMacOSUpdates CriticalUpdateInstall AutomaticDownload; do
	eval "old=\${BK_SU_$k:-}"
	cur="$(su_get "$k")"
	if [ "$old" = "$cur" ]; then
		pass "$k 无需恢复（${cur:-未设置}）"
	elif [ -z "$old" ]; then
		change "删除 ${k}（备份时未设置）" defaults delete /Library/Preferences/com.apple.SoftwareUpdate "$k"
	else
		change "${k}：$cur → $old" defaults write /Library/Preferences/com.apple.SoftwareUpdate "$k" -bool "$([ "$old" = "1" ] && echo true || echo false)"
	fi
done

step "主机名与家目录"
[ "$(scutil --get ComputerName 2>/dev/null)" != "$BK_COMPUTERNAME" ] && change "ComputerName → $BK_COMPUTERNAME" scutil --set ComputerName "$BK_COMPUTERNAME"
[ "$(scutil --get LocalHostName 2>/dev/null)" != "$BK_LOCALHOSTNAME" ] && change "LocalHostName → $BK_LOCALHOSTNAME" scutil --set LocalHostName "$BK_LOCALHOSTNAME"
cur_hn="$(scutil --get HostName 2>/dev/null)"
if [ "$cur_hn" != "$BK_HOSTNAME" ]; then
	if [ -z "$BK_HOSTNAME" ]; then
		# scutil 没有可靠的「取消设置 HostName」命令；保留当前值不影响使用
		info "HostName 备份时未设置，当前为 ${cur_hn}；保留不动"
	else
		change "HostName → $BK_HOSTNAME" scutil --set HostName "$BK_HOSTNAME"
	fi
fi
cur_mode="$(home_mode "$ADMIN_USER")"
if [ -n "$BK_ADMIN_HOME_MODE" ] && [ "$cur_mode" != "$BK_ADMIN_HOME_MODE" ]; then
	change "管理员家目录权限 $cur_mode → $BK_ADMIN_HOME_MODE" chmod "$BK_ADMIN_HOME_MODE" "$(user_home "$ADMIN_USER")"
else
	pass "管理员家目录权限无需恢复"
fi

step "本工具新建的账号"
for u in $(managed_users); do
	user_exists "$u" || continue
	if in_list "$u" "$BK_USERS"; then
		info "$u 在备份时已存在，不删除"
	elif has_flag --remove-users; then
		if confirm "将删除账号 $u 及其家目录 $(user_home "$u")，无法撤销。"; then
			change "删除账号 ${u}（含家目录）" sysadminctl -deleteUser "$u"
		fi
	else
		info "$u 是本工具新建的；加 --remove-users 才会删除"
	fi
done

step "不在回滚范围内"
info "FileVault：当前 $(fv_status)；备份时 ${BK_FV}。需要恢复请用 55-filevault.sh"
info "UU 的设置、隐私权限、系统设置里手动改过的项目，需要手动恢复"

summary
