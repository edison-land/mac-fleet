#!/bin/bash
# 55 FileVault：按方案开启（B）或关闭（A）。
# 用法：
#   bash scripts/55-filevault.sh                         检查
#   sudo bash scripts/55-filevault.sh --apply --plan=A   关闭 FileVault（随后运行 50 设置自动登录）
#   sudo bash scripts/55-filevault.sh --apply --plan=B   开启 FileVault（会显示新的恢复密钥）
# 恢复密钥只显示在终端，不写进日志；看到后立刻存进密码管理器。

. "$(dirname "$0")/lib.sh"
fleet_init "$@"
require_backup

fv_disable() {
	echo "  按提示输入管理员账号名（${ADMIN_USER}）和密码："
	fdesetup disable </dev/tty
}

fv_enable() {
	echo "  按提示输入 $ADMIN_USER 的密码。恢复密钥只显示在下面的终端里，不会进入日志："
	# 输出直接送到终端，绕过 tee，防止恢复密钥落进日志文件
	fdesetup enable -user "$ADMIN_USER" </dev/tty >/dev/tty 2>&1
}

step "FileVault"
st="$(fv_status)"
info "当前：$st"
has_secure_token "$ADMIN_USER" || warn "$ADMIN_USER 没有 Secure Token，fdesetup 可能拒绝操作"

if [ "$FILEVAULT_PLAN" = "A" ]; then
	if fv_is_off; then
		pass "方案 A：FileVault 已关闭"
	elif echo "$st" | grep -qi "decryption in progress"; then
		info "正在解密，等它完成后重跑本脚本"
	else
		if confirm "将关闭 FileVault。之后任何人拿到这台机器、接上显示器开机，都会进入自动登录的账号。"; then
			change "关闭 FileVault" fv_disable
		else
			info "已跳过"
		fi
	fi
	[ "$MODE" = "apply" ] && info "现在：$(fv_status)"
	todo "FileVault 关闭后运行：sudo bash scripts/50-console-uu.sh --apply --plan=A"
else
	if fv_is_on; then
		pass "方案 B：FileVault 已开启"
	elif echo "$st" | grep -qi "encryption in progress"; then
		info "正在加密，等它完成后重跑本脚本"
	else
		if confirm "将开启 FileVault，并生成一个新的恢复密钥（旧的作废）。请准备好密码管理器。"; then
			change "开启 FileVault（用户 ${ADMIN_USER}）" fv_enable
			todo "把刚才终端里显示的恢复密钥存进密码管理器；不要存在这台 Mac 上"
		else
			info "已跳过"
		fi
	fi
	[ "$MODE" = "apply" ] && info "现在：$(fv_status)"
	[ -n "$(autologin_user)" ] && todo "方案 B 不应自动登录：运行 sudo bash scripts/50-console-uu.sh --apply --plan=B"
fi

summary
