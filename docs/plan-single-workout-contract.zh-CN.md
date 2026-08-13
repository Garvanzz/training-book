# 单次训练计划契约与验收清单

> 生效日期：2026-08-05  
> 决策：不兼容旧计划数据；开发和测试数据库可以直接迁移到新结构。

## 1. 领域契约

一个 `Plan` 是一次完整训练模板，例如“下肢力量 A”或“肩部恢复”。它不是周期、周计划或多个训练日的容器。

```text
Plan
└── PlanVersion
    └── StageBlock [0..n]，按 sort_order 排序
        └── ExerciseSlot [1..n]，按 sort_order 排序
            └── Prescription（每个动作独立）

PlanVersion --开始训练--> WorkoutSession（不可变快照）
```

术语边界：

- `训练计划`：用户保存、编辑和直接开始的单次训练模板。
- `阶段`：训练计划内的有序模块，例如活动度、激活、主项力量、辅助、有氧、冷身。
- `训练会话`：一次实际执行记录；不是计划中的“训练日”。
- `周期`、`日历安排`、`训练日`：不属于本次 V1 计划模型；未来若实现，必须作为引用多个 `Plan` 的独立排程领域。

## 2. 数据与 API 契约

新结构直接生效，不保留 `session_templates`、`training_weeks`、`weekday`、`estimated_duration_seconds` 或 `source_session_template_id` 的业务语义。

| 范围 | 必须提供 | 必须移除 |
|---|---|---|
| 创建/替换计划请求 | `name`、可选 `goal`、`blocks` | `sessions[]`、训练日名称、weekday |
| 计划详情 | `blocks[]`，每个 block 直接含 `slots[]` | `session_count`、`sessions[]` |
| 计划摘要 | `block_count` 或直接省略数量 | “X 个训练日” |
| 数据库 | `stage_blocks.plan_version_id` | `session_templates` 及其外键 |
| 开始训练 | `POST /v1/plans/{plan_id}/workouts`，服务端解析当前已发布版本 | `/v1/workouts/from-template/{template_id}` |
| 训练会话响应/快照 | `source_plan_version_id`、`plan_name`、`blocks` 的执行顺序 | `source_session_template_id`、`weekday`、`session_name` |

开始训练的前置条件：计划当前版本必须已发布，且至少有一个动作槽位。失败时返回可读的业务错误，不能要求客户端猜测内部模板 ID。

每个 `ExerciseSlot` 都有独立 `Prescription`；不存在计划或阶段级“默认处方”。阶段可以有可选的 `config`（如提示文本、预估时长），但不得覆盖动作处方。

## 3. 必须保持的训练流语义

1. 用户打开一个计划，直接看到其阶段及动作，不需要先选训练日。
2. 从计划详情“开始训练”，快照计划版本、阶段顺序、动作版本与每个动作处方。
3. 执行页可按阶段展示动作，但组记录仍按 `WorkoutItem` 归属，不能因为阶段切换丢失或重排日志。
4. 历史列表的标题取自 `plan_name` 快照；历史不依赖当前计划、阶段或动作是否还存在。
5. 对已发布计划编辑时创建新版本；已有训练会话仍指向原 `source_plan_version_id`。

## 4. 集成验收清单

### 计划接口

- [ ] 创建请求接受一个 `blocks[]` 根数组，拒绝 `sessions[]`、`weekday` 等旧字段（`extra=forbid`）。
- [ ] 创建、读取、克隆、替换和发布计划后，返回中都不出现训练日或模板字段。
- [ ] 空计划草稿可保存；发布时仅要求至少一个动作槽位。
- [ ] 两个阶段各含一个动作时，读取顺序严格按 `StageBlock.sort_order`、`ExerciseSlot.sort_order`。
- [ ] 同一阶段内两个动作可使用不同组数、次数、重量、RPE 和休息，互不覆盖。

### 训练接口与快照

- [ ] `POST /v1/plans/{plan_id}/workouts` 只能从当前已发布版本创建会话。
- [ ] 未发布、没有动作或不存在的计划分别返回确定且可读的 409/422/404 业务错误。
- [ ] 创建会话后，响应与数据库都不含模板 ID、weekday 或训练日名称。
- [ ] 会话动作顺序与计划阶段/动作排序一致；每个动作的处方快照与开始时版本一致。
- [ ] 计划随后修订或删除动作后，已开始/已完成会话仍能在历史中显示计划名、动作名与实际组记录。

### 客户端与离线

- [ ] 计划编辑器只显示计划名称与阶段；没有“添加训练日”、weekday 或训练日默认字段。
- [ ] 计划列表和详情文案不再出现“个训练日”。
- [ ] 开始训练入口只接收 `plan_id`，离线队列/SQLite 实体不保存 `session_template_id`。
- [ ] 旧本地计划缓存按“不兼容数据”策略清空或重建，并清楚提示开发/测试环境需要重新创建计划；不能半迁移后崩溃。

## 5. 集成时必须处理的遗留点

截至本契约写入时，以下旧语义仍存在于代码，重构必须一并移除：

- 后端 schema 的 `PlanSessionTemplateInput`、`sessions`、`session_count`、`PlanSessionTemplateResponse` 与 `source_session_template_id`。
- 后端计划 SQL 的 `session_templates` 表及 `stage_blocks.session_template_id`。
- 后端训练启动路由 `/v1/workouts/from-template/{template_id}`、会话快照内的 `weekday`。
- Flutter repository 的 `startWorkout(templateId)`、计划 UI 的 `sessions`/`weekday` 组装，以及“X 个训练日”文案。
- SQLite 本地计划与同步载荷中的任何 `session_template_id`、`weekday`、`sessions` 键。

实现完成后，使用下列检查确保旧公开契约未残留：

```powershell
rg -n "from-template|source_session_template_id|session_template_id|session_count|weekday|PlanSessionTemplate|sessions" backend\app apps\client_flutter\lib
```

该命令在迁移完成后可以在历史迁移文件中命中，但不应在运行时代码、客户端 DTO、公开 API schema 或 UI 文案中命中。
