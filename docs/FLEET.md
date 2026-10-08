# fleet：给朋友开通 Mac mini 访问

管理员在自己电脑上用一条命令开账号，朋友粘贴 4 行命令接入。分配关系存在 Tailscale 后台规则里，本地不维护任何表。

- 名字就是账号：`fleet user add alice mm-us-01` → 朋友用 `ssh alice@mm-us-01` 登录
- 朋友不用注册 Tailscale，不占免费版用户名额；只能连分配给他的机器，只能以自己的账号登录
- 每次改规则都会：本地检查硬性规定 → 后台校验（含自检测试）→ 备份旧规则 → 显示差异 → 输入 yes 才写入

## 一、管理员一次性准备

1. Tailscale 后台（确认左上角是你自己的网络）→ Trust credentials → 新建凭证，Custom scopes 只勾：
   - Policy File：Write
   - Devices → Core：Write，标签 `tag:fleet-admin`
   - Keys → Auth Keys：Write，标签 `tag:fleet-admin`
2. 在自己的终端运行，粘贴 Client ID 和 Secret（存进本机钥匙串，以后不用再输）：

   ```
   fleet login
   ```

3. 把规则整理成 fleet 格式（看差异后输入 yes）：

   ```
   fleet init
   ```

> `tskey-client-…` 是管理员凭证，只在 `fleet login` 时输入，永远不要发给任何人。泄露了就在后台 Revoke、新建一个、重新 `fleet login`。

## 二、给朋友开账号

```
fleet user add alice mm-us-01
```

1. 第一次会打印一个浏览器链接，打开确认身份（每 12 小时一次），然后在机器上建账号 `alice`
2. 显示规则变化，输入 `yes`
3. 打印 4 行命令（含一次性接入码 `tskey-auth-…`，24 小时有效），私聊发给朋友

机器上已有同名、但不是 fleet 建的账号（如管理员账号）时，fleet 会拒绝，换个名字即可。

## 三、朋友接入

在朋友的 Mac 终端逐行粘贴管理员发来的命令：

```
cd /tmp
B=https://raw.githubusercontent.com/edison-land
curl -fsSL -o c.sh $B/mac-fleet/main/client/connect-mac.sh
bash c.sh --code tskey-auth-… alice@mm-us-01
```

第一次安装 Tailscale 时输入电脑密码，并允许「添加 VPN 配置」「网络扩展」。看到 `登录成功：alice@…` 即完成，以后：

```
ssh alice@mm-us-01
```

`curl` 报证书错误（`no alternative certificate subject name`）：国内网络下 GitHub 被干扰，打开代理后重试。

## 四、日常管理

| 要做的事 | 命令 |
|---|---|
| 查看机器、用户和权限 | `fleet list` |
| 给已有用户加机器 | `fleet user grant alice mm-au-01` |
| 朋友换电脑 / 接入码过期 | `fleet user code alice` |
| 收回某台机器 | `fleet user revoke alice mm-us-01` |
| 收回全部（可选删除机器上的账号） | `fleet user revoke alice` |
| 已在网络中的机器缺标签 | `fleet host add mm-us-01` |

## 五、管理员自测（扮演朋友）

1. 菜单栏 Tailscale 切到另一个账号（避免动到管理员身份）
2. `fleet user add test <机器名>`，在本机粘贴它打印的命令
   - 本机下载不了时，直接用仓库里的脚本：`cp <仓库>/client/connect-mac.sh /tmp/c.sh`
3. `ssh test@<机器名>` 能进；连其他机器应超时
4. 菜单栏 Tailscale 切回管理员账号
