# 动作库内容包

动作库内容不是自由格式文档。每个待发布动作版本必须符合 `schemas/exercise-version.schema.json`，并经过产品负责人审核。

建议导入结构：

```text
content/
  exercises/
    goblet-squat.v1.json
  media/
    goblet-squat/
      source.mp4
```

媒体先上传到草稿存储区，后台计算 SHA-256、转码、生成封面及关键帧。JSON 中只保存最终对象键和版权声明，禁止把第三方播放器链接当作唯一教学媒介。
