#!/bin/bash
# mac-fleet 公共函数库：由各步骤脚本 source，不单独执行。
#
# 约定
#   - 兼容 macOS 自带 bash 3.2：不用关联数组、mapfile、${var,,}；用户列表用空格分隔的字符串。
#   - 默认是检查模式（只读，不改任何东西），加 --apply 才执行修改，修改必须 sudo。
#   - 每一项输出一个标签：[PASS] [FAIL] [WARN] [TODO] [PLAN] [DO]，方便整段贴回来比对。
#   - 所有输出同时写入 logs/<脚本名>-<主机名>-<时间>.log；密码与恢复密钥只走终端，不进日志。

set -u

FLEET_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_NAME="$(basename "$0" .sh)"
TS="$(date +%Y%m%d-%H%M%S)"
MODE="check"
ASSUME_YES=0
PLAN_OVERRIDE=""
EXTRA_FLAGS=" "
RERUN_ARGS=""  # 提示 --apply 命令时需要原样带上的参数
N_PASS=0
N_FAIL=0
N_WARN=0
N_TODO=0
N_PLAN=0

# ---------- 输出 ----------

pass() { N_PASS=$((N_PASS + 1)); echo "[PASS] $*"; }
fail() { N_FAIL=$((N_FAIL + 1)); echo "[FAIL] $*"; }
warn() { N_WARN=$((N_WARN + 1)); echo "[WARN] $*"; }
todo() { N_TODO=$((N_TODO + 1)); echo "[TODO] $*"; }
info() { echo "       $*"; }
step() { echo; echo "== $*"; }
die()  { echo "[FAIL] $*"; exit 2; }

# change "说明" 命令 参数...
# 检查模式只打印计划；--apply 时执行，失败计入 FAIL。
change() {
	local desc="$1"
	shift
	N_PLAN=$((N_PLAN + 1))
	if [ "$MODE" = "apply" ]; then
		echo "[DO]   $desc"
		"$@"
		local rc=$?
		if [ $rc -ne 0 ]; then
			fail "命令返回 ${rc}：$*"
			return $rc
		fi
	else
		echo "[PLAN] $desc"
		echo "         \$ $*"
	fi
	return 0
}

# confirm "提示"：必须手动输入 yes。检查模式下不询问。
confirm() {
	[ "$MODE" = "apply" ] || return 0
	[ "$ASSUME_YES" -eq 1 ] && return 0
	local ans=""
	printf '%s\n请输入 yes 继续，其他任意输入跳过：' "$1" >/dev/tty
	read -r ans </dev/tty
	[ "$ans" = "yes" ]
}

has_flag() { case "$EXTRA_FLAGS" in *" $1 "*) return 0 ;; esac; return 1; }

summary() {
	echo
	echo "== 汇总：PASS $N_PASS · FAIL $N_FAIL · WARN $N_WARN · TODO $N_TODO · 待执行修改 $N_PLAN"
	if [ "$MODE" = "check" ] && [ "$N_PLAN" -gt 0 ]; then
		echo "   这是检查模式，没有做任何修改。确认上面的 [PLAN] 无误后执行："
		echo "   sudo bash scripts/${SCRIPT_NAME}.sh --apply${RERUN_ARGS}"
	fi
	echo "   日志：${LOG_FILE#"$FLEET_ROOT"/}"
	# 等 tee 写完再退出，避免最后几行落在提示符之后
	sleep 0.2
	[ "$N_FAIL" -eq 0 ]
	exit $?
}

# ---------- 初始化 ----------

usage_common() {
	cat <<EOF
用法：bash scripts/${SCRIPT_NAME}.sh [--apply] [--yes] [--plan=A|B] ${ALLOWED_FLAGS:-}
  （默认）检查模式：只读，打印当前状态和将要做的修改
  --apply   执行修改（需要 sudo）
  --yes     跳过逐项确认（谨慎使用）
  --plan=A|B  临时覆盖配置里的 FILEVAULT_PLAN
EOF
}

fleet_init() {
	local a
	for a in "$@"; do
		case "$a" in
		--apply) MODE="apply" ;;
		--check | --dry-run) MODE="check" ;;
		--yes) ASSUME_YES=1 ;;
		--plan=A | --plan=B) PLAN_OVERRIDE="${a#--plan=}"; RERUN_ARGS="$RERUN_ARGS $a" ;;
		-h | --help) usage_common; exit 0 ;;
		*)
			case " ${ALLOWED_FLAGS:-} " in
			*" $a "*) EXTRA_FLAGS="$EXTRA_FLAGS$a "; RERUN_ARGS="$RERUN_ARGS $a" ;;
			*) usage_common; die "未知参数：$a" ;;
			esac
			;;
		esac
	done

	# 配置：host.conf 可选（本机专用），其余用 defaults.sh；环境变量优先于默认值
	CONF_FILE="${FLEET_CONF:-$FLEET_ROOT/config/host.conf}"
	if [ -f "$CONF_FILE" ]; then
		# shellcheck source=/dev/null
		. "$CONF_FILE"
	else
		CONF_FILE="（无 host.conf，使用默认值与环境变量）"
	fi
	# shellcheck source=/dev/null
	. "$FLEET_ROOT/config/defaults.sh"
	[ -n "$PLAN_OVERRIDE" ] && FILEVAULT_PLAN="$PLAN_OVERRIDE"
	case "${FILEVAULT_PLAN:-}" in A | B) ;; *) die "FILEVAULT_PLAN 只能是 A 或 B" ;; esac

	if [ -z "${ADMIN_USER:-}" ]; then
		ADMIN_USER="${SUDO_USER:-$(id -un)}"
	fi
	[ "$ADMIN_USER" = "root" ] && die "无法确定管理员账号：请在配置里填写 ADMIN_USER"

	if [ "$MODE" = "apply" ] && [ "$(id -u)" -ne 0 ]; then
		die "--apply 需要 root：sudo bash scripts/${SCRIPT_NAME}.sh --apply${RERUN_ARGS}"
	fi

	mkdir -p "$FLEET_ROOT/logs" "$FLEET_ROOT/state"
	LOG_FILE="$FLEET_ROOT/logs/${SCRIPT_NAME}-$(hostname -s)-${TS}.log"
	: >"$LOG_FILE"
	# 用 sudo 运行时，把日志和状态目录交还给管理员，避免之后普通身份写不进去
	if [ -n "${SUDO_UID:-}" ]; then
		chown "$SUDO_UID" "$FLEET_ROOT/logs" "$FLEET_ROOT/state" "$LOG_FILE" 2>/dev/null
	fi
	exec > >(tee -a "$LOG_FILE") 2>&1

	echo "mac-fleet · ${SCRIPT_NAME} · 模式=${MODE} · 方案=${FILEVAULT_PLAN}"
	echo "主机 $(scutil --get ComputerName 2>/dev/null) · macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion)) · $(date '+%Y-%m-%d %H:%M:%S %z')"
	echo "管理员 $ADMIN_USER · 配置 ${CONF_FILE#"$FLEET_ROOT"/}"
}

# ---------- 读取系统状态（都不需要 root） ----------

# version_ge 26.6.2 26.5 → 真
version_ge() {
	awk -v a="$1" -v b="$2" 'BEGIN {
		na = split(a, x, "."); nb = split(b, y, ".");
		n = (na > nb) ? na : nb;
		for (i = 1; i <= n; i++) {
			xi = (i <= na) ? x[i] + 0 : 0; yi = (i <= nb) ? y[i] + 0 : 0;
			if (xi > yi) exit 0; if (xi < yi) exit 1;
		}
		exit 0
	}'
}

model_name() { system_profiler SPHardwareDataType 2>/dev/null | awk -F': ' '/Model Name/ {print $2; exit}'; }
model_id() { sysctl -n hw.model; }
chip_name() { sysctl -n machdep.cpu.brand_string; }
# "Apple M4 Pro" → 4；非 Apple 芯片返回 0
chip_gen() { chip_name | sed -n 's/^Apple M\([0-9][0-9]*\).*/\1/p' | grep . || echo 0; }

pmset_get() { pmset -g 2>/dev/null | awk -v k="$1" '$1 == k {print $2; exit}'; }

user_exists() { dscl . -read "/Users/$1" UniqueID >/dev/null 2>&1; }
user_uid() { dscl . -read "/Users/$1" UniqueID 2>/dev/null | awk '{print $2}'; }
user_home() { dscl . -read "/Users/$1" NFSHomeDirectory 2>/dev/null | awk '{print $2}'; }
is_admin() { dsmemberutil checkmembership -U "$1" -G admin 2>/dev/null | grep -q "is a member"; }
has_secure_token() { sysadminctl -secureTokenStatus "$1" 2>&1 | grep -q "ENABLED"; }
home_mode() { local h; h="$(user_home "$1")"; [ -d "$h" ] && stat -f %Lp "$h"; }

group_exists() { dscl . -read "/Groups/$1" PrimaryGroupID >/dev/null 2>&1; }
group_members() { dscl . -read "/Groups/$1" GroupMembership 2>/dev/null | sed 's/^GroupMembership: *//'; }
# 访问组里嵌套的整组（系统设置里选「管理员」时出现），输出组名，空格分隔
group_nested() {
	local guid
	for guid in $(dscl . -read "/Groups/$1" NestedGroups 2>/dev/null | sed 's/^NestedGroups: *//'); do
		dscl . -search /Groups GeneratedUID "$guid" 2>/dev/null | awk 'NR == 1 {printf "%s ", $1}'
	done
}
# 访问组的人类可读描述
acl_describe() {
	local m n
	m="$(group_members "$1")"
	n="$(group_nested "$1")"
	echo "成员=[${m}] 整组=[${n% }]"
}
in_list() { case " $2 " in *" $1 "*) return 0 ;; esac; return 1; }

# 读 launchd 的禁用表：enabled / disabled / 空（未登记，按系统默认＝关闭）
svc_state() { launchctl print-disabled system 2>/dev/null | awk -v k="\"$1\"" '$1 == k {print $3; exit}'; }
port_listening() { netstat -anv -p tcp 2>/dev/null | awk '$6 == "LISTEN" {print $4}' | grep -Eq "[.:]$1\$"; }

fv_status() { fdesetup status 2>/dev/null | head -1; }
fv_is_on() { fv_status | grep -q "FileVault is On"; }
fv_is_off() { fv_status | grep -q "FileVault is Off"; }
autologin_user() { defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>/dev/null; }
console_user() { stat -f %Su /dev/console 2>/dev/null; }
guest_enabled() { sysadminctl -guestAccount status 2>&1 | grep -qi "guest account enabled"; }
fw_state() { /usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate 2>/dev/null | sed -n 's/.*State = \([0-9]\).*/\1/p'; }
su_get() { defaults read /Library/Preferences/com.apple.SoftwareUpdate "$1" 2>/dev/null; }

boot_epoch() { sysctl -n kern.boottime | sed -n 's/.*sec = \([0-9]*\),.*/\1/p'; }

# ps 的 etime（[[dd-]hh:]mm:ss）→ 秒
etime_to_sec() {
	echo "$1" | awk '{
		d = 0; s = $1;
		if (index(s, "-")) { split(s, p, "-"); d = p[1]; s = p[2] }
		n = split(s, t, ":"); sec = 0;
		for (i = 1; i <= n; i++) sec = sec * 60 + t[i];
		print d * 86400 + sec
	}'
}

# 列出 UU 进程：每行 "pid 用户 已运行秒数"
uu_procs() {
	local pid
	for pid in $(pgrep -x "$UU_PROC" 2>/dev/null); do
		echo "$pid $(ps -o user= -p "$pid" | tr -d ' ') $(etime_to_sec "$(ps -o etime= -p "$pid" | tr -d ' ')")"
	done
}

ethernet_device() { networksetup -listallhardwareports 2>/dev/null | awk '/^Hardware Port: Ethernet$/ {getline; print $2; exit}'; }
default_iface() { route -n get default 2>/dev/null | awk '/interface:/ {print $2}'; }
wifi_device() { networksetup -listallhardwareports 2>/dev/null | awk '/^Hardware Port: Wi-Fi$/ {getline; print $2; exit}'; }
iface_has_ipv4() { [ -n "$1" ] && ifconfig "$1" 2>/dev/null | grep -q "inet "; }

# 实际在用的物理网络：ethernet / wifi / none。
# 不看默认路由：开着代理 TUN 时默认路由会指向 utun。
net_mode() {
	local eth wifi
	eth="$(ethernet_device)"
	wifi="$(wifi_device)"
	if iface_has_ipv4 "$eth" && ifconfig "$eth" | grep -q "status: active"; then
		echo ethernet
	elif iface_has_ipv4 "$wifi"; then
		echo wifi
	else
		echo none
	fi
}

# Wi-Fi 加密方式，如 WPA2_PSK / WPA3_SAE / NONE。macOS 15+ 会隐藏 SSID，但加密方式仍可读
wifi_security() { ipconfig getsummary "$1" 2>/dev/null | awk -F' : ' '/^ +Security :/ {print $2; exit}'; }
wifi_signal() { system_profiler SPAirPortDataType 2>/dev/null | awk -F': ' '/Signal \/ Noise/ {print $2; exit}'; }
# 已保存的 Wi-Fi（按优先顺序），每行一个
wifi_preferred() { networksetup -listpreferredwirelessnetworks "$1" 2>/dev/null | sed '1d; s/^[[:space:]]*//'; }
# Wi-Fi 密码在系统钥匙串里 → 开机后无人登录也能自动连上
wifi_in_system_keychain() { security find-generic-password -D "AirPort network password" -a "$1" /Library/Keychains/System.keychain >/dev/null 2>&1; }
ipv4_list() { ifconfig 2>/dev/null | awk '/^[a-z]/ {i = $1} /inet / && $2 != "127.0.0.1" {sub(":", "", i); printf "%s=%s ", i, $2}'; }

# 最近一次 00-preflight 的备份目录
latest_backup() { ls -1d "$FLEET_ROOT"/state/backup-* 2>/dev/null | tail -1; }

require_backup() {
	[ "$MODE" = "apply" ] || return 0
	[ -n "$(latest_backup)" ] || die "没有找到 state/backup-*：修改前先运行 bash scripts/00-preflight.sh 记录当前设置（更新脚本时请用 ditto -x -k 覆盖解压，整个替换文件夹会丢掉 state/）"
}

# 远程用户 = 控制台账号以外、由本工具管理的账号
managed_users() { echo "${MANAGED_USERS:-}"; }
ssh_allowed_users() { echo "$ADMIN_USER ${SSH_EXTRA_USERS:-}"; }
screen_allowed_users() {
	if [ "${SCREEN_INCLUDE_ADMIN:-1}" = "1" ]; then echo "$ADMIN_USER ${SCREEN_SHARE_USERS:-}"; else echo "${SCREEN_SHARE_USERS:-}"; fi
}

WATCHDOG_LABEL="local.mac-fleet.uu-watchdog"
SSHD_DROPIN="/etc/ssh/sshd_config.d/200-mac-fleet.conf"
ACL_SSH="com.apple.access_ssh"
ACL_SCREEN="com.apple.access_screensharing"

# ---------- Tailscale（开源版 tailscaled） ----------
BREW="${BREW:-/opt/homebrew/bin/brew}"
TS_CLI="/opt/homebrew/bin/tailscale"
TSD_SRC="/opt/homebrew/bin/tailscaled"
TS_PLIST="/Library/LaunchDaemons/com.tailscale.tailscaled.plist"

# 从 tailscale status --json 取字段，如 BackendState、Self.TailscaleIPs.0
ts_field() {
	local f v
	[ -x "$TS_CLI" ] || return 0
	f="$(mktemp)"
	"$TS_CLI" status --json >"$f" 2>/dev/null
	v="$(plutil -extract "$1" raw "$f" 2>/dev/null)"
	rm -f "$f"
	echo "$v"
}
# 从 tailscale debug prefs 取字段，如 RunSSH
ts_pref() {
	local f v
	[ -x "$TS_CLI" ] || return 0
	f="$(mktemp)"
	"$TS_CLI" debug prefs >"$f" 2>/dev/null
	v="$(plutil -extract "$1" raw "$f" 2>/dev/null)"
	rm -f "$f"
	echo "$v"
}

# 电源目标值，每行「键:目标值:说明」。
# 系统设置里「接入电源时启动」是三选一（2026-10-06 在 M4 Mac mini / macOS 26.5.2 实测）：
#   从不 = autorestart 0 + autorestartatconnect 0
#   断电后 = autorestart 1 + autorestartatconnect 0
#   始终 = autorestart 0 + autorestartatconnect 1（含断电后）
# 两个都设成 1 时，系统设置会把 autorestart 改回 0，所以这里严格对齐上表。
power_targets() {
	if [ "${POWER_ON_CONNECT:-1}" = "1" ]; then
		echo "autorestartatconnect:1:接入电源时启动＝始终（含断电后）"
		echo "autorestart:0:「始终」时系统要求为 0"
	else
		echo "autorestart:1:接入电源时启动＝断电后"
		echo "autorestartatconnect:0:「断电后」时为 0"
	fi
	echo "sleep:0:主机永不睡眠（显示器关闭时防止自动进入睡眠）"
	echo "womp:1:唤醒以供网络访问"
	echo "displaysleep:${DISPLAY_SLEEP_MIN}:显示器 ${DISPLAY_SLEEP_MIN} 分钟后关闭"
}
