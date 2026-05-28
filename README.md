# NAS Player

Flutter SMB NAS media browser and player for Android, macOS, and Windows.

## 功能

- 通过 SMB 账号密码连接 NAS
- 展示共享目录、子文件夹、图片文件和视频文件
- 点击文件夹进入下一级目录
- 点击图片进入查看模式，支持缩放、查看文件信息、删除图片
- 删除图片后自动切换到下一张；没有下一张时返回文件列表
- 点击视频后通过本机 HTTP Range 代理从 SMB 分段读取，边缓冲边播放

## 运行

安装依赖：

```sh
flutter pub get
```

在 macOS 上测试：

```sh
flutter run -d macos
```

构建 Android：

```sh
flutter build apk
```

构建 Windows 需要在 Windows 机器上运行：

```sh
flutter build windows
```

## macOS 环境

macOS 桌面版需要完整 Xcode 和 CocoaPods：

```sh
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -runFirstLaunch
sudo gem install cocoapods
flutter doctor
```

`media_kit` 当前在 macOS 上仍走 CocoaPods，Flutter 可能会提示它暂未支持 Swift
Package Manager。这是未来兼容性警告，不影响当前构建路径。

## 说明

播放器使用 `media_kit`，用于兼容 Android、macOS 和 Windows。应用会在本机启动
`127.0.0.1` HTTP 代理，把播放器的 Range 请求转换为 SMB 分段读取请求，因此不需要
等整个视频下载完成。
