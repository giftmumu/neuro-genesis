# DeepSeek JSON Mode 独立证据

> **日期**: 2026-08-16 | **P1 待办 #2** | 状态: ✅ 完成
> 原始响应: `evidence/deepseek-jsonmode-direct-2026-08-16.json`（直连）· `evidence/deepseek-jsonmode-chain-2026-08-16.json`（链路）

## 结论

**DeepSeek 的 `response_format: {"type": "json_object"}` 经两次真实调用验证，均返回合法 JSON。**

## 证据一：直连 DeepSeek 官方 API（独立）

```
POST https://api.deepseek.com/v1/chat/completions   （经 Clash :7890 出网）
Authorization: Bearer $DEEPSEEK_API_KEY
{
  "model": "deepseek-chat",
  "response_format": {"type": "json_object"},
  "temperature": 0.2, "max_tokens": 200
}
```

| 字段 | 值 |
|------|-----|
| model | `deepseek-v4-flash`（`deepseek-chat` 别名已解析到 V4 Flash）|
| finish_reason | `stop` |
| usage | 80 prompt + 17 completion = 97 tokens |
| content | `{"status":"ok","project":"Neuro-Genesis","mode":"json_object"}` |
| content 合法性 | ✅ `json.loads` 解析成功 |

## 证据二：生产链路（网关→CC-Switch→DeepSeek）

```
POST http://127.0.0.1:4386/v1/chat/completions   （双相网关）
Authorization: Bearer sk-ant-ccswitch-proxy-routed
{ "model": "deepseek-v4-flash", "response_format": {"type":"json_object"}, "max_tokens": 2000 }
```

| 字段 | 值 |
|------|-----|
| model | `deepseek-v4-flash` |
| finish_reason | `stop` |
| usage | 618 prompt + 84 completion = 702 tokens（**512 cached，命中率 82%**）|
| content | `{"chain":"gateway->ccswitch->deepseek","json_mode":true,"ok":1}` |
| content 合法性 | ✅ `json.loads` 解析成功 |

## 附带的两个真实发现

1. **CC-Switch 将 `deepseek-v4-flash` 路由到推理模型**：响应含 `reasoning_content`（254 字符）+ `completion_tokens_details.reasoning_tokens=62`。首次尝试 `max_tokens=200` 时思考耗尽预算 → `finish_reason=length`、`content` 为空；加大到 2000 后正常。
2. **DeepSeek 提示词缓存生效**：`prompt_cache_hit_tokens=512`，命中率 82%，说明链路已吃上 DeepSeek 的 prefix caching。

## 备注

- 生产链路的模型 ID 是 `deepseek-v4-flash/pro`（CC-Switch 映射名）；直连用官方别名 `deepseek-chat`。
- API key 取自环境变量 `DEEPSEEK_API_KEY`（未落盘明文）。
