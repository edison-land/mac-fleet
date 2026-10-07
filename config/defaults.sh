# mac-fleet 默认值：每项都只在「环境变量和 host.conf 都没给」时才生效。
# 这里不写任何个人信息；每台机器不同的值在执行时自动检测，或者在命令前用环境变量传入，例如：
#   sudo HOST_NAME=mm-us-01 TS_AUTHKEY=tskey-auth-… bash bootstrap.sh

# 主机名：默认取序列号后 6 位，如 mm-x7k2q9（只含字母数字和连字符）
if [ -z "${HOST_NAME:-}" ]; then
	_sn="$(ioreg -rd1 -c IOPlatformExpertDevice 2>/dev/null | awk -F'"' '/IOPlatformSerialNumber/ {print $4}')"
	HOST_NAME="mm-$(echo "${_sn:-unknown}" | tr '[:upper:]' '[:lower:]' | tail -c 7)"
fi
MIN_MACOS="${MIN_MACOS:-26.5}"
MIN_CHIP_GEN="${MIN_CHIP_GEN:-4}"

FILEVAULT_PLAN="${FILEVAULT_PLAN:-A}"            # A＝关闭 FileVault + 自动登录 console（无人值守）；B＝保留

ADMIN_USER="${ADMIN_USER:-}"                     # 空＝运行 sudo 的账号
ADMIN_PUBKEY="${ADMIN_PUBKEY:-}"                 # 空＝不写公钥
HARDEN_ADMIN_HOME="${HARDEN_ADMIN_HOME:-0}"      # 不动管理员家目录
FLEET_GROUP="${FLEET_GROUP:-fleetusers}"         # 远程用户的主组（不是 staff）
CONSOLE_USER="${CONSOLE_USER:-console}"
CONSOLE_FULLNAME="${CONSOLE_FULLNAME:-Console}"
MANAGED_USERS="${MANAGED_USERS:-}"               # 远程用户；开户时再传，如 MANAGED_USERS="u_alice"
PASSWORD_MODE="${PASSWORD_MODE:-generate}"

SSH_EXTRA_USERS="${SSH_EXTRA_USERS:-}"           # 系统 SSH 只给管理员做局域网救援；用户走 Tailscale SSH
SCREEN_SHARE_USERS="${SCREEN_SHARE_USERS:-console}"  # 管理员经 Tailscale 屏幕共享登录 console 配置 UU
SCREEN_INCLUDE_ADMIN="${SCREEN_INCLUDE_ADMIN:-1}"
SSH_KEY_ONLY="${SSH_KEY_ONLY:-0}"

POWER_ON_CONNECT="${POWER_ON_CONNECT:-1}"
DISPLAY_SLEEP_MIN="${DISPLAY_SLEEP_MIN:-10}"

TS_ENABLE="${TS_ENABLE:-1}"
TS_HOSTNAME="${TS_HOSTNAME:-}"                   # 空＝HOST_NAME 小写
TS_TAGS="${TS_TAGS:-tag:mac}"                    # 只在扫码登录时用；用认证密钥时以密钥上的标签为准
TS_ACCEPT_DNS="${TS_ACCEPT_DNS:-0}"

UU_APP="${UU_APP:-/Applications/UURemote.app}"
UU_PROC="${UU_PROC:-UURemote}"
UU_CASK="${UU_CASK:-uuremote}"                   # Homebrew 安装包名
WATCHDOG_INTERVAL="${WATCHDOG_INTERVAL:-300}"

FIREWALL="${FIREWALL:-1}"
DISABLE_MACOS_AUTO_UPDATE="${DISABLE_MACOS_AUTO_UPDATE:-1}"
