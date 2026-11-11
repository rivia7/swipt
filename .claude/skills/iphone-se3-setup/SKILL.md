---
name: iphone-se3-setup
description: 把 iPhone SE3（SE 第三代 / SE 2022，iPhone14,6，iOS 27）或其他 Home 键 iPhone 从新机配置到拔掉数据线后 Agent 仍能经 Wi-Fi 操控的状态，并保持这个状态（Swipt App + LocalDevVPN 路线，能脚本化的步骤由脚本完成）。用户要给这类手机做初始化、接入、上架、批量配置，或说“再配一台”时使用；配置做到一半卡住要接着跑（LocalDevVPN、prepare 挂载磁盘镜像卡住、签名安装 Swipt 及证书报错、开 API 令牌、记录地址），拔线前后验收，或停电、重启、换网络后巡检这些手机无线状态下能否连上、自动解锁、打开 App，续签 Swipt（包括续签报错、设置或检查自动续签、查签名还剩几天），IP 变了重新登记，也都用它，即使用户没提 SOP。它只负责把手机配好、保持可控并验证；在已配好的手机上办具体的事、写 Swipt 自动化脚本、改 swipt-server 或 LocalDevVPN 源码、比较方案、通用 Mac 运维都不用它。
---

# iPhone SE3 初始化 SOP

目标：手机拔掉数据线后，Agent 能通过 Wi-Fi 调用手机上的 Swipt，读屏、点击、打开 App，锁屏后也能自己解锁。

手机上跑 Swipt App 和回环 VPN，所以运行时不依赖 Mac 和数据线。Mac 只在配置和续签时需要。

## 本机环境

`references/local.md` 记着这套环境的测试 Mac 的 SSH 地址、参数和主机密钥指纹，手机的 UDID 和 API 地址，以及在手机上跑脚本的方法。它是私有文件，已被 git 忽略，别的机器上可能没有。有的话先读它，里面有的信息不用再问用户。环境有变化就更新它，但不要把里面的地址、UDID 写进会提交的文件。

## 开始前要向用户确认

- 手机的 UDID。不带 UDID 运行 `preflight`，会列出这台 Mac 认识的手机及其 UDID。`xcrun devicectl list devices` 表格里的 Identifier 列是 CoreDevice 的 UUID，不是 UDID，不要拿错。
- 手机接在哪台 Mac 上，以及 SSH 地址和账号。登录方式见下一节。

## 连接 Mac

用一把专用的 SSH 密钥登录，Mac 的密码不经过聊天：

1. 让用户在本机生成密钥：`ssh-keygen -t ed25519 -N "" -C swipt-mac -f ~/.ssh/swipt_mac_ed25519`。
2. 让用户在**自己的终端窗口**里运行 `ssh-copy-id -i ~/.ssh/swipt_mac_ed25519.pub -o IdentitiesOnly=yes user@mac`，输入一次 Mac 的登录密码。在 Claude Code 里用 `!` 运行时输入不了密码。
3. 之后每次连接都带上 `-i ~/.ssh/swipt_mac_ed25519 -o IdentitiesOnly=yes`。不加 `IdentitiesOnly` 的话，ssh-agent 会先把它里面的其他密钥都试一遍，用完 Mac 允许的认证次数后，报 `Too many authentication failures`。

Mac 换了 IP 时，先用 `-o HostKeyAlias=<旧 IP>` 连一次，确认主机密钥没变，再信任新地址。

实在只能用密码时，由用户提供，只通过 `SE3_SSH_PASSWORD` 环境变量传给当次命令，不要写进文件或记忆。

## 运行脚本

总脚本 `scripts/se3.sh` 在 Mac 上运行。Claude 不在那台 Mac 上时，用 `scripts/remote.sh` 同步并执行：

```sh
SE3_SSH=user@mac SE3_SSH_OPTS="-i $HOME/.ssh/swipt_mac_ed25519 -o IdentitiesOnly=yes" scripts/remote.sh preflight <UDID>
```

它会把脚本放到 Mac 的 `~/.swipt-se3/`。`SE3_SWIPT_SERVER` 和 `SWIPT_TEAM` 会被一起带到 Mac 上，其他环境变量不会。标着“桌面”的步骤必须由用户在 **Mac 桌面的“终端”App** 里运行，命令是 `zsh ~/.swipt-se3/se3.sh ...`。原因是 `codesign` 第一次使用私钥要弹窗授权，SSH 会话弹不出来。不要通过 SSH 解锁钥匙串来绕开它。

API 地址和令牌保存在 Mac 的 `~/.config/swipt-se3/devices/<UDID>.json`，只有本人可读。不要把令牌打印出来，脚本的输出已经遮盖了令牌。

手机的解锁密码只在安装时由用户在终端手动输入，脚本不保存。不要向用户索要这个密码。

## 流程

| # | 步骤 | 谁来做 | 命令 |
|---|---|---|---|
| 1 | Mac 一次性准备 | 用户 | 见下文 |
| 2 | 手机人工准备 | 用户 | 见下文 |
| 3 | 环境检查 | 脚本 | `preflight <UDID>` |
| 4 | 手机设置 | 脚本 | `prepare <UDID>` |
| 5 | 签名并安装 Swipt，输入解锁密码 | 用户（桌面） | `install <UDID>` |
| 6 | 连 VPN、开令牌、记录地址 | 脚本 | `post <UDID>` |
| 7 | 验证 | 脚本 | `verify <UDID> --lock-test` |
| 8 | 拔线后再验证 | 用户拔线，脚本验证 | `verify <UDID>` |

一步失败就停下来，按 `references/troubleshooting.md` 处理后重跑这一步。脚本都可以安全地重复运行。

### 1. Mac 一次性准备（每台 Mac 一次）

SSH 登录用的账号，要和 Mac 桌面上登录的是同一个用户，并且是管理员。钥匙串、证书和自动续签的定时任务都属于桌面登录的用户。带 `sudo` 的命令每次都要先征得用户同意，密码由用户自己输入。

先通过 SSH 运行一次不带 UDID 的 `preflight`。它会把脚本同步到 Mac 的 `~/.swipt-se3/`（第 4 步要用），并列出还缺什么，这时有 FAIL 是正常的。

1. 安装 Xcode，打开一次，同意许可，等它装完附加组件（也可以运行 `sudo xcodebuild -runFirstLaunch`）。再用 `sudo xcode-select -s /Applications/Xcode.app` 把它设为默认；不设的话，直接运行 `swipt` 时找不到 `devicectl`。
2. 用 Homebrew 装 Node（`brew install node`），再装 `swipt`：`npm install -g @swipt/cli --include=optional`。脚本只加载 `/opt/homebrew` 下的命令，用别的方式装的 Node 在 SSH 里找不到 `swipt`。
3. Xcode › Settings › Apple Accounts 登录账号，Manage Certificates › + › Apple Development。
4. 在桌面终端运行 `zsh ~/.swipt-se3/se3.sh fix-wwdr`。弹窗询问钥匙串时输入登录密码，点“始终允许”。
5. 关闭系统睡眠：`sudo pmset -a sleep 0`。睡眠中的 Mac 会让所有手机反复掉线，并产生大量假故障。
6. 最好让 Mac 和手机在同一网段。这样续签不用插线，也能自动续签（见“续签”），Bonjour 也能发现手机上的 Swipt。

全部做完后再运行一次 `preflight`，Mac 的各项应该都是 OK。

账号如果显示 Personal Team，就是免费账号，签名 7 天过期，要告诉用户。

新手机第一次挂载开发者磁盘镜像时，官方发布的 `swipt-server` 可能卡住。用带 MTU 修复的构建（`swipt` 仓库 `multi-device-server` 分支的 `make server`），脚本会自动在 `~/swipt-dev` 下查找，也可以用 `SE3_SWIPT_SERVER` 指定。`preflight` 会提示当前用的是哪个。

### 2. 手机人工准备（每台手机一次）

这些步骤脚本做不了，让用户逐项完成：

1. 设置锁屏密码，连上 Wi-Fi，登录 Apple 账号。
2. 用数据线接 Mac，解锁，点“信任此电脑”。
3. 设置 › 隐私与安全性 › 开发者模式，打开后重启，开机后确认。
4. 从 App Store 安装 LocalDevVPN，打开后点 Connect，允许添加 VPN 配置。

### 3. 环境检查

`preflight` 检查 Xcode、CLI、证书、WWDR G3、Mac 睡眠设置，以及手机的型号、系统、开发者模式和配对状态。有 `FAIL` 就先解决。不带 UDID 时，它只检查 Mac，并列出 Mac 认识的手机和它们的 UDID。

### 4. 手机设置

`prepare` 需要手机已解锁。它会把自动锁定设为永不、关闭待机显示、挂载磁盘镜像，并断开 VPN。Mac 和手机跨网段时，VPN 开着会让 CoreDevice 连不上手机，报 4016。

待机显示必须关：手机充电、横放、锁屏时会进入 StandBy，自动解锁就走不通了。

如果 LocalDevVPN 没装，脚本会在手机上打开 App Store 页面并退出，让用户安装后重跑。

### 5. 签名并安装 Swipt

让用户在 Mac 桌面终端运行：

```sh
zsh ~/.swipt-se3/se3.sh install <UDID>
```

脚本会先测试签名，然后提示输入手机的解锁密码（不回显，输入两次防手误）。默认是 4 或 6 位数字；自定义密码在 UDID 后面加 `numeric` 或 `alphanumeric`。

正常结果是打印 `Swipt is running`。CLI 会跟随终端语言，中文环境下显示为 “Swipt 正在執行” 之类的译文。最后如果提示 `was not found on the local network`（“在區域網路上找不到”），只说明手机和 Mac 不在同一网段，不是错误。有多个 Team 时设置 `SWIPT_TEAM=<Team ID>`。

这一步会把手机注册到开发者账号，占用一个设备名额。解锁密码不写入文件，但安装期间会短暂出现在 Mac 的进程参数里，Swipt 会在手机上保存一份用于自动解锁。

### 6. 连 VPN、开令牌、记录地址

`post` 连上 VPN，重启 Swipt，打开 Local Network 的 Authentication，读出令牌和手机的 Wi-Fi 地址，保存到 `devices/<UDID>.json`。

第一次连 VPN 如果弹出需要输入密码的系统窗口，脚本会停下来，让用户在手机上允许后重跑。

### 7. 验证

`verify <UDID> --lock-test` 走 Wi-Fi 检查：端口可达、不带令牌被拒绝、读设备信息、截图、读界面，然后锁屏、解锁、打开 App Store。

`--lock-test` 会用手机上保存的解锁密码。失败时先看调试日志，**不要循环重试**，连续输错会让手机停用。

### 8. 拔线后再验证

让用户拔掉数据线，换成充电头，手机保持竖放，再运行 `verify <UDID>`。

## 完成后告诉用户

- 手机的 Wi-Fi 地址和 API 地址（不要显示令牌，告诉用户令牌在哪个文件里）。
- 签名的到期时间，以及用的是不是 Personal Team。
- 接入方式，例如 `claude mcp add --transport http <名称> http://<令牌>@<IP>:<端口>/mcp`。
- 手机的 IP 由 Wi-Fi 分配，可能会变，变了就重跑 `post`。
- 自动续签有没有开（`schedule status`）。没开就请用户在 Mac 桌面运行 `schedule on`，见“自动续签”。

## 查看状态

`status` 不带 UDID 时列出所有已登记的手机，包括网络是否通、Swipt 的 API 端口是否开着、签名还剩几天、什么时候进入续签期。它可以通过 SSH 运行。用户问“签名还有几天”“手机还在线吗”，先跑它。

## 续签

在 Mac 桌面终端运行 `zsh ~/.swipt-se3/se3.sh renew <UDID>`。

- Mac 和手机在同一网段时，CoreDevice 能在 VPN 开着的情况下经 Wi-Fi 连到手机，续签不用插线，也不用断开 VPN。SE3-4 实测过：拔着线从 build 71 升到 74。
- CoreDevice 连不上时，比如跨网段，手机就得插 USB。脚本会先断开 VPN，再重新签名，然后把 VPN 连回去。

续签成功后跑一次 `verify <UDID> --lock-test`，确认 API 端口、令牌和自动解锁都还在。SE3-2 和 SE3-4 续签后这三样都保留了。跑一次是为了确认这次也一样，免得等到 Agent 要用时才发现。

两种情况的共同点：

- 只有签名剩余不到一半（免费账号约 3.5 天）或有新版本时才会真的重签，否则只打印到期时间。
- 手机上的 nightly 比正式版新时，脚本会自动改用 nightly 通道。
- Mac 的 CoreDevice 配对丢了时（报 `The device must be paired`），USB 方式会先重新配对，手机上可能要点“信任”并输入密码。
- 失败时 VPN 也会连回来，旧签名到期前手机照常可用。
- 输出在 `~/.config/swipt-se3/logs/<UDID>.renew.log`。

### 自动续签

`zsh ~/.swipt-se3/se3.sh schedule on` 要由用户在 Mac 桌面终端运行。它装一个 LaunchAgent，每天 09:30 和 21:30 运行 `auto-renew`。每次运行会：

1. 先试签一次，提前发现后台会话里签不了名的问题。
2. 逐台检查已登记的手机，过了半程的才续签。只走无线方式，不碰 USB 和 VPN。
3. 续签后确认 Swipt 的 API 恢复了。
4. 结果写到 `~/.config/swipt-se3/auto-renew.status`，有问题就在 Mac 上弹通知。

`auto-renew --check` 只报告不续签，可以通过 SSH 运行。

前提条件：

- Mac 保持登录桌面、不睡眠。重启后要有人登录，任务才会跑。
- Mac 和手机在同一网段。
- Xcode 里的 Apple 账号保持登录。

不再使用的手机要删掉它的 `devices/<UDID>.json`，否则每次都会报连不上。`schedule off` 关闭自动续签，`schedule status` 查看最近一次的结果。

## 操作手机时的注意事项

Swipt 的 JS 脚本都放在 `scripts/device/`，写新的自动化时可以参考：

- iOS 27 的开关要用 `input.touch` 按住 200 毫秒，`input.tap` 翻不动，而且不报错。
- 经 `--setup` 启动的 App 会挡住 `accessibility.tap`，重启 App 或改用 `input.tap(element.point)`。
- 较旧的 nightly 用 `device.screenshot()`，新版用 `screen.screenshot()`。

遇到问题查 `references/troubleshooting.md`。
