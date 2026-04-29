# AIClient-2-API 开发迭代 TODO

## 额度管理（高优先级）

### 1. 主动额度检测与账号停用
- **现状**：只在 Kiro 返回 402 错误后才调用 `getUsageLimits()` 确认额度耗尽，属于被动检测
- **问题**：额度用完的那一次请求会失败，且无法在接近耗尽时提前停用账号
- **需求**：
  - 单账号剩余积分 < 50（可配置）时，停止使用该账号，切换到其他账号
  - 所有账号剩余积分均 < 20（可配置）时，直接返回错误，不再发起请求
- **方案**：
  1. 在 `KiroApiService` 中新增定时额度查询（如每 10 分钟调用一次 `getUsageLimits()`），缓存 `usedCount` / `limitCount` 到节点状态
  2. 每次请求前也查一次缓存的额度（不是每次都调 API，避免额外开销）
  3. 在 `_calculateNodeScore()` 中加入额度惩罚：剩余积分低于阈值的节点评分设为极大值（等同不健康）
  4. 在 `acquireSlot()` 中加入全局检查：如果所有健康节点的剩余积分都低于全局最低阈值，抛出错误返回给客户端
- **配置项**（加入 `config.json`）：
  ```json
  {
    "quotaControl": {
      "singleAccountMinCredits": 50,
      "globalMinCredits": 20,
      "checkIntervalMinutes": 10
    }
  }
  ```
- **涉及文件**：
  - `src/providers/claude/claude-kiro.js`（`getUsageLimits` 定时调用 + 缓存）
  - `src/providers/provider-pool-manager.js`（`_calculateNodeScore` 额度惩罚 + `acquireSlot` 全局检查）
  - `configs/config.json.example`（新增配置项）

---

## 池管理（ProviderPoolManager）优化

### 2. 响应延迟感知
- **现状**：评分只看健康状态和使用次数，不感知响应速度
- **问题**：某个账号被隐性限速（响应变慢但不返回 429），评分不会降低，请求继续分配过去
- **方案**：在 `_calculateNodeScore()` 中加入平均响应时间惩罚项，记录每个节点最近 N 次请求的响应耗时，响应慢的节点评分升高
- **涉及文件**：`src/providers/provider-pool-manager.js`

### 3. 滑动窗口限流
- **现状**：错误计数用 10 秒窗口，超过窗口重置为 1。没有请求频率限制
- **问题**：如果某个账号有隐性速率限制（如每分钟 10 次），当前机制感知不到，会一直打到 429 才切换
- **方案**：为每个节点维护一个滑动窗口计数器（如 1 分钟窗口），接近阈值时主动降低评分或暂停分配
- **涉及文件**：`src/providers/provider-pool-manager.js`，可能需要新增 `src/utils/rate-limiter.js`

### 4. 半开状态（Half-Open）恢复
- **现状**：账号被标记不健康后，要么等定时恢复，要么等健康检查，恢复后立即接收全量请求
- **问题**：直接恢复可能导致大量请求涌入刚恢复的账号，如果实际上还没好会造成一波失败
- **方案**：引入半开状态——先放 1 个请求试探，成功则完全恢复，失败则继续保持不健康。类似断路器（Circuit Breaker）模式
- **涉及文件**：`src/providers/provider-pool-manager.js`（`_checkAndRecoverScheduledProviders` 方法）

### 5. 账号渐进式预热
- **现状**：新加入或刚恢复的账号因 `isFresh` 获得 `-1e14` 极低分，所有请求瞬间涌向它
- **问题**：如果该账号实际有问题（token 快过期、配额不足），会造成一波请求集中失败
- **方案**：新/恢复节点设置一个预热期（如 30 秒），期间逐步增加分配权重，而非一步到位
- **涉及文件**：`src/providers/provider-pool-manager.js`（`_calculateNodeScore` 方法）

---

## 提示词覆盖增强

### 6. 持续观察 Kiro 身份覆盖效果
- **现状**：采用双重注入策略（首条消息 builtInPrefix + 末条消息 identityReminder）对抗 Kiro 后端系统提示词
- **风险**：Kiro 后端更新系统提示词后可能失效
- **观察点**：在不同客户端（Claude Code、Chatbox、Cherry Studio）测试身份回复是否正确
- **涉及文件**：`src/providers/claude/claude-kiro.js`（`buildCodewhispererRequest` 方法）
