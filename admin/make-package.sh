#!/bin/bash
# 管理员在自己电脑上运行：为一台新 Mac mini 生成专属部署包（内含主机名和一次性认证密钥）。
# 现场的人拿到包后只需要一条固定命令，不用填任何参数。
#
# 用法：bash admin/make-package.sh <主机名>
#   例：bash admin/make-package.sh mm-us-01
#   运行后会提示粘贴认证密钥（不显示、不进命令历史）。
# 先把机器写进 admin/hosts.conf 并运行 bash admin/sync.sh --push（这样后台才有 tag:<主机名>），
# 再到后台 Settings → Keys → Generate auth key：不勾 Reusable，有效期 1 天，Tags 选 tag:mac 和 tag:<主机名>

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST="${1:-}"

case "$HOST" in
"" | *[!a-z0-9-]*)
	echo "用法：bash admin/make-package.sh <主机名>（只用小写字母、数字和连字符，如 mm-us-01）"
	exit 2
	;;
esac

if ! sed -e 's/#.*//' "$ROOT/admin/hosts.conf" 2>/dev/null | awk '{print $1}' | grep -qx "$HOST"; then
	echo "提醒：admin/hosts.conf 里还没有 ${HOST}。请先加一行「$HOST  <这台机器的管理员账号>」，运行 bash admin/sync.sh --push，"
	echo "      然后生成 Tags 为 tag:mac 和 tag:$HOST 的认证密钥，再回来运行本命令。"
	exit 2
fi

printf '粘贴 %s 的认证密钥（tskey-auth-…，输入时不显示）：' "$HOST"
read -rs KEY
printf '\n'
case "$KEY" in tskey-auth-*) ;; *) echo "这不像认证密钥（应以 tskey-auth- 开头）"; exit 2 ;; esac

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
# 只放通用文件：不带本机配置、测试记录、运行产物和管理员工具
rsync -a --exclude dist --exclude logs --exclude state --exclude .DS_Store \
	--exclude config/host.conf --exclude checklists --exclude admin \
	"$ROOT/" "$STAGE/mac-fleet/"
umask 077
printf 'HOST_NAME=%q\nTS_AUTHKEY=%q\n' "$HOST" "$KEY" >"$STAGE/mac-fleet/config/site.env"

mkdir -p "$ROOT/dist"
OUT="$ROOT/dist/mac-fleet-$HOST.zip"
rm -f "$OUT"
(cd "$STAGE" && ditto -c -k --norsrc --noextattr --noacl --keepParent mac-fleet "$OUT")
chmod 600 "$OUT"

cat <<MSG

已生成：$OUT
这个压缩包里含有认证密钥，只发给现场负责这台机器的人（私聊），对方用完即失效（一次性、1 天内有效）。

—— 下面这段直接复制发给对方 ——
1. 把附件 mac-fleet-$HOST.zip 保存到「下载」文件夹
2. 打开「终端」，粘贴下面这一行后回车，按提示输入这台 Mac 的开机密码，再输入 yes：
cd ~/Downloads && ditto -x -k mac-fleet-$HOST.zip . && cd mac-fleet && sudo bash bootstrap.sh
3. 执行完把屏幕截图发给我
—————————————————————
MSG
