# 开发与构建

MacToys 的功能和使用方式见 [README](../README.md)。

## 构建与运行

需要 Xcode 27（包含 macOS 27 SwiftUI 宏插件）与 Swift 6.4。

```sh
scripts/test.sh
scripts/dev-cert.sh
scripts/build-app.sh
open /Applications/MacToys.app
```

构建和签名验证成功后会自动安装到 `/Applications/MacToys.app`；若应用正在运行，会先退出并在安装后重新打开。仅安装已有构建可运行 `scripts/install-app.sh`。

使用 Xcode 也可直接打开 `Package.swift`。构建脚本优先选择 `/Applications/Xcode.app`，支持通过 `DEVELOPER_DIR` 指定其他 Xcode。`CONFIGURATION=debug` 构建调试版本，`UNIVERSAL=1` 构建 arm64/x86_64 通用版本。

默认使用固定的本地自签名证书 `MacToys Development`。先运行一次 `scripts/dev-cert.sh` 创建证书，后续构建重复使用同一证书；不再回退到临时签名。应用身份同时绑定 Bundle ID 和证书指纹，不依赖每次构建变化的二进制哈希。

证书及不可导出的私钥位于 `~/Library/Keychains/mactoys-dev.keychain-db`。创建时自行设置签名密码，后续每次运行 `scripts/build-app.sh` 时输入该密码。终端输入不回显；非交互运行会显示隐藏密码的系统输入框。密码不会保存到文件，请自行记住。

忘记旧密码时，运行 `scripts/dev-cert.sh --reset` 设置新密码并创建新证书。旧签名钥匙串会被删除，不保留备份。更换证书后可能需要重新授予应用权限；正常构建会一直复用现有证书。

通过 `CODE_SIGN_IDENTITY` 可使用自己的开发或 Developer ID 证书，必要时通过 `CODE_SIGN_KEYCHAIN` 指定钥匙串。公开分发仍需 Developer ID 签名和公证。本次由临时签名切换为固定证书后，需要重新授予一次权限。
