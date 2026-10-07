#!/bin/bash
# 管理员在自己电脑上运行：按 hosts.conf（机器）和 users.conf（谁能用哪些机器）同步一切。
#
# 用法：
#   bash admin/sync.sh              只读：校验两张表，生成访问规则到 admin/out/policy.hujson，打印分配情况
#   bash admin/sync.sh --accounts   另外经 Tailscale SSH 到各台机器，补建缺少的账号（每台会要一次该机器管理员的 sudo 密码）
#   bash admin/sync.sh --push       另外把规则推送到 Tailscale 后台（需要 API 令牌，见 docs/SOP.md）
#
# 规则模型（多对多）：
#   每台机器有标签 tag:mac + tag:<机器名>；每个用户在 users.conf 里一行 → 生成两条规则：
#     grants：只能连到他被分配的机器的 22 / mosh 端口
#     ssh   ：在这些机器上只能以他自己的本地账号登录
#   同一台机器可以分配给多个人；一个人可以有多台机器；每个人在所有机器上只有一个账号。
# 只增不删：从表里删掉某人后，规则会去掉他的权限，但机器上的账号不会自动删除（会提示）。

set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
HOSTS="$DIR/hosts.conf"
USERS="$DIR/users.conf"
OUT="$DIR/out"
POLICY="$OUT/policy.hujson"
DO_ACCOUNTS=0
DO_PUSH=0
for a in "$@"; do
	case "$a" in
	--accounts) DO_ACCOUNTS=1 ;;
	--push) DO_PUSH=1 ;;
	*) echo "未知参数：$a"; exit 2 ;;
	esac
done

err=0
bad() { echo "[错误] $*"; err=1; }
strip() { sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$1"; }

[ -f "$HOSTS" ] || { echo "缺少 ${HOSTS}（参考 hosts.conf.example）"; exit 2; }
[ -f "$USERS" ] || { echo "缺少 ${USERS}（参考 users.conf.example）"; exit 2; }

# ---------- 校验 ----------
HOST_LIST=""
while read -r h admin _dir; do
	case "$h" in *[!a-z0-9-]* | "") bad "机器名「${h}」只能用小写字母、数字和连字符" ;; esac
	[ -n "${admin:-}" ] || bad "机器 $h 没写管理员账号"
	case " $HOST_LIST " in *" $h "*) bad "机器 $h 重复" ;; esac
	HOST_LIST="$HOST_LIST $h"
done <<<"$(strip "$HOSTS")"

LOGINS=" "
ACCOUNTS=" "
while read -r login acct hosts; do
	[ -z "${login:-}" ] && continue
	case "$login" in *@*) ;; *) bad "「${login}」不像 Tailscale 登录名（应形如 alice@github）" ;; esac
	case "$acct" in u_*) ;; *) bad "${login} 的本地账号「${acct}」必须以 u_ 开头（避免和 console、管理员等系统账号冲突）" ;; esac
	case "$acct" in *[!a-z0-9_]*) bad "本地账号「${acct}」只能用小写字母、数字和下划线" ;; esac
	case "$LOGINS" in *" $login "*) bad "用户 $login 出现了不止一行（一个人只写一行，多台机器写在同一行）" ;; esac
	case "$ACCOUNTS" in *" $acct "*) bad "本地账号 $acct 被不止一个人使用（一个账号只能属于一个人）" ;; esac
	LOGINS="$LOGINS$login "
	ACCOUNTS="$ACCOUNTS$acct "
	[ -n "${hosts:-}" ] || bad "$login 没有分配任何机器"
	for h in ${hosts:-}; do
		case " $HOST_LIST " in *" $h "*) ;; *) bad "$login 被分配到 ${h}，但 hosts.conf 里没有这台机器" ;; esac
	done
done <<<"$(strip "$USERS")"
[ "$err" -eq 0 ] || { echo "两张表有错误，没有生成任何东西"; exit 1; }

# ---------- 生成访问规则 ----------
mkdir -p "$OUT"
q() { printf '"%s"' "$1"; }
tags_of() { local t="" h; for h in $1; do t="$t, \"tag:$h\""; done; echo "${t#, }"; }
{
	echo "// 由 admin/sync.sh 于 $(date '+%Y-%m-%d %H:%M') 生成。不要在后台手改：改 admin/users.conf / hosts.conf 后重新同步。"
	echo "{"
	echo '    "tagOwners": {'
	echo '        "tag:mac": ["autogroup:admin"],'
	for h in $HOST_LIST; do echo "        \"tag:$h\": [\"autogroup:admin\"],"; done
	echo '    },'
	echo '    "grants": ['
	echo '        {"src": ["autogroup:admin"], "dst": ["*"], "ip": ["*"]},'
	echo '        {"src": ["autogroup:member"], "dst": ["autogroup:self"], "ip": ["*"]},'
	while read -r login acct hosts; do
		[ -z "${login:-}" ] && continue
		echo "        {\"src\": [$(q "$login")], \"dst\": [$(tags_of "$hosts")], \"ip\": [\"tcp:22\", \"udp:60000-61000\"]},"
	done <<<"$(strip "$USERS")"
	echo '    ],'
	echo '    "ssh": ['
	echo '        {"action": "accept", "src": ["autogroup:admin"], "dst": ["tag:mac"], "users": ["autogroup:nonroot"]},'
	while read -r login acct hosts; do
		[ -z "${login:-}" ] && continue
		echo "        {\"action\": \"accept\", \"src\": [$(q "$login")], \"dst\": [$(tags_of "$hosts")], \"users\": [$(q "$acct")]},"
	done <<<"$(strip "$USERS")"
	echo '        {"action": "check", "src": ["autogroup:member"], "dst": ["autogroup:self"], "users": ["autogroup:nonroot", "root"]},'
	echo '    ],'
	echo "}"
} >"$POLICY"
plutil -convert xml1 -o /dev/null - <<<"$(sed -e 's#^[[:space:]]*//.*##' -e 's#,\([[:space:]]*[]}]\)#\1#g' "$POLICY" | tr -d '\n' | sed -e 's#,\([[:space:]]*[]}]\)#\1#g')" 2>/dev/null &&
	echo "[OK] 规则已生成：admin/out/policy.hujson" || bad "生成的规则格式有误：$POLICY"

# ---------- 分配情况 ----------
echo
echo "== 分配情况"
for h in $HOST_LIST; do
	who=""
	while read -r login acct hosts; do
		[ -z "${login:-}" ] && continue
		case " $hosts " in *" $h "*) who="$who ${acct}（${login}）" ;; esac
	done <<<"$(strip "$USERS")"
	echo "  ${h}：${who:- 无人}"
done
echo
echo "== 用户的连接命令"
while read -r login acct hosts; do
	[ -z "${login:-}" ] && continue
	for h in $hosts; do echo "  $login → ssh $acct@$h"; done
done <<<"$(strip "$USERS")"

# ---------- 补建账号 ----------
if [ "$DO_ACCOUNTS" = "1" ]; then
	echo
	echo "== 检查各机器上的账号（经 Tailscale SSH，本机 Tailscale 需登录管理员账号）"
	while read -r h admin dir; do
		dir="${dir:-/usr/local/mac-fleet}"
		need=""
		while read -r login acct hosts; do
			[ -z "${login:-}" ] && continue
			case " $hosts " in *" $h "*) need="$need $acct" ;; esac
		done <<<"$(strip "$USERS")"
		need="${need# }"
		[ -z "$need" ] && { echo "  ${h}：没有分配用户，跳过"; continue; }
		# ssh -n / </dev/tty：不让 ssh 读走循环的输入，否则后面的机器会被跳过
		if ! missing="$(ssh -n -o BatchMode=yes -o ConnectTimeout=15 "$admin@$h" "for u in $need; do id -u \$u >/dev/null 2>&1 || printf '%s ' \$u; done" 2>/dev/null)"; then
			echo "  ${h}：连不上（以 $admin 身份），跳过"
			continue
		fi
		existing="$(ssh -n -o BatchMode=yes "$admin@$h" "dscl . -list /Users | grep '^u_' | tr '\n' ' '" 2>/dev/null)"
		for u in $existing; do case " $need " in *" $u "*) ;; *) echo "  ${h}：账号 $u 已不在分配表里（不会自动删除；确认后可手动删：sudo sysadminctl -deleteUser ${u}）" ;; esac; done
		if [ -z "$missing" ]; then
			echo "  ${h}：账号齐全（${need}）"
			continue
		fi
		echo "  ${h}：需要新建 ${missing}——下面会要求输入 $h 上 $admin 的 sudo 密码"
		ssh -t "$admin@$h" "sudo FLEET_CONF=/nonexistent MANAGED_USERS='$need' bash '$dir/scripts/20-accounts.sh' --apply --yes" </dev/tty ||
			echo "  ${h}：开户没有完全成功，见上面的输出"
	done <<<"$(strip "$HOSTS")"
fi

# ---------- 推送规则 ----------
if [ "$DO_PUSH" = "1" ]; then
	echo
	. "$DIR/push-policy.sh"
	push_policy "$POLICY"
else
	echo
	echo "下一步：把 admin/out/policy.hujson 的内容整段粘贴到 Tailscale 后台 Access controls（或用 --push 自动推送）"
fi
