#!/bin/bash
# mac-fleet 一条命令入口：下载最新版并启动服务端初始化。可以反复执行，已完成的步骤会自动跳过。
#
#   curl -fsSL -o /tmp/i.sh https://raw.githubusercontent.com/edison-land/mac-fleet/main/install.sh
#   sudo HOST_NAME=mm-us-01 bash /tmp/i.sh
#
# 其余参数（TS_AUTHKEY、FILEVAULT_PLAN、BOOTSTRAP_YES）原样传给 bootstrap.sh；加 --check 只预演。

set -u
TGZ="https://codeload.github.com/edison-land/mac-fleet/tar.gz/main"
DIR="$(mktemp -d /tmp/mac-fleet.XXXXXX)"
if ! curl -fsSL "$TGZ" | tar xz -C "$DIR"; then
	printf '\033[1;31m下载失败：检查网络后重新运行同一条命令\033[0m\n'
	exit 1
fi
exec bash "$DIR/mac-fleet-main/bootstrap.sh" "$@"
