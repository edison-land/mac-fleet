#!/bin/bash
# 10 电源：断电后自动开机、接通电源时开机、主机不睡眠。
# 用法：
#   bash scripts/10-power.sh             检查
#   sudo bash scripts/10-power.sh --apply  执行
#   bash scripts/10-power.sh --probe     实测「接通电源时启动」每个选项分别改了什么（pmset 与 NVRAM）

ALLOWED_FLAGS="--probe"
. "$(dirname "$0")/lib.sh"
fleet_init "$@"

# 电源相关状态快照：pmset 的自定义值 + NVRAM（「接通电源时启动」可能不在 pmset 里）
power_snapshot() {
	pmset -g custom 2>&1 | sed 's/^/pmset: /'
	# NVRAM 里有些值很长（令牌、蓝牙信息），只保留前 100 个字符，够看出是否变化
	nvram -p 2>/dev/null | awk '{ v = $0; if (length(v) > 100) v = substr(v, 1, 100) "…"; print "nvram: " v }'
}

if has_flag --probe; then
	step "探测：「接通电源时启动」每个选项对应的设置"
	info "当前 autorestart=$(pmset_get autorestart) autorestartatconnect=$(pmset_get autorestartatconnect)"
	prev="$(mktemp)"
	cur="$(mktemp)"
	power_snapshot >"$prev"
	printf '\n先在 系统设置 → 能源 里看「接通电源时启动」当前选的是哪一项，输入它的名称后回车：' >/dev/tty
	read -r prev_label </dev/tty
	while :; do
		printf '\n把它切换到另一个选项，输入新选项的名称后回车（全部选项都试过后输入 q 结束）：' >/dev/tty
		read -r label </dev/tty
		[ "$label" = "q" ] && break
		power_snapshot >"$cur"
		echo "--- 「${prev_label}」→「${label}」"
		if cmp -s "$prev" "$cur"; then
			warn "pmset 和 NVRAM 都没有变化：这个选项存在别处（例如 SMC）"
		else
			diff "$prev" "$cur" | grep -E '^[<>]' | sed 's/^</  -/; s/^>/  +/'
			pass "已记录变化"
		fi
		cp "$cur" "$prev"
		prev_label="$label"
	done
	rm -f "$prev" "$cur"
	todo "探测完把「接通电源时启动」改回「始终」，并截图 能源 页面"
	todo "把上面所有「---」段落贴回来"
	summary
fi

require_backup

want_list="$(power_targets)"

step "pmset 设置"
# 用 here-string 而不是管道：管道里的 while 在子 shell 运行，PASS/FAIL 计数会丢
while IFS=: read -r key want desc; do
	cur="$(pmset_get "$key")"
	if [ "$cur" = "$want" ]; then
		pass "$key=${cur}（${desc}）"
		continue
	fi
	change "${key}：${cur:-未设置} → ${want}（${desc}）" pmset -a "$key" "$want"
	if [ "$MODE" = "apply" ]; then
		now="$(pmset_get "$key")"
		if [ "$now" = "$want" ]; then
			pass "$key 已是 $now"
		elif [ -z "$now" ]; then
			warn "$key 设置后在 pmset -g 里看不到：该机型/系统可能不支持这个键"
		else
			fail "$key 设置后仍是 $now"
		fi
	fi
done <<<"$want_list"

step "核对（可选）"
info "可在 系统设置 → 能耗 核对（退出并重新打开后，「接入电源时启动」显示「始终」，「显示器关闭时，防止自动进入睡眠」「唤醒以供网络访问」都已打开；窗口不会自动刷新）"

summary
