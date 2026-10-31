# HealthSync-iOS

把 iPhone 的 Apple HealthKit 数据（活动 / 心率 / 睡眠 / 体重等）通过自建服务器安全同步到本地归档（Obsidian / 数据库 / 任意自托管）。

- **iOS App（SwiftUI / Swift 6）**：订阅 HealthKit 全量类型，增量游标 + fingerprint 去重，支持前台与系统调度的后台同步。
- **Server 端（FastAPI）**：`server/health_api_server.py` 接收并落盘样本，可按天写入 Obsidian Vault 的 `data/raw/`。
- 支持局域网直连或公网 HTTPS 隧道（如 Cloudflare Quick Tunnel）。

> 本项目由个人项目重构脱敏后开源，已去除所有私有服务器地址 / Token / 个人信息，可放心 clone、二次开发。

---

## 架构

```text
HealthKit ──▶ HKObserverQuery / BGTaskScheduler
                        │
                        ▼
                 SyncCoordinator
                        │
        HTTPS / 本地 HTTP + Bearer Token
                        │
                        ▼
                FastAPI Server (8765)
                        │
                        ▼
      data/raw/YYYY-MM-DD.json（精简记录）
```

- 推荐在服务器前挂 **Cloudflare Quick Tunnel**（或 Nginx + TLS），App 端走 HTTPS + 域名（ATS 放行），无需自签证书。
- Token 认证：请求头 `Authorization: Bearer <token>`，服务端通过环境变量 `HEALTH_API_TOKEN` 校验。
- 上传使用逐页查询与后台上传；服务端按内容哈希幂等去重并自动精简落盘字段。

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

至少先完成一次前台同步，并允许访问健康数据和本地网络。后台任务只有在 HealthKit 授权、服务器地址与 Token 均有效后才会排期。

---

## 功能

- [x] 全量 / 增量 / 强制全量三种同步模式
- [x] SHA-256 数据指纹 + UUID 去重（幂等重放）
- [x] HealthKit 后台投递 + `BGAppRefreshTask` 定期补扫 + `BGProcessingTask` 首次回填
- [x] 可恢复的后台 `URLSession` 上传 + 失败自动重试
- [x] 打开 App 自动同步
- [x] 逐页查询、逐页上传，避免全量历史占用内存
- [x] ECG 分类、平均心率、采样率与电压波形
- [x] 设置持久化（Keychain 存连接信息、UserDefaults 存同步配置）
- [x] 服务器地址 / Token 可在设置页动态改，无需重编译
- [x] 局域网直连 + 公网隧道双模式
- [x] 无任何第三方 SDK / 广告 / 埋点

## 数据模型

上传请求保留 UUID 和 fingerprint，用于服务端幂等去重。写入 `data/raw/` 时自动精简为以下格式：

```json
{
  "type": "HKQuantityTypeIdentifierHeartRate",
  "category": "heart",
  "startDate": "2026-10-30T22:08:32Z",
  "endDate": "2026-10-30T22:08:32Z",
  "value": 68.0,
  "unit": "count/min",
  "sourceName": "Chookyin的Apple Watch"
}
```

睡眠、ECG、锻炼等类型仅额外保留有意义字段，例如 `valueDescription`、`metadata` 或 `ecgVoltageMeasurements`。旧文件会在服务启动时先备份到 `data/.backups/raw-pre-optimized-*`，再自动迁移。

后端按 `startDate` 和 `HEALTH_TIMEZONE`（默认 UTC）落到 `data/raw/YYYY-MM-DD.json`。

## 后台同步

后台同步由四层组成：

1. `HKObserverQuery` 在已授权的健康数据类型变化后唤醒 App，只查询发生变化的类型。
2. `BGAppRefreshTask` 约每 30 分钟申请一次短期补扫，实际执行时间由 iOS 决定。
3. `BGProcessingTask` 在“首次全量后增量”模式且尚未完成全量时运行，要求联网和外部电源。
4. `URLSession` 后台会话以临时文件上传请求体，App 挂起时由系统继续传输。

设置页可单独关闭“后台自动同步”。iOS 不保证固定执行间隔，也不保证用户手动强制退出 App 后仍继续调度；服务器端仍需保留 UUID / fingerprint 幂等去重。

工程已配置：

- HealthKit capability 中的 Background Delivery entitlement
- `fetch`、`processing` 后台模式
- 两个 `BGTaskSchedulerPermittedIdentifiers`

更换 Bundle ID 后，Xcode 仍会从构建变量自动展开任务标识；真机运行前请重新确认 HealthKit capability 和签名团队。

部分 HealthKit 类型可能不支持 Background Delivery，App 会保留其余可用类型并记录失败项。后台短任务只回看较短时间窗口；首次全量回填失败时会保留 `completedFullSyncAt = nil`，下次继续重试。

## 验证状态

当前本地已验证：

- Swift 6 严格并发构建通过。
- iPhone 17 Pro 模拟器 XCTest `12/12` 通过，覆盖地址解析、同步窗口、稳定指纹、游标迁移、类别映射、后台策略、401 不重试、503 重试和取消传播。
- 签名版 App 可安装启动，HealthKit 授权页面可正常弹出，启动进程无 App 错误或崩溃。
- 服务端 pytest `8/8` 通过，覆盖鉴权、请求校验、内容去重、ECG 波形、损坏文件恢复和 CORS。
- 运行中服务健康检查正常，精简数据格式正确，现有记录不含 UUID / fingerprint 字段。

仍需真机确认：

- `HKObserverQuery` 在真实 HealthKit 数据变化后的后台唤醒。
- `BGAppRefreshTask`、`BGProcessingTask` 的实际执行时机，由 iOS 动态决定，无法在模拟器中强制保证。
- App 被挂起或进程回收后，后台 `URLSession` 的最终完成与服务器落盘。
- 锁屏状态下通过局域网 HTTP 访问服务器。

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
├── .github/workflows/ci.yml   # GitHub Actions
├── HealthSync.xcodeproj       # Xcode 工程
├── HealthSync/                # iOS 源码（SwiftUI）
│   ├── App/                   # App 入口、同步协调、后台任务
│   ├── Core/                  # 模型、DTO、工具
│   ├── Features/              # 设置页 / 数据看板
│   ├── Services/              # HealthKit、网络、Keychain
│   └── Resources/             # Info.plist、图标
├── HealthSyncTests/           # XCTest 单元测试
└── server/
    ├── health_api_server.py   # FastAPI 接收端
    ├── requirements-dev.txt   # 服务端测试依赖
    ├── run-local.sh           # 本地服务启动脚本
    ├── tests/                 # pytest 服务端测试
    └── README.md              # 服务端部署详细文档
```

## 测试

```bash
# iOS：编译并要求测试目标完整构建
xcodebuild build-for-testing \
  -project HealthSync.xcodeproj \
  -scheme HealthSync \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO

# iOS：在模拟器执行 XCTest（按本机可用设备修改名称）
xcodebuild test \
  -project HealthSync.xcodeproj \
  -scheme HealthSync \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  CODE_SIGNING_ALLOWED=NO

# Server
cd server
python3 -m venv .venv
.venv/bin/pip install -r requirements-dev.txt
.venv/bin/pytest
```

GitHub Actions 会运行 Swift 6 构建、iOS 模拟器 XCTest，以及 Python 3.9/3.12 服务端测试。后台系统调度和 HealthKit 真机行为不能仅靠 CI 模拟器证明，发布前仍需完成一次真机验证。

> `HealthSync/Features/Dashboard/` 等看板 UI 依赖本地自定义解析器，服务端未附带；只依赖 `data/raw` 的数据流已完整可跑。

## License

MIT，自由使用。

---

**贡献**：修 Bug / 加功能欢迎提 PR。若你改了服务器字段，记得同步更新 `server/README.md`。
