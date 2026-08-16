FROM python:3.11-slim
WORKDIR /app

# 使用阿里云镜像 + 增加超时和重试
RUN pip install --default-timeout=100 --retries=5 \
    fastapi uvicorn transformers torch requests \
    -i https://mirrors.aliyun.com/pypi/simple/ \
    --trusted-host mirrors.aliyun.com

# ========== 2026-08-16: 模型烘焙进镜像 ==========
# 构建环境（GitHub Actions）有网 → 构建时下载模型烤进 /app/models/hub/
# 运行时零联网、零挂载（无需 /mnt/f 缓存），冷启动也完全可移植
# 注意：transformers 5.11 缺 chat_template 时仍会尝试联网拉 hub 模板
# （privoxy 不支持 CONNECT→501），必须离线模式强制用本地缓存
RUN HF_HOME=/app/models python -c "from transformers import AutoTokenizer, AutoModelForSequenceClassification; AutoTokenizer.from_pretrained('uer/roberta-base-finetuned-dianping-chinese'); AutoModelForSequenceClassification.from_pretrained('uer/roberta-base-finetuned-dianping-chinese'); print('>>> [BAKE] Model baked to /app/models')"

ENV HF_HOME=/app/models \
    HF_HUB_OFFLINE=1 \
    TRANSFORMERS_OFFLINE=1

COPY . .
EXPOSE 8001
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8001"]
