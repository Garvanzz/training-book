# 数据库迁移

迁移使用 Alembic，首个版本执行 `001_initial_schema.sql`。生产环境只允许向前迁移；不得以自动 downgrade 删除个人训练数据。

本地示例：

```powershell
Copy-Item .env.example .env
# 填入仅用于本地开发的 DATABASE_URL 和 JWT_PRIVATE_KEY
$env:DATABASE_URL = 'postgresql+asyncpg://training_book:change-me@localhost:5432/training_book'
..\.venv\Scripts\alembic.exe -c alembic.ini upgrade head
```

应用请求事务必须在访问任何用户表前执行：

```sql
SELECT set_config('app.user_id', '<authenticated-user-uuid>', true);
```

数据库只接受来自 API 服务的私网连接；客户端永远不持有 PostgreSQL 凭证。
