FROM python:3.11-slim
WORKDIR /app

# 使用阿里云镜像 + 增加超时和重试
RUN pip install --default-timeout=100 --retries=5 \
    fastapi uvicorn transformers torch requests \
    -i https://mirrors.aliyun.com/pypi/simple/ \
    --trusted-host mirrors.aliyun.com

COPY . .
EXPOSE 8001
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8001"]
