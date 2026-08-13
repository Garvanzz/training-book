# API 契约

`openapi.yaml` 是 v1 目标契约。当前已实现并验证 `/health`、`/v1/auth/login` 和 `/v1/auth/refresh` 的路由注册；登录路由仍需要 PostgreSQL 实例和已创建 Owner 账号才能完成端到端验证。

同步与动作库端点的 schema 已冻结，但尚未实现，故合同被标记为 `draft`。每实现一个端点必须同时：

1. 加入 FastAPI 路由；
2. 加入请求、授权和错误场景测试；
3. 对比 FastAPI 生成的 OpenAPI 与本文件；
4. 将 `x-contract-status` 或相应端点状态更新为可用。
