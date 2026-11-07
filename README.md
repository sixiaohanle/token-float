# Token 悬浮球

一个 macOS 桌面小工具，实时查看 Codex 和 Claude Code 的输出速率与 Token 用量。

- 在悬浮球、菜单栏或两处同时显示总速率。展开后可看各来源和对话的速率。
- 查看今日累计和历史用量。活动图支持每日、每周、累计，以及按来源切换。
- 设置中可调整数据来源、开机启动、猫咪动画和累计用量的数字格式。
- 在「设置 → 关于」点击「检测更新」，或通过 GitHub 查看正式发布。

## 下载

从 [GitHub Releases](https://github.com/sixiaohanle/token-float/releases/latest) 下载 ZIP，解压后将 `Token 悬浮球.app` 移到「应用程序」。

发布包适用于 Apple 芯片和 macOS 13 或更新版本。发布包使用临时签名，未经过 Apple 公证，首次打开时 macOS 可能阻止运行。也可以按下文在本机从源码构建，构建脚本会使用当前 Mac 的架构。

## 从源码构建

准备 macOS 13 或更新版本，以及支持 Swift 5.9 或更新版本的 Xcode 命令行工具。在仓库根目录运行：

```sh
./work/build-token-float.sh
```

生成的应用位于 `outputs/Token 悬浮球.app`。

## 数据与更新

应用从本机读取 Codex 和 Claude Code 的会话日志，按天缓存用量。设置中的「数据来源」可指定自定义目录。速率随日志写入刷新，具体刷新时机取决于各工具写入用量的频率。

会话日志和用量保存在本机。应用启动时及运行期间会向 GitHub 查询正式版本，检查请求无需登录。

## 许可证

[MIT](LICENSE)
