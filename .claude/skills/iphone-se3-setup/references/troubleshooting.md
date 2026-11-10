# 排障手册

这些现象都在 iPhone SE 3（iPhone14,6，iOS 27.2）和 Mac mini M1 上实际遇到过。先按报错查表，表里没有的再去读日志。

手机上的调试日志：

```sh
swipt device logs -d <名称> --since 2m --level debug
```

## 安装和签名

| 现象 | 原因 | 处理 |
|---|---|---|
| `Xcode has no development certificate`，但 Xcode 里能看到证书 | 这台 Mac 缺 WWDR G3 中间证书，证书被判定无效。CLI 只认 `security find-identity -v` 里有效的身份 | 在桌面终端运行 `se3.sh fix-wwdr` |
| `Xcode has no development certificate`，`find-identity` 里也没有 | 账号还没有开发证书 | Xcode › Settings › Apple Accounts › Manage Certificates › + › Apple Development |
| `errSecInternalComponent` | `codesign` 第一次使用私钥要弹窗授权，SSH 会话弹不出来 | 换到 Mac 桌面的终端，运行 `se3.sh fix-wwdr`，弹窗里输入登录密码并点“始终允许” |
| `CoreDevice cannot reach the device while its loopback VPN is on`（CoreDeviceError 4016） | CLI 把 4016 都解释成 VPN 的问题。实测中，Mac 和手机在不同网段时出现过；换到同一网段后，VPN 开着也能连上 | 把 Mac 放到手机的网段；或者插 USB，用 `se3.sh renew`，它会自动断开 VPN、装完再连上 |
| `缺少 Xcode` / `unable to find utility "devicectl"` | Xcode 没有被选为默认开发者目录。`se3.sh` 会自己设 `DEVELOPER_DIR`，直接运行 `swipt` 时没有 | `sudo xcode-select -s /Applications/Xcode.app`（需要用户同意），或者在命令前加 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` |
| `auto-renew.status` 里 `signing does not work in this session` | 后台任务签不了名：钥匙串被锁住，或者签名私钥没有对 codesign 设置“始终允许” | 在桌面终端运行一次 `se3.sh fix-wwdr`，弹窗时输入登录密码并点“始终允许” |
| `Developer Mode` 相关的 xcodebuild 错误 | 开发者模式没开 | 设置 › 隐私与安全性 › 开发者模式，打开后重启并确认 |
| `its signing expires in 1 week` | 账号是 Personal Team（免费），描述文件 7 天过期 | 定期运行 `se3.sh renew`，或换付费团队（有效期约一年） |
| `renew` 只打印“已是最新”和到期时间，没有重签 | 签名剩余超过一半，也没有新版本，`swipt sideload update` 什么都不做。**不是错误** | 剩余不到一半（免费账号约 3.5 天）时再续签 |
| `The device must be paired before it can be connected`（`RemotePairingError error 2`） | Mac 的 CoreDevice 配对丢了，但 USB 信任还在，所以 usbmuxd 和 `swipt-server` 照常工作，`devicectl list devices` 里显示 `unpaired`。SE3-2 出现过一次，原因未查清；关掉 VPN 也恢复不了 | 手机解锁并插着 USB，在桌面终端运行 `xcrun devicectl manage pair --device <UDID>`，手机上有提示就点“信任”并输入密码。`se3.sh renew` 会自动做这一步 |
| `was not found on the local network` | 手机和 Mac 不在同一网段，Bonjour 跨不过去。**不是错误** | 继续 `se3.sh post`，它会读出手机的 Wi-Fi 地址 |

## 连接

| 现象 | 原因 | 处理 |
|---|---|---|
| `device not listed by usbmuxd`，或 `usbmuxd` 列表为空，但 `ioreg -p IOUSB` 能看到 iPhone | USB 枚举正常，Mac 的 usbmuxd 丢了这台手机。原因未查清，长时间闲置后出现过 | 先重新插拔。还不行就 `sudo killall usbmuxd`（需要用户同意），它救回过一部分手机 |
| `devicectl` 显示 `unavailable` | 同上；或者手机没插 USB，又和 Mac 不在同一网段。同一网段时，没插线的手机显示 `localNetwork` | 同上，或者把 Mac 放到手机的网段 |
| SSH 报 `Too many authentication failures` | ssh-agent 依次尝试它里面的所有密钥，用完了 Mac 允许的认证次数（默认 6 次），还没轮到正确的密钥或密码 | 加 `-o IdentitiesOnly=yes -i <专用密钥>` |
| 在 Claude Code 里用 `!` 运行 `ssh-copy-id`，提示 `Permission denied, please try again` | `!` 里输入不了密码 | 让用户在自己的终端窗口里运行 |
| Mac 换了 IP 后，SSH 报 `Host key verification failed` 或要求确认新指纹 | known_hosts 里还没有新地址 | 用 `-o HostKeyAlias=<旧 IP>` 连一次，主机密钥一致再把新地址加进 known_hosts |
| 挂载磁盘镜像时 `retransmit limit`、`the service accepted no data for 5s` | 隧道 MTU 过大。MTU 8000 及以上全部卡死 | 用带 `LockdownMTU = 1280` 修复的 `swipt-server`。通过 `SE3_SWIPT_SERVER` 指定路径 |
| 各种随机超时、`connection reset`、读界面要几十秒 | Mac 在睡眠。SSH 会话不会阻止睡眠 | `pmset -g log` 查睡眠次数；保持唤醒后重测，否则结果不可信 |
| Wi-Fi 上 `ping` 通，但 API 端口 `ECONNREFUSED` | 手机上的 Swipt 没在运行 | 让人打开 Swipt。出现过一次拔线后 App 退出，原因未查清 |

## 操作手机

| 现象 | 原因 | 处理 |
|---|---|---|
| `device.unlock()` 超时，报 `wait for the accessibility service` | 报错有误导性，实际是密码页一直没出现。查调试日志里的 `reason` 和 `hit.class` | 见下一行 |
| 日志里是 `candidate_missing`，`hit.class` 是 `AMUIOnboardingView`，屏幕横向 | 手机充电、横放、锁屏时进入了 StandBy | 关掉“待机显示”（`se3.sh prepare` 会做） |
| `input.tap` 点开关没反应，也不报错 | iOS 27 的 SwiftUI 开关不响应短按 | 用 `input.touch` 按住 200 毫秒 |
| `accessibility.tap` 报 `would reach the element with the identifier "setup-finished"` | `--setup` 启动的 App 留着一个隐形元素 | 重启 App（`se3.sh post` 会做），或改用 `input.tap` |
| `the device is locked: unlock it first` | 锁屏时不能点击和启动 App，这是设计如此 | 先 `await device.unlock()`，这需要设置过自动解锁 |
| `screen.screenshot is not a function` | 较旧的 nightly 版本 | 用 `device.screenshot()` |
| `scope must be frontApp, springBoard or fullScreen` | 较旧的 nightly 版本，新版叫 `screen` | 换成 `fullScreen` |

## 需要用户决定、不要自行处理的事

- **解锁登录钥匙串。** 通过 SSH 用密码解锁会被权限系统拦下，也不应该绕过。需要签名的步骤让用户在 Mac 桌面的终端运行。
- **`sudo` 命令。** 每次都先问，之前的同意不延续。
- **重复尝试解锁。** 连续输错密码会让手机进入停用状态。解锁失败时先看调试日志，不要循环重试。
