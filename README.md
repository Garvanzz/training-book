# Training Book

个人训练计划、动作库与训练记录系统。

当前仓库正在实现 v1 离线优先 MVP：

- `apps/client_flutter`：iOS + Windows Flutter 客户端。
- `backend`：中国大陆部署的 FastAPI 服务、PostgreSQL 迁移和 OpenAPI 契约。
- `content`：动作库结构定义、种子内容与审核清单。
- `docs`：产品实现规格与架构决策记录。

产品与技术边界见 [实现规格](docs/fitness-app-implementation-spec.zh-CN.md)。

## 当前状态

离线优先 MVP 主流程可用:不登录也能建计划/训练/记录(数据仅本机),登录后本地数据自动并入账号并上传同步(计划/训练会话/组记录);动作库公开只读、支持标签筛选;训练完成展示总结页(开始/结束时间、时长、组明细、下次重量建议);冲突同步记录可查看/重试/丢弃;计划可删除;动作可下架;种子动作 10 个,`import_exercises` 一键导入。

不要把 `.env`、媒体原片、用户 SQLite 数据库或任何云密钥提交到仓库。
