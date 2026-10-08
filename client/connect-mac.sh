#!/bin/bash
# mac-fleet 客户端一键接入（macOS）：安装 Tailscale → 检查代理冲突 → 登录管理员的私有网络 → 测试 SSH。
#
# 用法（推荐，管理员用 fleet user add 生成接入码）：
#   bash connect-mac.sh --code <接入码> [本地账号@机器名]
#   例：bash connect-mac.sh --code tskey-auth-… u_alice@mm-us-01
# 旧用法（邀请链接 + 浏览器登录）：bash connect-mac.sh <网络名> [本地账号@机器名]
#
# 需要人工的地方：
#   1. 第一次安装时：输入电脑密码；系统弹窗「允许添加 VPN 配置」「允许网络扩展」各点一次
#   2. 只有旧用法需要浏览器登录；接入码用法不用注册任何账号

set -u
CODE=""
if [ "${1:-}" = "--code" ]; then
	CODE="${2:-}"
	shift 2 2>/dev/null || shift $#
	TAILNET="(接入码)"
else
	TAILNET="${1:-}"
	shift 2>/dev/null
fi
TARGET="${1:-}"
APP="/Applications/Tailscale.app"
TS="$APP/Contents/MacOS/Tailscale"
PKG_URL="https://pkgs.tailscale.com/stable/Tailscale-latest-macos.pkg"

say() { printf '%s\n' "$*"; }
ok() { printf '[OK]   %s\n' "$*"; }
bad() { printf '[需处理] %s\n' "$*"; }

if [ -n "$CODE" ]; then
	case "$CODE" in
	tskey-auth-*) ;;
	tskey-client-*)
		bad "这是管理员的 OAuth 凭证，不是接入码！不要使用，也不要再发给任何人；请让管理员立刻在后台作废它"
		exit 2
		;;
	*)
		bad "接入码应以 tskey-auth- 开头，请核对管理员发给你的内容"
		exit 2
		;;
	esac
fi
if [ -z "$TAILNET" ] || { [ "$TAILNET" = "(接入码)" ] && [ -z "$CODE" ]; }; then
	say "用法：bash connect-mac.sh --code <接入码> [本地账号@机器名]"
	say "网络名和账号由管理员告诉你，例如：bash connect-mac.sh xxx.github u_alice@mm-us-01"
	exit 2
fi

ts_json_field() {
	local f v
	f="$(mktemp)"
	"$TS" status --json >"$f" 2>/dev/null
	v="$(plutil -extract "$1" raw "$f" 2>/dev/null)"
	rm -f "$f"
	echo "$v"
}

# ---- 1. 安装 ----
say "== 1/4 安装 Tailscale"
if [ -d "$APP" ]; then
	ok "已安装 $(defaults read "$APP/Contents/Info" CFBundleShortVersionString 2>/dev/null)"
else
	pkg="$(mktemp -d)/Tailscale.pkg"
	say "下载官方安装包…"
	curl -fL --progress-bar -o "$pkg" "$PKG_URL" || { bad "下载失败：检查网络，或手动到 https://tailscale.com/download 下载"; exit 1; }
	say "安装需要输入电脑密码："
	sudo installer -pkg "$pkg" -target / || { bad "安装失败"; exit 1; }
	rm -f "$pkg"
	ok "安装完成"
fi

# ---- 2. 代理冲突 ----
say "== 2/4 检查代理软件"
ip="$(dscacheutil -q host -a name controlplane.tailscale.com 2>/dev/null | awk '/ip_address/ {print $2; exit}')"
case "$ip" in
198.18.* | 198.19.*)
	bad "你的代理软件（Clash 一类）开着 Fake-IP，Tailscale 会连不上。请在代理软件里加三项设置后重新运行本脚本："
	say "  ① DNS → Fake-IP 过滤：+.tailscale.com  +.tailscale.io  +.ts.net"
	say "  ② 虚拟网卡（TUN）→ 排除网段：100.64.0.0/10"
	say "  ③ 规则（放最前面）：DOMAIN-SUFFIX,tailscale.com,DIRECT  DOMAIN-SUFFIX,ts.net,DIRECT  IP-CIDR,100.64.0.0/10,DIRECT,no-resolve"
	exit 1
	;;
"") bad "解析不到 Tailscale 服务器，检查网络后重试"; exit 1 ;;
*) ok "没有代理冲突（${ip}）" ;;
esac

# ---- 3. 登录 ----
say "== 3/4 登录私有网络 $TAILNET"
open "$APP"
cur_net() { ts_json_field CurrentTailnet.Name; }
if [ -n "$CODE" ]; then
	if [ "$(ts_json_field BackendState)" = "Running" ] && [ -n "$(ts_json_field 'Self.Tags.0')" ]; then
		ok "已经接入（本机 $(ts_json_field Self.DNSName)），接入码不用再用"
	else
		say "如果弹出「添加 VPN 配置」「网络扩展」，请点允许（系统设置 → 通用 → 登录项与扩展 → 网络扩展 里打开 Tailscale）"
		say "等待 Tailscale 就绪…"
		for _ in $(seq 1 60); do
			case "$(ts_json_field BackendState)" in NeedsLogin | Stopped | Running) break ;; esac
			sleep 3
		done
		if ! "$TS" login --auth-key="$CODE" --timeout=60s; then
			bad "接入码登录失败（原因见上一行）：接入码一次性、24 小时内有效，过期或已用过请找管理员重新生成（fleet user code 你的名字）"
			exit 1
		fi
		"$TS" up >/dev/null 2>&1
		sleep 3
		[ "$(ts_json_field BackendState)" = "Running" ] || { bad "登录后没有连上（状态 $(ts_json_field BackendState)），在菜单栏 Tailscale 里点 Connect 后重新运行"; exit 1; }
		ok "已接入（本机 $(ts_json_field Self.DNSName)）"
	fi
elif [ "$(ts_json_field BackendState)" = "Running" ] && [ "$(cur_net)" = "$TAILNET" ]; then
	ok "已在网络 $TAILNET 中（本机 $(ts_json_field Self.DNSName)）"
else
	say "请按顺序操作（第一次需要，以后不用）："
	say "  a. 允许系统弹出的「添加 VPN 配置」和「网络扩展」（在 系统设置 → 通用 → 登录项与扩展 → 网络扩展 里打开 Tailscale）"
	say "  b. 在浏览器里打开管理员发给你的邀请链接，用你自己的账号（GitHub / 微软 / passkey）登录并接受"
	say "  c. 在 Tailscale 窗口点「Sign in」，用同一个账号登录；如果让你选网络，选「${TAILNET}」"
	say "  （浏览器里若已登录别的 Tailscale 账号，请用无痕窗口打开链接）"
	say "等待登录完成（最多 10 分钟）…"
	for _ in $(seq 1 120); do
		[ "$(ts_json_field BackendState)" = "Running" ] && [ -n "$(cur_net)" ] && break
		sleep 5
	done
	st="$(ts_json_field BackendState)"
	net="$(cur_net)"
	if [ "$st" != "Running" ]; then bad "还没有登录成功（状态 ${st:-未知}）。完成登录后重新运行本脚本"; exit 1; fi
	if [ "$net" != "$TAILNET" ]; then
		bad "登录进了网络「${net}」，不是「${TAILNET}」。在菜单栏 Tailscale → Settings → Accounts 里退出，再登录并选「${TAILNET}」"
		exit 1
	fi
	ok "已加入 ${TAILNET}（本机 $(ts_json_field Self.DNSName)）"
fi

# ---- 4. 可以连的 Mac 与 SSH 测试 ----
say "== 4/4 可连接的 Mac"
"$TS" status 2>/dev/null | awk '/tagged-devices/ {print "  " $2 "  " $1}'
if [ -n "$TARGET" ]; then
	host="${TARGET#*@}"
	say "测试 ssh ${TARGET}…"
	if ssh -o BatchMode=yes -o ConnectTimeout=20 -o StrictHostKeyChecking=accept-new "$TARGET" 'echo "登录成功：$(whoami)@$(hostname)"'; then
		ok "以后直接执行：ssh $TARGET"
		path="$("$TS" ping -c 1 "$host" 2>&1 | tail -1)"
		say "  线路：$path"
	else
		bad "SSH 没连上：确认管理员已在访问规则里给你分配了 ${TARGET}，或联系管理员"
		exit 1
	fi
else
	say "连接命令：ssh <管理员分配给你的账号>@<上面列出的机器名>"
fi
