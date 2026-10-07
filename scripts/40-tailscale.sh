#!/bin/bash
# 40 Tailscale：安装开源版 tailscaled 作为系统服务（开机即运行，不需要有人登录），
# 加入私有网络并打开 Tailscale SSH。macOS 上只有开源版能当 Tailscale SSH 的服务端。
#
# 用法：bash scripts/40-tailscale.sh  →  sudo bash scripts/40-tailscale.sh --apply
# 登录：执行时直接按回车，会打印二维码和链接，用手机扫码、以管理员身份批准即可；
#       也可以粘贴管理后台生成的带标签认证密钥（不进日志）；或者用环境变量直接传入，适合远程部署：
#         sudo TS_AUTHKEY=tskey-auth-… bash scripts/40-tailscale.sh --apply
#       （这样密钥会留在 shell 历史里，所以要用一次性、1 天有效的密钥）

. "$(dirname "$0")/lib.sh"
fleet_init "$@"
require_backup

TS_ENABLE="${TS_ENABLE:-1}"
TS_HOSTNAME="${TS_HOSTNAME:-$(echo "$HOST_NAME" | tr '[:upper:]' '[:lower:]')}"
TS_TAGS="${TS_TAGS:-tag:mac}"
TS_ACCEPT_DNS="${TS_ACCEPT_DNS:-0}"

if [ "$TS_ENABLE" != "1" ]; then
	info "TS_ENABLE=0，跳过"
	summary
fi

brew_install_tailscale() {
	# Homebrew 拒绝以 root 运行，用管理员身份安装
	sudo -u "$ADMIN_USER" -H env HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_ENV_HINTS=1 "$BREW" install --quiet --formula tailscale
}

install_daemon() {
	# tailscaled 自带的安装命令：写入 /Library/LaunchDaemons/com.tailscale.tailscaled.plist，
	# 并把程序复制到 /usr/local/bin/tailscaled。以后 brew 升级后要重跑本步骤
	"$TSD_SRC" install-system-daemon
}

ts_up() {
	local key="" kf dns
	dns="$([ "$TS_ACCEPT_DNS" = "1" ] && echo true || echo false)"
	if [ -n "${TS_AUTHKEY:-}" ]; then
		key="$TS_AUTHKEY"
		echo "  使用环境变量 TS_AUTHKEY 里的认证密钥"
	else
		printf '粘贴认证密钥（tskey-auth-…，输入时不显示）；没有密钥直接按回车，改用扫码登录：' >/dev/tty
		read -rs key </dev/tty
		printf '\n' >/dev/tty
	fi
	if [ -z "$key" ]; then
		# 扫码登录：用手机或任意电脑打开链接，以管理员（标签所有者）身份批准，设备就带着标签加入
		echo "  下面会打印登录链接和二维码：用手机扫码（或在任意电脑打开链接），用管理员账号批准即可"
		"$TS_CLI" up --ssh --hostname="$TS_HOSTNAME" --advertise-tags="$TS_TAGS" \
			--accept-dns="$dns" --qr --timeout=600s
		return $?
	fi
	case "$key" in tskey-*) ;; *) echo "看起来不是认证密钥（应以 tskey- 开头）"; return 1 ;; esac
	kf="$(mktemp)"
	chmod 600 "$kf"
	printf '%s' "$key" >"$kf"
	# 用认证密钥时，设备标签以密钥上设置的为准，不再另外指定
	"$TS_CLI" up --ssh --hostname="$TS_HOSTNAME" \
		--accept-dns="$([ "$TS_ACCEPT_DNS" = "1" ] && echo true || echo false)" \
		--auth-key="file:$kf" --timeout=60s
	local rc=$?
	rm -f "$kf"
	return $rc
}

ts_set() {
	"$TS_CLI" set --ssh=true --hostname="$TS_HOSTNAME" \
		--accept-dns="$([ "$TS_ACCEPT_DNS" = "1" ] && echo true || echo false)"
}

step "前提"
if [ -x "$BREW" ]; then pass "Homebrew：${BREW}（$("$BREW" --version 2>/dev/null | head -1)）"; else fail "没有 Homebrew（${BREW}）：先安装 Homebrew，或在配置里改 BREW 路径"; summary; fi
if [ -d /Applications/Tailscale.app ]; then
	fail "装着 Tailscale 图形版：它不能当 SSH 服务端，且会和开源版冲突。先退出并删除 /Applications/Tailscale.app"
fi
if ifconfig 2>/dev/null | grep -q "inet 198\.18\."; then
	warn "发现代理软件的虚拟网卡（198.18.x，Clash / Surge 一类）：可能拦截 Tailscale 流量"
	todo "在代理软件里加直连规则：IP-CIDR 100.64.0.0/10、DOMAIN-SUFFIX tailscale.com、DOMAIN-SUFFIX ts.net"
fi

step "安装"
if [ -x "$TSD_SRC" ] && [ -x "$TS_CLI" ]; then
	pass "已安装：$("$TS_CLI" version 2>/dev/null | head -1)"
else
	change "用 Homebrew 安装开源版 tailscale（以 $ADMIN_USER 身份）" brew_install_tailscale
fi

step "系统服务"
if [ -f "$TS_PLIST" ]; then
	pass "系统服务已安装：$TS_PLIST"
else
	change "安装 tailscaled 系统服务（开机即运行）" install_daemon
fi
if [ "$MODE" = "apply" ]; then
	# 等守护进程起来
	for _ in 1 2 3 4 5 6 7 8 9 10; do "$TS_CLI" status >/dev/null 2>&1 && break; [ -S /var/run/tailscaled.socket ] && break; sleep 1; done
fi

step "加入私有网络（主机名 ${TS_HOSTNAME}，标签 ${TS_TAGS}）"
# 代理软件（Clash 等）的 Fake-IP 会把控制服务器解析成 198.18.x 假地址；tailscaled 绑定物理网卡直连，
# 连不上假地址，登录会一直卡住。提前发现并给出处理办法，而不是等到超时
cp_ip="$(dscacheutil -q host -a name controlplane.tailscale.com 2>/dev/null | awk '/ip_address/ {print $2; exit}')"
case "$cp_ip" in
198.18.* | 198.19.*)
	if [ "$(ts_field BackendState)" = "Running" ]; then
		warn "控制服务器被代理软件解析成假地址 ${cp_ip}（Fake-IP）。现在在线，但断线重连时可能连不上"
		todo "在代理的 DNS「Fake-IP 过滤」里加 +.tailscale.com、+.tailscale.io、+.ts.net，或关闭代理的 TUN 模式"
		cp_ip=""
	else
	fail "控制服务器被代理软件解析成假地址 ${cp_ip}（Fake-IP），tailscaled 会连不上、登录卡住"
	todo "二选一：① 关闭代理软件的虚拟网卡（TUN）模式；② 在代理的 DNS「Fake-IP 过滤」里加 +.tailscale.com、+.tailscale.io、+.ts.net"
	summary
	fi
	;;
"") [ "$(ts_field BackendState)" = "Running" ] || warn "解析不到控制服务器 controlplane.tailscale.com，检查网络" ;;
*) pass "控制服务器解析正常：$cp_ip" ;;
esac
state="$(ts_field BackendState)"
info "当前状态：${state:-未运行}"
if [ "$state" = "Running" ]; then
	pass "已登录私有网络：$(ts_field Self.DNSName) $(ts_field Self.TailscaleIPs.0)"
	change "同步设置（打开 Tailscale SSH、主机名 ${TS_HOSTNAME}）" ts_set
	cur_tags="$(ts_field Self.Tags.0)"
	[ -n "$cur_tags" ] && [ "$cur_tags" != "${TS_TAGS%%,*}" ] && warn "当前标签 $cur_tags 与配置 $TS_TAGS 不同；改标签需要重新认证"
else
	info "登录方式：执行时按回车用手机扫码批准（最省事）；批量部署时可改用管理后台生成的带标签认证密钥"
	change "登录私有网络（扫码批准或粘贴认证密钥）" ts_up
fi

if [ "$MODE" = "apply" ]; then
	step "结果"
	state="$(ts_field BackendState)"
	if [ "$state" = "Running" ]; then
		pass "已加入：$(ts_field Self.DNSName) · $(ts_field Self.TailscaleIPs.0) · 标签 $(ts_field Self.Tags.0)"
	else
		fail "状态是 ${state:-未知}，没有加入成功"
	fi
	if [ "$(ts_pref RunSSH)" = "true" ]; then pass "Tailscale SSH 已打开"; else fail "Tailscale SSH 没有打开"; fi
	step "到各中转节点的延迟（tailscale netcheck）"
	"$TS_CLI" netcheck 2>&1 | sed -n '/DERP latency/,$p' | head -12
fi

summary
