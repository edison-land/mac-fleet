#!/bin/bash
# 60 加固：主机名、关闭 macOS 自动安装更新、打开防火墙。
# 用法：bash scripts/60-hardening.sh  →  sudo bash scripts/60-hardening.sh --apply

. "$(dirname "$0")/lib.sh"
fleet_init "$@"
require_backup

set_hostnames() {
	scutil --set ComputerName "$HOST_NAME" &&
		scutil --set HostName "$HOST_NAME" &&
		scutil --set LocalHostName "$HOST_NAME"
}

set_fw() {
	local fw=/usr/libexec/ApplicationFirewall/socketfilterfw
	$fw --setglobalstate on >/dev/null && $fw --setallowsigned on >/dev/null
}

step "主机名"
case "$HOST_NAME" in
*[!A-Za-z0-9-]* | "") fail "HOST_NAME「${HOST_NAME}」只能包含字母、数字和连字符" ;;
*)
	cn="$(scutil --get ComputerName 2>/dev/null)"
	hn="$(scutil --get HostName 2>/dev/null)"
	ln="$(scutil --get LocalHostName 2>/dev/null)"
	if [ "$cn" = "$HOST_NAME" ] && [ "$hn" = "$HOST_NAME" ] && [ "$ln" = "$HOST_NAME" ]; then
		pass "三个名字都是 $HOST_NAME"
	else
		change "主机名 ComputerName=$cn HostName=${hn:-未设置} LocalHostName=$ln → $HOST_NAME" set_hostnames
	fi
	;;
esac

step "系统更新"
if [ "${DISABLE_MACOS_AUTO_UPDATE:-1}" = "1" ]; then
	v="$(su_get AutomaticallyInstallMacOSUpdates)"
	if [ "$v" = "0" ]; then
		pass "「自动安装 macOS 更新」已关闭"
	else
		change "关闭「自动安装 macOS 更新」（当前：${v:-未设置}）" defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticallyInstallMacOSUpdates -bool false
	fi
	v="$(su_get CriticalUpdateInstall)"
	if [ "$v" = "1" ]; then
		pass "「安装安全响应和系统文件」保持开启"
	else
		change "开启「安装安全响应和系统文件」（当前：${v:-未设置}）" defaults write /Library/Preferences/com.apple.SoftwareUpdate CriticalUpdateInstall -bool true
	fi
	info "可在 系统设置 → 通用 → 软件更新 → 自动更新 (i) 核对「安装 macOS 更新」已关闭"
else
	info "DISABLE_MACOS_AUTO_UPDATE=0，跳过"
fi

step "防火墙"
if [ "${FIREWALL:-1}" = "1" ]; then
	if [ "$(fw_state)" = "1" ] || [ "$(fw_state)" = "2" ]; then
		pass "防火墙已开启（State=$(fw_state)）"
	else
		change "打开防火墙，并自动允许内建签名软件" set_fw
	fi
	info "防火墙已放行系统自带的 SSH 与屏幕共享"
else
	info "FIREWALL=0，跳过"
fi

step "其他共享服务（只报告）"
for s in com.apple.smbd com.apple.AEServer com.apple.RemoteDesktop.agent; do
	info "${s}：$(svc_state "$s" | grep . || echo 未登记＝默认关闭)"
done

summary
