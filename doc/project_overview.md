# Media Player 项目功能与实现分析

## 1. 项目概述

**项目名称**: Media Player (mobile_video_play)  
**技术栈**: Flutter 3.10+ / Dart, Android 原生 (Kotlin)  
**平台**: Android (主要), macOS/Windows (框架已搭建)  
**定位**: 一款支持 SMB 网络共享和 Emby 媒体服务器的本地/网络媒体浏览与播放应用

---

## 2. 核心功能模块

### 2.1 服务器管理

**入口页面**: `lib/pages/server_home_page.dart`

- **多服务器支持**: 支持同时配置多个 SMB 和 Emby 服务器
- **服务器类型**: `ServerKind.smb` / `ServerKind.emby`
- **自动重连**: 记录上次连接的服务器 ID，下次打开自动连接
- **CRUD 操作**: 添加、编辑、删除服务器配置
- **服务器切换**: 在浏览页面可随时切换到其他服务器
- **配置持久化**: 使用 `flutter_secure_storage` 加密存储服务器凭据

**数据模型** (`lib/models.dart`):
- `ServerConfig`: 服务器配置（id, kind, name, host, domain, username, password, accessToken, userId）

### 2.2 SMB 文件浏览

**入口页面**: `lib/pages/browser_page.dart`

- **目录浏览**: 支持浏览 SMB 共享目录，显示文件夹、图片、视频
- **视图模式**: 列表、详细列表、大图标、中图标 四种显示模式 (`FileListViewMode`)
- **分页加载**: 每页 20 条，滚动到底部自动加载更多
- **排序规则**: 文件夹 > 图片 > 视频，同类按名称字母排序
- **缩略图**: 图片和视频自动生成缩略图（延迟加载、LRU 缓存、视频信号量限流）
- **文件操作**: 支持删除文件/视频
- **断线重连**: 检测连接断开（socket closed, broken pipe 等），自动重连

**SMB 双通道架构**:

| 通道 | 技术 | 用途 |
|------|------|------|
| Dart 通道 | `smb_connect` 包 | 文件列表、删除、图片读取、缩略图生成 |
| 原生通道 | Android SMBJ (Kotlin) | 视频流播放（性能更优） |

### 2.3 Emby 媒体浏览 

**相关页面**:
- `lib/pages/emby_home_page.dart` — Emby 首页（最近播放 + 媒体库列表）
- `lib/pages/emby_library_page.dart` — 媒体库详情（节目/类型/文件夹 三种视图）
- `lib/pages/emby_series_page.dart` — 剧集列表页

**功能**:
- **认证**: 用户名密码认证，获取 AccessToken 缓存复用
- **最近播放**: 显示最近添加的 20 个媒体项
- **媒体库浏览**: 按节目（Movie/Series）、类型（Genres）、文件夹三种视图浏览
- **剧集展开**: 点击电视剧可查看所有剧集列表
- **海报卡片**: 水平滚动的海报卡片展示，带封面图和标题

**数据模型**:
- `EmbyItem`: id, name, type, overview
- `playable`: Movie / Episode / Video 类型可播放
- `isSeries`: Series 类型可展开查看剧集

### 2.4 视频播放

**相关页面**:
- `lib/players/video_player_page.dart` — SMB 视频播放器
- `lib/players/network_video_player_page.dart` — Emby 视频播放器

**播放引擎**: `media_kit` (基于 libmpv/FFmpeg)

**通用功能**:
- 手势控制：左右滑动快进/快退，左侧上下滑动调节亮度，右侧上下滑动调节音量
- 进度条拖拽
- 播放/暂停
- 前进/后退 15 秒
- 横竖屏切换
- 杜比视界检测（文件名检测 + 设备 HDR 能力查询）

**SMB 播放器额外功能**:
- 上一部/下一部切换
- 视频删除

**Emby 播放器额外功能**:
- 画质选择（原始画质 / 2160p~144p 18 种预设）
- HLS 流转码播放 (`/Videos/{id}/master.m3u8`)
- 播放状态上报（开始/进度/停止），每 10 秒上报一次进度

### 2.5 图片查看

**页面**: `lib/players/image_viewer_page.dart`

- SMB 图片全屏查看
- 双指缩放（0.5x ~ 5x）
- 图片信息面板（路径、大小、创建时间、修改时间、只读状态）
- 删除图片

---

## 3. 技术实现细节

### 3.1 SMB 流媒体服务器 (`lib/smb_stream_server.dart`)

Dart 侧实现的本地 HTTP 代理服务器，用于将 SMB 文件转为 HTTP 流供播放器消费：

- **绑定**: `127.0.0.1:0`（随机端口）
- **分块缓存**: 2MB 一块，最多缓存 32 块（LRU 淘汰）
- **预读**: 打开视频时预读第 0 块，播放时预读下一块
- **Range 请求**: 完整支持 HTTP Range，用于视频 seek

### 3.2 Android 原生 SMB 实现

#### SmbService (`android/.../smb/SmbService.kt`)
- 基于 SMBJ 库，纯 Java/Kotlin SMB2/3 客户端
- 会话管理：`ConcurrentHashMap<String, SmbConnection>`
- Share 连接缓存：每个 session 内缓存已连接的 share
- 随机读取：`SmbFileHandle.readAt()` 使用 `File.read(buffer, fileOffset, ...)` 实现 O(1) seek

#### NativeSmbHttpServer (`android/.../smb/NativeSmbHttpServer.kt`)
- 轻量级 HTTP 服务器，绑定本地回环地址
- 完整支持 Range 请求（206 Partial Content）
- 256KB 读取缓冲区
- 使用 `SmbFileHandle` 随机访问，避免 InputStream.skip() 的线性开销

#### SmbContentProvider (`android/.../smb/SmbContentProvider.kt`)
- Android ContentProvider，将 SMB 文件暴露为 `content://` URI
- 通过管道（Pipe）在后台线程流式传输数据
- 支持 offset/length 查询参数实现范围读取

### 3.3 HDR/杜比视界检测 (`lib/emby_client.dart`)

- `HdrDetector`: 通过 MethodChannel 调用 Android 原生 API
- 检测设备是否支持 Dolby Vision 和 HDR
- 在文件名中检测 "dolby" / ".dv." / ".dovi." 等关键词

### 3.4 缩略图系统 (`lib/pages/browser_page.dart`)

- **图片缩略图**: 读取 SMB 文件后使用 `ui.instantiateImageCodec` 缩放到 256px
- **视频缩略图**: 通过 `get_thumbnail_video` 包从本地 HTTP 流截取帧
- **缓存**: LRU 缓存，最多 200 条
- **限流**: 视频缩略图信号量限制最多 3 并发
- **延迟加载**: 列表中每个缩略图延迟 index*80ms 加载，优先渲染列表

### 3.5 数据持久化 (`lib/server_store.dart`)

- 使用 `flutter_secure_storage` 加密存储
- 存储键：`nas_servers`（服务器列表 JSON）、`last_server_id`（上次连接的服务器 ID）

---

## 4. 文件结构

```
lib/
├── main.dart                          # 应用入口，MaterialApp 配置
├── models.dart                        # 数据模型（ServerConfig, EmbyItem, 枚举）
├── emby_client.dart                   # Emby API 客户端（认证、库浏览、流地址、播放上报）
├── smb_native_client.dart             # Android 原生 SMB MethodChannel 桥接
├── smb_stream_server.dart             # Dart 本地 HTTP 代理服务器
├── server_store.dart                  # 服务器配置持久化
├── utils.dart                         # 工具函数（文件类型判断、格式化、MIME 类型）
├── widgets/
│   └── common.dart                    # 通用 Widget（SecondsIcon, StreamingVideo, EmptyState, ErrorState）
├── pages/
│   ├── server_home_page.dart          # 服务器列表/添加/编辑/切换
│   ├── browser_page.dart              # SMB 文件浏览（列表/缩略图/分页）
│   ├── emby_home_page.dart            # Emby 首页（最近播放 + 媒体库）
│   ├── emby_library_page.dart         # Emby 媒体库详情
│   └── emby_series_page.dart          # Emby 剧集列表
└── players/
    ├── video_player_page.dart         # SMB 视频播放器
    ├── network_video_player_page.dart # Emby 视频播放器
    └── image_viewer_page.dart         # SMB 图片查看器

android/.../smb/
├── SmbService.kt                      # SMBJ 封装（连接、列表、读取、删除）
├── NativeSmbHttpServer.kt             # 原生 HTTP 服务器（Range 支持）
└── SmbContentProvider.kt              # ContentProvider（content:// URI）
```

---

## 5. 依赖清单

| 包 | 用途 |
|----|------|
| `media_kit` / `media_kit_video` / `media_kit_libs_video` | 视频播放引擎（libmpv） |
| `smb_connect` | Dart 侧 SMB 客户端 |
| `flutter_secure_storage` | 加密存储服务器凭据 |
| `screen_brightness` | 屏幕亮度调节 |
| `volume_controller` | 系统音量调节 |
| `get_thumbnail_video` | 视频缩略图生成 |

---

## 6. 已知问题

- SMB 视频播放性能问题（git log 提及 "smb播放视频非常慢，待修复"），原生 SMBJ 通道已实现作为优化方案
