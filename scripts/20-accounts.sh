#!/bin/bash
# 20 账号：创建远程用户（标准账号，主组 fleetusers）、关闭访客、收紧家目录权限。
# 用法：bash scripts/20-accounts.sh  →  sudo bash scripts/20-accounts.sh --apply
#
# 新账号的密码由配置 PASSWORD_MODE 决定：
#   shared   只问一次，本次新建的账号共用这个密码（默认，适合测试）
#   generate 不用输入：每个账号随机生成 20 位密码，执行结束时只在终端显示一次，请立刻存进密码管理器
#   prompt   每个账号分别输入（sysadminctl 自己提示）
# shared / generate 会把密码作为参数交给 sysadminctl，创建的几秒内本机其他用户用 ps 能看到；
# 新机器上此时没有其他人登录，风险可以接受。密码不会写进日志。

. "$(dirname "$0")/lib.sh"
fleet_init "$@"
require_backup

PASSWORD_MODE="${PASSWORD_MODE:-shared}"
case "$PASSWORD_MODE" in shared | generate | prompt) ;; *) die "PASSWORD_MODE 只能是 shared、generate、prompt" ;; esac
SHARED_PW=""
GENERATED=""

# 20 位随机密码，去掉容易看错的 0 O 1 l I
gen_password() { LC_ALL=C tr -dc 'A-HJ-NP-Za-km-z2-9' </dev/urandom | head -c 20; }

read_shared_password() {
	local a b
	while :; do
		printf '为本次新建的账号设置一个共用密码（输入时不显示，至少 8 位）：' >/dev/tty
		read -rs a </dev/tty
		printf '\n再输入一次：' >/dev/tty
		read -rs b </dev/tty
		printf '\n' >/dev/tty
		if [ "$a" != "$b" ]; then echo "两次不一致，重来" >/dev/tty; continue; fi
		if [ ${#a} -lt 8 ]; then echo "少于 8 位，重来" >/dev/tty; continue; fi
		SHARED_PW="$a"
		return 0
	done
}

create_user() {
	local u="$1" full="$2" pw
	case "$PASSWORD_MODE" in
	prompt)
		echo "  为 $u 设置密码（输入时不显示）："
		sysadminctl -addUser "$u" -fullName "$full" -GID "$FLEET_GID_RESOLVED" -password - </dev/tty
		;;
	shared)
		sysadminctl -addUser "$u" -fullName "$full" -GID "$FLEET_GID_RESOLVED" -password "$SHARED_PW" 2>&1 | grep -v -E -- '-{10,}|clear text password'
		;;
	generate)
		pw="$(gen_password)"
		sysadminctl -addUser "$u" -fullName "$full" -GID "$FLEET_GID_RESOLVED" -password "$pw" 2>&1 | grep -v -E -- '-{10,}|clear text password'
		GENERATED="${GENERATED}${u} ${pw}
"
		;;
	esac
	user_exists "$u" || return 1
	createhomedir -c -u "$u" >/dev/null 2>&1
	return 0
}

# 执行结束时把随机密码显示在终端（不经过 tee，不进日志）
show_generated() {
	[ -n "$GENERATED" ] || return 0
	{
		echo
		echo "================ 新账号密码（只显示这一次，不在日志里）================"
		printf '%s' "$GENERATED" | while read -r u pw; do printf '  %-12s %s\n' "$u" "$pw"; done
		echo "======================================================================="
		echo "请现在存进密码管理器。"
	} >/dev/tty
}

demote_user() { dseditgroup -o edit -d "$1" -t user admin; }

# ---- 专用组：远程用户不放在 staff 里 ----
# macOS 新建家目录是 750（组 staff 可读），而默认所有用户的主组都是 staff。
# 把远程用户的主组换成专用组后，它们对管理员家目录来说就是「其他人」，750 直接拒绝；管理员账号一点不用动。
FLEET_GROUP="${FLEET_GROUP:-fleetusers}"
group_gid() { dscl . -read "/Groups/$1" PrimaryGroupID 2>/dev/null | awk '{print $2}'; }
free_gid() { local g=600; while dscl . -list /Groups PrimaryGroupID | awk '{print $2}' | grep -qx "$g"; do g=$((g + 1)); done; echo "$g"; }
FLEET_GID_RESOLVED="$(group_gid "$FLEET_GROUP")"
create_fleet_group() {
	FLEET_GID_RESOLVED="$(free_gid)"
	dseditgroup -o create -i "$FLEET_GID_RESOLVED" -r "mac-fleet remote users" "$FLEET_GROUP"
}
move_to_fleet_group() {
	local u="$1"
	dscl . -create "/Users/$u" PrimaryGroupID "$FLEET_GID_RESOLVED" &&
		chown -R "$u:$FLEET_GROUP" "$(user_home "$u")" &&
		dscacheutil -flushcache
}
in_staff() { dsmemberutil checkmembership -U "$1" -G staff 2>/dev/null | grep -q "is a member"; }

step "专用组 ${FLEET_GROUP}"
if [ -n "$FLEET_GID_RESOLVED" ]; then
	pass "组 $FLEET_GROUP 已存在（gid ${FLEET_GID_RESOLVED}）"
else
	change "创建组 ${FLEET_GROUP}（远程用户的主组，不再属于 staff）" create_fleet_group
	[ "$MODE" = "check" ] && FLEET_GID_RESOLVED="$(free_gid)"
fi

step "账号"
to_create=""
for u in $(managed_users); do user_exists "$u" || to_create="$to_create $u"; done
if [ -n "$to_create" ]; then
	info "密码方式：PASSWORD_MODE=${PASSWORD_MODE}（待创建：${to_create# }）"
	[ "$MODE" = "apply" ] && [ "$PASSWORD_MODE" = "shared" ] && read_shared_password
fi
[ -z "$(managed_users)" ] && info "MANAGED_USERS 为空：本次不创建远程用户（开户时再传，如 MANAGED_USERS=u_alice）"
for u in $(managed_users); do
	full="$u"
	if user_exists "$u"; then
		pass "$u 已存在（uid $(user_uid "$u")）"
	else
		change "创建标准账号 ${u}（全名 ${full}）" create_user "$u" "$full"
		if [ "$MODE" = "apply" ]; then
			if user_exists "$u"; then pass "$u 创建成功（uid $(user_uid "$u")）"; else fail "$u 创建失败"; continue; fi
		else
			continue
		fi
	fi
	if in_staff "$u"; then
		change "把 $u 的主组从 staff 改为 ${FLEET_GROUP}（之后它读不到管理员家目录）" move_to_fleet_group "$u"
		[ "$MODE" = "apply" ] && { in_staff "$u" && fail "$u 仍在 staff 组" || pass "$u 已不在 staff 组"; }
	else
		pass "$u 不在 staff 组（主组 $(dscl . -read "/Users/$u" PrimaryGroupID | awk '{print $2}')）"
	fi
	if is_admin "$u"; then
		if confirm "$u 当前是管理员，将降为标准用户。"; then
			change "把 $u 从 admin 组移除" demote_user "$u"
		fi
	else
		pass "$u 是标准用户"
	fi
	if has_secure_token "$u"; then
		info "$u 有 Secure Token：FileVault 开启时它也能在开机时解锁磁盘"
	else
		info "$u 没有 Secure Token：不能在开机时解锁 FileVault（符合预期）"
	fi
done

step "访客账号"
if guest_enabled; then
	change "关闭访客账号" sysadminctl -guestAccount off
else
	pass "访客账号已关闭"
fi

step "家目录权限"
targets="$(managed_users)"
[ "${HARDEN_ADMIN_HOME:-0}" = "1" ] && targets="$targets $ADMIN_USER"
for u in $targets; do
	if ! user_exists "$u"; then
		[ "$MODE" = "check" ] && info "$u 尚未创建，创建后再收紧"
		continue
	fi
	h="$(user_home "$u")"
	m="$(home_mode "$u")"
	if [ -z "$m" ]; then
		warn "$u 的家目录 $h 还不存在（首次登录时创建，之后重跑本脚本）"
	elif [ "$m" = "700" ]; then
		pass "$h 权限 700"
	else
		change "$h 权限 $m → 700" chmod 700 "$h"
		[ "$MODE" = "apply" ] && { [ "$(home_mode "$u")" = "700" ] && pass "$h 权限已是 700" || fail "$h 权限仍是 $(home_mode "$u")"; }
	fi
done
if [ "${HARDEN_ADMIN_HOME:-0}" != "1" ]; then
	info "管理员家目录 $(user_home "$ADMIN_USER") 权限 $(home_mode "$ADMIN_USER")，保持不动；远程用户不在 staff 组，读不到它"
fi

show_generated
summary
