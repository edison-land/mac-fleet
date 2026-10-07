#!/bin/bash
# shellcheck disable=SC2015  # pass/fail/warn 恒返回 0，A && B || C 在这里等价于 if-else
# 90 巡检：只读，按配置逐项判定 PASS/FAIL，并输出 state/verify-<主机>-<时间>.json。
# 每次重启、拔电测试后都跑一次。不需要 sudo。
# 用法：bash scripts/90-verify.sh [--plan=A|B]

. "$(dirname "$0")/lib.sh"
fleet_init "$@"
[ "$MODE" = "apply" ] && info "90-verify 只读，--apply 不起作用"

JSON=""
rec() { JSON="${JSON}$(printf '  "%s": "%s",' "$1" "$(echo "$2" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr "\n" " " | sed "s/ *\$//")")
"; }

step "机器"
rec model "$(model_name) $(model_id)"
rec chip "$(chip_name)"
rec macos "$(sw_vers -productVersion) $(sw_vers -buildVersion)"
rec hostname "$(scutil --get ComputerName 2>/dev/null)"
rec ipv4 "$(ipv4_list)"
nm="$(net_mode)"
rec net_mode "$nm"
if [ "$nm" = "wifi" ]; then
	rec wifi_security "$(wifi_security "$(wifi_device)")"
	rec wifi_signal "$(wifi_signal)"
fi
info "$(model_name) $(model_id) · $(chip_name) · macOS $(sw_vers -productVersion) · $(ipv4_list)"
[ "$(scutil --get LocalHostName 2>/dev/null)" = "$HOST_NAME" ] && pass "主机名 $HOST_NAME" || warn "主机名不是 ${HOST_NAME}（60-hardening 未执行？）"
case "$nm" in
ethernet) pass "网络：以太网" ;;
wifi) pass "网络：Wi-Fi（$(wifi_security "$(wifi_device)")，信号/噪声 $(wifi_signal)）" ;;
*) fail "没有检测到已连接的以太网或 Wi-Fi" ;;
esac

step "开机与 UU 用时"
now="$(date +%s)"
boot="$(boot_epoch)"
up=$((now - boot))
rec boot_time "$(date -r "$boot" '+%Y-%m-%d %H:%M:%S')"
rec uptime_sec "$up"
info "本次开机：$(date -r "$boot" '+%Y-%m-%d %H:%M:%S')，已运行 ${up}s"
cuser="$(console_user)"
rec console_user "$cuser"
info "当前控制台用户：$cuser"
uu_admin_delay=""
while read -r pid u secs; do
	[ -z "$pid" ] && continue
	d=$((up - secs))
	info "UU pid=$pid 用户=$u 在开机后第 ${d}s 启动"
	[ "$u" = "$ADMIN_USER" ] && uu_admin_delay="$d"
done <<<"$(uu_procs)"
rec uu_admin_start_after_boot_sec "$uu_admin_delay"

step "电源"
while IFS=: read -r k w _; do
	v="$(pmset_get "$k")"
	rec "pmset_$k" "$v"
	if [ "$v" = "$w" ]; then pass "pmset $k=$v"; else fail "pmset $k=${v:-未设置}，应为 $w"; fi
done <<<"$(power_targets)"

step "FileVault 与自动登录（方案 ${FILEVAULT_PLAN}）"
fv="$(fv_status)"
al="$(autologin_user)"
rec filevault "$fv"
rec autologin "$al"
if [ "$FILEVAULT_PLAN" = "A" ]; then
	fv_is_off && pass "FileVault 已关闭" || fail "方案 A 要求 FileVault 关闭：$fv"
	[ "$al" = "$ADMIN_USER" ] && pass "自动登录 $ADMIN_USER" || fail "自动登录应为 ${ADMIN_USER}，当前：${al:-无}"
	sl="$(sudo -n -u "$ADMIN_USER" sysadminctl -screenLock status 2>&1 | sed -n 's/.*screenLock delay is \(.*\)$/\1/p')"
	rec screenlock "$sl"
	case "$sl" in *immediate* | "0 seconds") pass "显示器关闭后立即锁屏" ;; "") info "锁屏状态需 sudo 运行本脚本才能读取" ;; *) fail "锁屏延迟为 ${sl}，自动登录时应立即锁屏（运行 50-uu --apply）" ;; esac
else
	fv_is_on && pass "FileVault 已开启" || fail "方案 B 要求 FileVault 开启：$fv"
	[ -z "$al" ] && pass "未设置自动登录" || fail "方案 B 不应自动登录，当前：$al"
fi

step "管理员家目录（不修改，只检查远程用户能否读到）"
am="$(home_mode "$ADMIN_USER")"
rec admin_home_mode "$am"
info "$(user_home "$ADMIN_USER") 权限 ${am}（保持原样）"
for u in $(managed_users); do
	user_exists "$u" || continue
	if dsmemberutil checkmembership -U "$u" -G staff 2>/dev/null | grep -q "is a member"; then
		case "$am" in 7[0-7]0 | 700) fail "$u 在 staff 组，能读管理员家目录里组可读的内容（运行 20-accounts --apply）" ;; *) fail "$u 在 staff 组" ;; esac
	else
		pass "$u 不在 staff 组：读不到管理员家目录"
	fi
done

step "账号"
[ -z "$(managed_users)" ] && info "没有配置远程用户（MANAGED_USERS 为空）"
for u in $(managed_users); do
	if ! user_exists "$u"; then fail "$u 不存在"; continue; fi
	is_admin "$u" && fail "$u 是管理员" || pass "$u 是标准用户"
	m="$(home_mode "$u")"
	rec "home_mode_$u" "$m"
	if [ "$m" = "700" ]; then pass "$u 家目录 700"; elif [ -z "$m" ]; then warn "$u 家目录尚未创建"; else fail "$u 家目录权限 $m"; fi
done
guest_enabled && fail "访客账号开着" || pass "访客账号已关闭"

step "远程入口"
ssh_st="$(svc_state com.openssh.sshd)"
ss_st="$(svc_state com.apple.screensharing)"
rec ssh "$ssh_st"
rec screensharing "$ss_st"
port_listening 22 && pass "SSH 端口 22 在监听" || fail "SSH 未开启（launchd=${ssh_st}）"
port_listening 5900 && pass "屏幕共享端口 5900 在监听" || fail "屏幕共享未开启（launchd=${ss_st}）"
check_acl() {
	local g="$1" name="$2" want="$3" cur u nested
	if ! group_exists "$g"; then fail "$name 没有访问组：所有用户都能连"; return; fi
	cur="$(group_members "$g")"
	nested="$(group_nested "$g")"
	rec "acl_$g" "$cur"
	rec "acl_nested_$g" "$nested"
	[ -n "$nested" ] && info "${name}：另外整组允许 [${nested% }]"
	for u in $want; do in_list "$u" "$cur" && pass "$name 允许 $u" || fail "$name 缺少 $u"; done
	for u in $cur; do in_list "$u" "$want" || fail "$name 多出 ${u}（不在配置里）"; done
}
check_acl "$ACL_SSH" "远程登录" "$(ssh_allowed_users)"
check_acl "$ACL_SCREEN" "屏幕共享" "$(screen_allowed_users)"
if [ -f "$SSHD_DROPIN" ]; then pass "sshd 加固片段存在"; else fail "缺少 $SSHD_DROPIN"; fi

step "UU"
[ -d "$UU_APP" ] && pass "UU 已安装" || fail "UU 未安装"
wd="$(user_home "$ADMIN_USER")/Library/LaunchAgents/${WATCHDOG_LABEL}.plist"
if [ -f "$wd" ]; then pass "守护任务已安装"; else fail "缺少守护任务 $wd"; fi
if [ -n "$uu_admin_delay" ]; then
	pass "$ADMIN_USER 的 UU 在运行（开机后 ${uu_admin_delay}s 启动）"
elif [ "$FILEVAULT_PLAN" = "A" ]; then
	fail "$ADMIN_USER 的 UU 没有在运行"
else
	info "方案 B 不自动登录，管理员登录后 UU 才会运行"
fi

step "Tailscale"
if [ "${TS_ENABLE:-1}" = "1" ]; then
	ts_state="$(ts_field BackendState)"
	rec tailscale_state "$ts_state"
	rec tailscale_ip "$(ts_field Self.TailscaleIPs.0)"
	[ -f "$TS_PLIST" ] && pass "tailscaled 系统服务已安装" || fail "缺少 tailscaled 系统服务（40-tailscale 未执行？）"
	[ "$ts_state" = "Running" ] && pass "已加入私有网络：$(ts_field Self.DNSName) $(ts_field Self.TailscaleIPs.0)" || fail "Tailscale 状态：${ts_state:-未运行}"
	[ "$(ts_pref RunSSH)" = "true" ] && pass "Tailscale SSH 已打开" || fail "Tailscale SSH 未打开"
fi

step "加固"
fw="$(fw_state)"
rec firewall "$fw"
[ "$fw" = "1" ] || [ "$fw" = "2" ] && pass "防火墙已开启" || fail "防火墙未开启"
v="$(su_get AutomaticallyInstallMacOSUpdates)"
rec auto_install_macos_updates "$v"
[ "$v" = "0" ] && pass "自动安装 macOS 更新已关闭" || fail "自动安装 macOS 更新：${v:-未设置}"

OUT="$FLEET_ROOT/state/verify-$(hostname -s)-$TS.json"
{
	echo "{"
	printf '%s' "$JSON"
	printf '  "plan": "%s",\n  "pass": %d,\n  "fail": %d,\n  "warn": %d,\n  "time": "%s"\n}\n' "$FILEVAULT_PLAN" "$N_PASS" "$N_FAIL" "$N_WARN" "$(date '+%Y-%m-%d %H:%M:%S %z')"
} >"$OUT"
plutil -convert xml1 -o /dev/null "$OUT" >/dev/null 2>&1 || warn "生成的 JSON 校验失败：$OUT"
[ -n "${SUDO_UID:-}" ] && chown "$SUDO_UID" "$OUT"
info "JSON：${OUT#"$FLEET_ROOT"/}"

summary
