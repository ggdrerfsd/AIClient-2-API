#!/bin/bash
set -e

# 脚本在 ilaoxia/ 子目录下，往上一级即为仓库根目录
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE_DIR="/opt/1panel/docker/compose/aiclient2api"
IMAGE_NAME="justlikemaki/aiclient-2-api:latest"

echo "====== 1. 拉取最新代码 ======"
cd "$REPO_DIR"
git pull

echo ""
echo "====== 2. 构建 Docker 镜像 ======"
docker build -t "$IMAGE_NAME" "$REPO_DIR"

echo ""
echo "====== 3. 重启容器 ======"
cd "$COMPOSE_DIR"
docker compose down
docker compose up -d

echo ""
echo "====== 4. 等待启动 ======"
sleep 5

echo ""
echo "====== 5. 验证 ======"
if docker ps | grep -q aiclient; then
    echo "容器运行正常"
    docker ps | grep aiclient
else
    echo "容器未启动，请检查日志："
    echo "  docker compose -f $COMPOSE_DIR/docker-compose.yml logs --tail=50"
    exit 1
fi

echo ""
echo "====== 部署完成 ======"
