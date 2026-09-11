# HealthSync Server — 部署文档

FastAPI 服务，接收 iOS HealthSync App 推送的健康样本并落盘到本地 Obsidian vault（`data/raw/YYYY-MM-DD.json`）。

## 环境变量

| 变量 | 必填 | 说明 |
|---|---|---|
| `HEALTH_API_TOKEN` | ✅ | 客户端 Bearer Token，无默认（未设置启动即退出） |
| `OBSIDIAN_VAULT` | ✅ | Obsidian vault 根目录（将写入其下 data/raw） |
| `DASHBOARD_SCRIPT` | 可选 | 每次 ingest 后额外执行的看板刷新脚本路径 |

## 启动

```bash
export HEALTH_API_TOKEN='...'
export OBSIDIAN_VAULT='/path/to/vault'
uvicorn health_api_server:app --host 0.0.0.0 --port 8765
```

## 接口

| 方法 | 路径 | 说明 |
|---|---|---|
| POST | `/api/ingest` | 接收批量样本（主要） |
| POST | `/api/health/data` | 旧版查询接口（兼容） |
| POST | `/api/health/report` | 报告接收（兼容） |
| GET | `/` | 健康检查 |

所有接口除 `/` 外均校验 `Authorization: Bearer <TOKEN>`。

## 安全提示
- **务必设置你的 `HEALTH_API_TOKEN`**，示例/默认值已被移除，未设置无法启动。
- 公网部署强烈建议加 Cloudflare Tunnel / 防火墙限制端口。