# AIClient-2-API 维护手册

## 环境信息

| 项目 | 值 |
|---|---|
| 本地项目目录 | `/Users/zhongsheng.xia/Documents/Git/AIClient-2-API` |
| Fork 仓库 | `git@github-ggdrerfsd:ggdrerfsd/AIClient-2-API.git` (origin) |
| 原作者仓库 | `https://github.com/justlovemaki/AIClient-2-API.git` (upstream) |
| VPS 代码目录 | `/root/AIClient-2-API` |
| VPS Docker 目录 | `/opt/1panel/docker/compose/aiclient2api` |
| VPS 连接方式 | `ssh root@YOUR_VPS_IP` |

---

## 场景一：本地修改代码后部署

当你在本地修改了代码（新功能、bug 修复等），需要推送到 fork 仓库并在 VPS 上重新部署。

### Mac 本地操作

```bash
cd /Users/zhongsheng.xia/Documents/Git/AIClient-2-API

# 1. 查看改了什么
git status
git diff

# 2. 提交
git add 改动的文件1 改动的文件2
git commit -m "描述你的改动"

# 3. 推送到你的 fork
git push origin main
```

### VPS 部署

**方式 A：脚本部署（推荐）**

```bash
ssh root@YOUR_VPS_IP
cd /root/AIClient-2-API
git pull
./ilaoxia/deploy.sh

curl -s http://localhost:3000/v1/messages \
  -H "x-api-key: sk-b91364de572cb170faa83f1fb38aa635" \
  -H "Content-Type: application/json" \
  -H "anthropic-version: 2023-06-01" \
  -d '{"model":"claude-opus-4-6","max_tokens":200,"messages":[{"role":"user","content":"What is your name and what are you?"}]}' | python3 -m json.tool
```

**方式 B：手动部署**

```bash
ssh root@YOUR_VPS_IP
cd /root/AIClient-2-API
git pull
docker build -t justlikemaki/aiclient-2-api:latest .
cd /opt/1panel/docker/compose/aiclient2api
docker compose down && docker compose up -d

# 确认容器正常
docker ps | grep aiclient
docker compose logs --tail=20


curl -s http://localhost:3000/v1/messages \
  -H "x-api-key: sk-your-api-key-here" \
  -H "Content-Type: application/json" \
  -H "anthropic-version: 2023-06-01" \
  -d '{"model":"claude-opus-4-6","max_tokens":200,"messages":[{"role":"user","content":"What is your name and what are you?"}]}' | python3 -m json.tool
```

---

## 场景二：同步原作者更新后部署

当原作者仓库有新版本发布，需要把更新合并到你的 fork 中。所有代码合并操作在 Mac 上完成，VPS 只负责部署。

### Mac 本地操作

```bash
cd /Users/zhongsheng.xia/Documents/Git/AIClient-2-API

# 1. 拉取原作者最新代码
git fetch upstream

# 2. 查看原作者有哪些新提交
git log main..upstream/main --oneline

# 3. 合并到你的 main 分支
git checkout main
git merge upstream/main

# 4. 如果有冲突：
#    - 打开冲突文件，手动解决 <<<< ==== >>>> 标记
#    - git add 解决后的文件
#    - git commit

# 5. 推送到你的 fork
git push origin main
```

### VPS 部署

**方式 A：脚本部署（推荐）**

```bash
ssh root@YOUR_VPS_IP
cd /root/AIClient-2-API
git pull
./ilaoxia/deploy.sh
```

**方式 B：手动部署**

```bash
ssh root@YOUR_VPS_IP
cd /root/AIClient-2-API
git pull
docker build -t justlikemaki/aiclient-2-api:latest .
cd /opt/1panel/docker/compose/aiclient2api
docker compose down && docker compose up -d

# 确认容器正常
docker ps | grep aiclient
docker compose logs --tail=20
```

---

## 部署脚本说明

仓库 `ilaoxia/deploy.sh` 会自动完成：拉取代码 → 构建镜像 → 重启容器 → 验证运行状态。

脚本首次使用前需要在 VPS 上赋予执行权限（只需一次）：

```bash
cd /root/AIClient-2-API
chmod +x ilaoxia/deploy.sh
```

---

## 完整工作流总结

```
Mac 本地操作（二选一）
├── 本地改代码：git add → git commit → git push origin main
└── 同步原作者：git fetch upstream → git merge upstream/main
                → 解决冲突(如有) → git push origin main
        │
        ▼
VPS 部署（二选一）
├── 脚本部署：cd /root/AIClient-2-API && git pull && ./ilaoxia/deploy.sh
└── 手动部署：git pull → docker build → docker compose down/up
```

---

## 常用排查命令

```bash
# 查看容器日志
cd /opt/1panel/docker/compose/aiclient2api
docker compose logs -f --tail=50

# 进入容器内部检查文件
docker exec -it aiclient2api sh

# 检查某个文件是否包含你的改动
docker exec aiclient2api grep "thinking" /app/src/providers/provider-models.js

# 检查模型列表
curl -s -H "Authorization: Bearer YOUR_API_KEY" http://localhost:3000/v1/models | python3 -m json.tool

# 回滚到上一个版本（如果部署出问题）
cd /root/AIClient-2-API
git log --oneline -5          # 找到上一个正常的 commit hash
git checkout <commit-hash>    # 切到那个版本
./ilaoxia/deploy.sh           # 重新部署
```
