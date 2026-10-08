#!/bin/bash
# 30 远程入口：打开 SSH 与屏幕共享，按配置限定允许的账号，写 sshd 加固片段和管理员公钥。
# 用法：bash scripts/30-remote-access.sh  →  sudo bash scripts/30-remote-access.sh --apply

. "$(dirname "$0")/lib.sh"
fleet_init "$@"
require_backup

# ---------- 动作函数（只在 --apply 时被 change 调用） ----------

enable_service() {
	local label="$1" plist="$2" port="$3"
	launchctl enable "system/$label"
	launchctl bootstrap system "$plist" 2>/dev/null
	port_listening "$port" && return 0
	# 老办法兜底
	launchctl load -w "$plist" 2>/dev/null
	port_listening "$port"
}

enable_ssh() {
	# systemsetup 在新版 macOS 需要终端有「完全磁盘访问权限」，失败就改用 launchctl
	systemsetup -setremotelogin on >/dev/null 2>&1
	port_listening 22 && return 0
	enable_service com.openssh.sshd /System/Library/LaunchDaemons/ssh.plist 22
}

acl_ensure_group() {
	local g="$1" real="$2"
	if group_exists "${g}-disabled"; then
		# 系统设置切到「所有用户」时会把组改名为 -disabled；改回来即恢复「仅这些用户」
		dscl . -change "/Groups/${g}-disabled" RecordName "${g}-disabled" "$g"
	else
		dseditgroup -o create -r "$real" -T group "$g"
	fi
}

acl_add() { dseditgroup -o edit -a "$1" -t user "$2"; }
acl_del() { dseditgroup -o edit -d "$1" -t user "$2"; }

# sync_acl 组名 显示名 "允许的账号" 必须保留的账号
sync_acl() {
	local g="$1" real="$2" want="$3" keep="$4" u cur nested
	for u in $want; do
		user_exists "$u" || if [ "$MODE" = "apply" ]; then fail "${real}：账号 $u 不存在（先运行 20-accounts），跳过"; want="$(echo " $want " | sed "s/ $u / /")"; else warn "${real}：账号 $u 尚未创建（20-accounts 执行后才能加入）"; fi
	done
	if group_exists "$g"; then
		pass "$real 访问组 $g 已存在（＝「仅这些用户」）"
	else
		change "创建访问组 ${g}（系统设置里显示为「仅这些用户」）" acl_ensure_group "$g" "$real"
	fi
	cur="$(group_members "$g")"
	nested="$(group_nested "$g")"
	[ -n "$nested" ] && info "${real}：另外整组允许 [${nested% }]（系统设置里选的「管理员」等；保持不动）"
	for u in $want; do
		if in_list "$u" "$cur"; then pass "$real 允许 $u"; else change "$real 加入 $u" acl_add "$u" "$g"; fi
	done
	for u in $cur; do
		in_list "$u" "$want" && continue
		if [ -n "$keep" ] && [ "$u" = "$keep" ]; then
			info "$real 保留 ${u}（管理员）"
			continue
		fi
		change "$real 移除 ${u}（不在配置里）" acl_del "$u" "$g"
	done
}

install_dropin() {
	local src="$1" bak=""
	if [ -f "$SSHD_DROPIN" ]; then
		bak="$(mktemp)"
		cp "$SSHD_DROPIN" "$bak"
	fi
	install -m 644 -o root -g wheel "$src" "$SSHD_DROPIN"
	# macOS 要等第一次有人连进来才生成主机密钥；没有密钥时 sshd -t 会报
	# 「no hostkeys available」。先补齐（与系统自带的 sshd-keygen-wrapper 做法相同）
	if ! ls /etc/ssh/ssh_host_*_key >/dev/null 2>&1; then
		echo "  尚无 SSH 主机密钥，先用 ssh-keygen -A 生成"
		ssh-keygen -A
	fi
	if /usr/sbin/sshd -t; then
		[ -n "$bak" ] && rm -f "$bak"
		return 0
	fi
	echo "sshd -t 校验失败，已撤回"
	if [ -n "$bak" ]; then mv "$bak" "$SSHD_DROPIN"; else rm -f "$SSHD_DROPIN"; fi
	return 1
}

add_pubkey() {
	local h ak
	h="$(user_home "$ADMIN_USER")"
	ak="$h/.ssh/authorized_keys"
	mkdir -p "$h/.ssh"
	echo "$ADMIN_PUBKEY" >>"$ak"
	chown -R "$ADMIN_USER" "$h/.ssh"
	chmod 700 "$h/.ssh"
	chmod 600 "$ak"
}

# ---------- 检查与执行 ----------

step "远程登录（SSH）"
# 先限定账号再开服务，避免开服务的那一刻对所有用户开放
sync_acl "$ACL_SSH" "远程登录" "$(ssh_allowed_users)" "$ADMIN_USER"
if [ "$(svc_state com.openssh.sshd)" = "enabled" ] && port_listening 22; then
	pass "SSH 已开启，端口 22 在监听"
else
	change "打开远程登录（SSH）" enable_ssh
	if [ "$MODE" = "apply" ]; then
		if port_listening 22; then pass "SSH 已开启"; else fail "SSH 没能用命令打开"; todo "到 系统设置 → 通用 → 共享 → 远程登录 手动打开，然后重跑本脚本"; fi
	fi
fi

step "管理员公钥"
if [ -z "${ADMIN_PUBKEY:-}" ]; then
	info "ADMIN_PUBKEY 为空，跳过"
else
	ak="$(user_home "$ADMIN_USER")/.ssh/authorized_keys"
	keybody="$(echo "$ADMIN_PUBKEY" | awk '{print $2}')"
	if [ -f "$ak" ] && grep -qF "$keybody" "$ak"; then
		pass "公钥已在 $ak"
	else
		change "把公钥（$(echo "$ADMIN_PUBKEY" | awk '{print $3}')）写入 $ak" add_pubkey
	fi
fi

step "sshd 加固片段 $SSHD_DROPIN"
tmp="$(mktemp)"
{
	echo "# 由 mac-fleet 30-remote-access.sh 生成，请勿手改；回滚用 99-rollback.sh"
	echo "PermitRootLogin no"
	if [ "${SSH_KEY_ONLY:-0}" = "1" ]; then
		echo "PasswordAuthentication no"
		echo "KbdInteractiveAuthentication no"
	fi
} >"$tmp"
if [ "${SSH_KEY_ONLY:-0}" = "1" ]; then
	ak="$(user_home "$ADMIN_USER")/.ssh/authorized_keys"
	if [ ! -s "$ak" ] && [ -z "${ADMIN_PUBKEY:-}" ]; then
		fail "SSH_KEY_ONLY=1 但管理员没有任何公钥：执行会把自己锁在外面，已跳过"
		rm -f "$tmp"
		tmp=""
	fi
	[ "$FILEVAULT_PLAN" = "B" ] && warn "方案 B 依赖 SSH 密码解锁 FileVault；关闭密码登录前先验证预启动解锁仍可用"
fi
if [ -n "$tmp" ]; then
	if [ -f "$SSHD_DROPIN" ] && cmp -s "$tmp" "$SSHD_DROPIN"; then
		pass "加固片段已是最新"
	else
		info "内容：$(grep -v '^#' "$tmp" | tr '\n' ';')"
		change "写入 $SSHD_DROPIN 并用 sshd -t 校验" install_dropin "$tmp"
	fi
	rm -f "$tmp"
fi

step "屏幕共享"
sync_acl "$ACL_SCREEN" "屏幕共享" "$(screen_allowed_users)" ""
if [ "$(svc_state com.apple.screensharing)" = "enabled" ] && port_listening 5900; then
	pass "屏幕共享已开启，端口 5900 在监听"
else
	change "打开屏幕共享" enable_service com.apple.screensharing /System/Library/LaunchDaemons/com.apple.screensharing.plist 5900
	if [ "$MODE" = "apply" ]; then
		if port_listening 5900; then pass "屏幕共享已开启"; else fail "屏幕共享没能用命令打开"; todo "到 系统设置 → 通用 → 共享 → 屏幕共享 手动打开，然后重跑本脚本"; fi
	fi
fi

step "从另一台电脑验证（贴回结果）"
info "本机地址：$(ipv4_list)"
info "可在 系统设置 → 通用 → 共享 核对：远程登录、屏幕共享都显示「仅这些用户」，名单与上面一致（截图贴回）"
info "验证：ssh $ADMIN_USER@<上面的IP> 能登录"
for u in $(managed_users); do
	if in_list "$u" "$(ssh_allowed_users)"; then
		info "验证：ssh $u@<IP> 输入正确密码后应能登录"
	else
		info "验证：ssh $u@<IP> 输入正确密码后仍应被拒绝（验证访问组生效）"
	fi
done

summary
