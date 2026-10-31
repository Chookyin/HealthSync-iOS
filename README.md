# HealthSync-iOS

把 iPhone 的 Apple HealthKit 数据（活动 / 心率 / 睡眠 / 体重等）通过自建服务器安全同步到本地归档（Obsidian / 数据库 / 任意自托管）。

- **iOS App（SwiftUI / Swift 6）**：订阅 HealthKit 全量类型，增量游标 + fingerprint 去重，打开 App 即同步。
- **Server 端（FastAPI）**：`server/health_api_server.py` 接收并落盘样本，可按天写入 Obsidian Vault 的 `data/raw/`。
- 支持局域网直连或公网 HTTPS 隧道（如 Cloudflare Quick Tunnel）。

> 本项目由个人项目重构脱敏后开源，已去除所有私有服务器地址 / Token / 个人信息，可放心 clone、二次开发。

---

## 架构

```text
┌─────────────┐ HTTPS/本地HTTP + Token  ┌──────────────────┐
│   iPhone     │ ───────────────────────▶ │   Server (8765)  │
│  HealthSync  │                          │  health_api_server│
│   (SwiftUI)  │ ◀─────────────────────── │  (FastAPI + uvicorn) │
└─────────────┘                          └────────┬─────────┘
                                                  │ 写盘
                                        ┌─────────▼─────────┐
                                        │ Obsidian Vault     │
                                        │ data/raw/YYYY-MM-DD.json
                                        └───────────────────┘
```

- 推荐在服务器前挂 **Cloudflare Quick Tunnel**（或 Nginx + TLS），App 端走 HTTPS + 域名（ATS 放行），无需自签证书。
- Token 认证：请求头 `Authorization: Bearer <token>`，服务端通过环境变量 `HEALTH_API_TOKEN` 校验。

---

## 快速开始

### 1. 准备服务器（任选其一）

**本机局域网（macOS）**

```bash
cd server/
export HEALTH_API_TOKEN="换成你的强随机 Token"
export OBSIDIAN_VAULT="$HOME/Library/Mobile Documents/iCloud~md~obsidian/Documents/Health"
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
uvicorn health_api_server:app --host 0.0.0.0 --port 8765
```

**公网（腾讯云 / 阿里云 + Cloudflare Quick Tunnel）**

```bash
# 1. 服务器上启动 relay（监听 8765，HTTP 即可）
export HEALTH_API_TOKEN=your_token
export OBSIDIAN_VAULT=/path/to/vault
nohup uvicorn health_api_server:app --host 0.0.0.0 --port 8765 &

# 2. 启动 Cloudflare Quick Tunnel（域名 443 → 本地 8765）
nohup cloudflared tunnel --url http://127.0.0.1:8765 --no-autoupdate &
# 输出中的 https://xxx.trycloudflare.com 就是 App 里要填的地址
```

> ⚠️ Quick Tunnel 域名会随重启变化。建议写脚本把新域名通知到你的网关（或改用固定域名 / 自有证书）。详见下方[常见坑]。

### 2. 构建 iOS App

前置：macOS + Xcode 16+，iPhone 真机（iOS 18+，HealthKit 可用）。

```bash
open HealthSync.xcodeproj
```

Xcode 里：
1. **Signing & Capabilities** → 把你的 Apple ID 设成 Team（免费账号即可，7 天有效）；
2. Bundle ID 改成你自己的（避免与线上已有版本冲突）；
3. 真机运行（首次运行需在 iPhone「设置 → 通用 → VPN 与设备管理」信任开发者）。

### 3. 在 App 里配置

打开 App → 设置页 → 填三项：

| 字段 | 值 |
|---|---|
| 服务器地址 | `你的隧道域名`，或粘贴完整 URL（如 `http://192.168.x.x:8765`） |
| 端口 | `443`（HTTPS）或 `8765`（局域网 HTTP） |
| API Token | 与服务器 `HEALTH_API_TOKEN` 一致 |

点「测试连接」，绿色即通。然后回首页点同步。

---

## 功能

- [x] 全量 / 增量 / 强制全量三种同步模式
- [x] SHA-256 数据指纹 + UUID 去重（幂等重放）
- [x] 打开 App 自动同步 + 上传失败自动重试
- [x] 逐页查询、逐页上传，避免全量历史占用内存
- [x] ECG 分类、平均心率、采样率与电压波形
- [x] 设置持久化（Keychain 存连接信息、UserDefaults 存同步配置）
- [x] 服务器地址 / Token 可在设置页动态改，无需重编译
- [x] 局域网直连 + 公网隧道双模式
- [x] 无任何第三方 SDK / 广告 / 埋点

## 数据模型

样本格式（与后端直接对应）：

```json
{
  "device": {"model": "iPhone17,2", "os": "27.0", "app": "HealthSync/1.0"},
  "batch": [
    {
      "id": "UUID",
      "type": "HKQuantityTypeIdentifierHeartRate",
      "category": "heart",
      "startDate": "2026-09-01T08:00:00Z",
      "endDate": "2026-09-01T08:00:01Z",
      "value": 62.0,
      "unit": "count/min",
      "sourceName": "Apple Watch",
      "sourceBundleID": "com.apple.health",
      "fingerprint": "sha256..."
    }
  ],
  "range": {"start": "...", "end": "..."},
  "cursorFingerprint": "...",
  "fullSync": false
}
```

后端按 `startDate` 和 `HEALTH_TIMEZONE`（默认 UTC）落到 `data/raw/YYYY-MM-DD.json`。

## 自定义坑（亲身经历）

### ① HTTPS 是硬门槛
- iOS **禁止 App 直接访问公网裸 IP 的 HTTP**（ATS 拦截），必须：**HTTPS + 域名**。
- 本地局域网 IP 可豁免（`NSAllowsLocalNetworking` 已在工程内配置）。
- 自签证书 + 安装描述文件也救不了 ATS，唯一正路是 Cloudflare/ 合法证书。

### ② 免费开发证书 7 天过期
- 免费 Apple ID 签名的 App **7 天有效**，到期 App 打不开（报「无法验证」/「未信任」）。
- 重新签名安装即可恢复；想省事用付费开发者账号或 AltStore 自动续签。

### ③ Cloudflare Tunnel 域名会变
- Quick Tunnel 重启后域名必变，App 地址要跟着改。
- 方案：写死 tunnel 域名到你的网关/加速器，或者用固定域名 + 自己的域名解析到隧道。

## 目录结构

```
.
├── HealthSync.xcodeproj      # Xcode 工程
├── HealthSync/                # iOS 源码（SwiftUI）
├── HealthSyncTests/           # XCTest 单元测试
│   ├── App/                   # App 入口、同步协调器、设置模型
│   ├── Core/                  # 模型、DTO、工具
│   ├── Features/              # 设置页 / 数据看板
│   ├── Services/              # HealthKit、网络、Keychain
│   └── Resources/             # Info.plist、图标
└── server/
    ├── health_api_server.py   # FastAPI 接收端
    ├── requirements-dev.txt   # 服务端测试依赖
    ├── tests/                 # pytest 服务端测试
    └── README.md              # 服务端部署详细文档
```

## 测试

```bash
# iOS：本地编译 XCTest
xcodebuild build-for-testing \
  -project HealthSync.xcodeproj \
  -scheme HealthSync \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO

# Server
cd server
python3 -m venv .venv
.venv/bin/pip install -r requirements-dev.txt
.venv/bin/pytest
```

GitHub Actions 会运行 Swift 6 构建、iOS 模拟器 XCTest，以及 Python 3.9/3.12 服务端测试。

> `HealthSync/Features/Dashboard/` 等看板 UI 依赖本地自定义解析器，服务端未附带；只依赖 `data/raw` 的数据流已完整可跑。

## License

MIT，自由使用。

---

**贡献**：修 Bug / 加功能欢迎提 PR。若你改了服务器字段，记得同步更新 `server/README.md`。
