# HealthSync Server — 部署文档

FastAPI 服务，接收 iOS HealthSync App 推送的健康样本并落盘到本地 Obsidian vault（`data/raw/YYYY-MM-DD.json`）。

运行时要求 Python 3.9+。

## 环境变量

| 变量 | 必填 | 说明 |
|---|---|---|
| `HEALTH_API_TOKEN` | ✅ | 客户端 Bearer Token，无默认（未设置启动即退出） |
| `OBSIDIAN_VAULT` | ✅ | Obsidian vault 根目录（将写入其下 data/raw） |
| `HEALTH_TIMEZONE` | 可选 | 日期归档时区，默认 `UTC`；已有数据不应随意修改该值 |
| `HEALTH_CORS_ORIGINS` | 可选 | 允许的网页来源，逗号分隔；默认不启用 CORS |
| `DASHBOARD_SCRIPT` | 可选 | 每次 ingest 后额外执行的看板刷新脚本路径 |

## 启动

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
export HEALTH_API_TOKEN='...'
export OBSIDIAN_VAULT='/path/to/vault'
uvicorn health_api_server:app --host 0.0.0.0 --port 8765
```

## 接口

| 方法 | 路径 | 说明 |
|---|---|---|
| POST | `/api/ingest` | 接收批量样本（主要） |
| POST | `/api/health` | 旧版快捷指令摘要写入 |
| GET | `/api/health/latest` | 获取最新摘要 |
| GET | `/` | 健康检查 |

所有接口除 `/` 外均校验 `Authorization: Bearer <TOKEN>`。

`/api/ingest` 使用 Pydantic 校验 UUID、类型、时区感知日期、有限数值、fingerprint 和 ECG 波形。每日 JSON 使用文件锁与临时文件原子替换写入；损坏文件会先重命名为 `.corrupt-*` 备份，不会静默覆盖。

上传协议中的 UUID 和 fingerprint 只用于去重。持久化到 `data/raw/YYYY-MM-DD.json` 时会自动精简为核心字段：`type`、`category`、`startDate`、`endDate`、`value`、`unit`、`sourceName`。睡眠、ECG 和锻炼等类型会按需保留 `valueDescription`、`metadata`、`ecgVoltageMeasurements`。旧格式会在启动时备份到 `data/.backups/raw-pre-optimized-*` 后自动迁移。

## 安全提示
- **务必设置你的 `HEALTH_API_TOKEN`**，示例/默认值已被移除，未设置无法启动。
- 公网部署强烈建议加 Cloudflare Tunnel / 防火墙限制端口。
