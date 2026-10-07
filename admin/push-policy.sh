#!/bin/bash
# 把 admin/out/policy.hujson 推送到 Tailscale 后台，并给 hosts.conf 里的每台机器补上标签。
# 由 sync.sh --push 调用；也可以单独保存令牌：
#   bash admin/push-policy.sh --save-token     粘贴 API 令牌（tskey-api-…），存进本机钥匙串，以后不用再输
#
# API 令牌在后台 Settings → Keys → Generate access token 生成（免费版也可用，有效期 1–90 天）。
# 推送前会：转成标准 JSON → 后台校验 → 备份后台现有规则 → 你输入 yes 确认 → 带 If-Match 推送（防止覆盖别人刚改的）。

KC_SERVICE="mac-fleet-tailscale-api"
API="https://api.tailscale.com/api/v2"

ts_token() {
	if [ -n "${TS_API_KEY:-}" ]; then echo "$TS_API_KEY"; return; fi
	security find-generic-password -s "$KC_SERVICE" -a default -w 2>/dev/null
}

save_token() {
	echo "粘贴 API 令牌（tskey-api-…）；按提示输入两次："
	security add-generic-password -U -s "$KC_SERVICE" -a default -w &&
		echo "已存进钥匙串（服务名 ${KC_SERVICE}）"
}

# HuJSON → 标准 JSON：本工具生成的规则只有整行注释和行尾逗号，这样处理足够
hujson_to_json() {
	sed -e 's#^[[:space:]]*//.*$##' "$1" | perl -0pe 's/,(\s*[\]}])/$1/g'
}

api() { # api 方法 路径 [数据文件] [额外 curl 参数…]
	local m="$1" p="$2" d="${3:-}"
	shift 3 2>/dev/null || shift $#
	if [ -n "$d" ]; then
		curl -sS -X "$m" -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" --data-binary "@$d" "$@" "$API$p"
	else
		curl -sS -X "$m" -H "Authorization: Bearer $TOKEN" "$@" "$API$p"
	fi
}

push_policy() {
	local policy="$1" dir json resp hdr etag ts ans
	dir="$(dirname "$policy")"
	TOKEN="$(ts_token)"
	if [ -z "$TOKEN" ]; then
		echo "[需处理] 没有 API 令牌：先运行 bash admin/push-policy.sh --save-token（或设置环境变量 TS_API_KEY）"
		return 1
	fi
	json="$dir/policy.json"
	hujson_to_json "$policy" >"$json"
	plutil -convert xml1 -o /dev/null "$json" 2>/dev/null || { echo "[错误] 规则转成 JSON 后格式不对：$json"; return 1; }

	echo "== 1/4 后台校验"
	resp="$(api POST /tailnet/-/acl/validate "$json")"
	case "$resp" in
	"" | "{}" | *'"message":""'*) echo "  通过" ;;
	*'"message"'*) echo "  [错误] 后台校验没通过：$resp"; return 1 ;;
	*) echo "  后台返回：$resp" ;;
	esac

	echo "== 2/4 备份后台现有规则"
	ts="$(date +%Y%m%d-%H%M%S)"
	hdr="$(mktemp)"
	api GET /tailnet/-/acl "" -D "$hdr" -o "$dir/policy-backup-$ts.hujson" || { echo "  [错误] 读取后台规则失败"; return 1; }
	etag="$(awk -F': ' 'tolower($1)=="etag" {print $2}' "$hdr" | tr -d '\r')"
	rm -f "$hdr"
	echo "  已备份到 admin/out/policy-backup-$ts.hujson（ETag ${etag:-无}）"

	echo "== 3/4 确认"
	echo "  将用 admin/out/policy.hujson 覆盖后台的访问规则。和备份的差异："
	diff <(hujson_to_json "$dir/policy-backup-$ts.hujson" | tr -d ' ') <(tr -d ' ' <"$json") | grep -E '^[<>]' | sed 's/^</  删除：/; s/^>/  新增：/' | head -40
	printf '  输入 yes 推送：'
	read -r ans </dev/tty
	[ "$ans" = "yes" ] || { echo "  已取消"; return 1; }

	resp="$(api POST /tailnet/-/acl "$json" -H "If-Match: $etag" -w '\nHTTP %{http_code}')"
	case "$resp" in
	*"HTTP 200") echo "  [OK] 规则已推送" ;;
	*) echo "  [错误] 推送失败：$resp"; return 1 ;;
	esac

	echo "== 4/4 给机器补标签"
	ensure_host_tags
}

# 每台机器应有 tag:mac + tag:<机器名>；只增加，不去掉已有标签
ensure_host_tags() {
	local devs n i name id tags want t newtags
	devs="$(mktemp)"
	api GET /tailnet/-/devices "" -o "$devs" || { echo "  [错误] 读取设备列表失败"; return 1; }
	n="$(plutil -extract devices raw "$devs" 2>/dev/null)"
	for h in $(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$HOSTS" | awk '{print $1}'); do
		id=""
		i=0
		while [ "$i" -lt "${n:-0}" ]; do
			name="$(plutil -extract "devices.$i.name" raw "$devs" 2>/dev/null)"
			if [ "${name%%.*}" = "$h" ]; then id="$(plutil -extract "devices.$i.id" raw "$devs")"; break; fi
			i=$((i + 1))
		done
		if [ -z "$id" ]; then echo "  ${h}：网络里还没有这台机器（部署后再同步一次）"; continue; fi
		tags="$(plutil -extract "devices.$i.tags" json -o - "$devs" 2>/dev/null | tr -d '[]"' | tr ',' ' ')"
		newtags="$tags"
		for want in tag:mac "tag:$h"; do
			case " $tags " in *" $want "*) ;; *) newtags="$newtags $want" ;; esac
		done
		if [ "$newtags" = "$tags" ]; then echo "  ${h}：标签齐全（${tags}）"; continue; fi
		t="$(mktemp)"
		printf '{"tags": [%s]}' "$(for x in $newtags; do printf '"%s",' "$x"; done | sed 's/,$//')" >"$t"
		if api POST "/device/$id/tags" "$t" -w '%{http_code}' -o /dev/null | grep -q 200; then
			echo "  ${h}：已补标签 →$newtags"
		else
			echo "  [错误] ${h}：补标签失败"
		fi
		rm -f "$t"
	done
	rm -f "$devs"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	case "${1:-}" in
	--save-token) save_token ;;
	*) echo "用法：bash admin/push-policy.sh --save-token；推送请用 bash admin/sync.sh --push" ;;
	esac
fi
