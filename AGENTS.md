# GPT–DeepSeek 受控编排器

## 边界

本项目是通用的本地任务编排工具，不包含任何业务项目、DCC API 或远程执行服务。

- `ProjectRoot` 是 DeepSeek 可读取和受限修改的目标项目。
- `ControlRoot` 属于本工具，保存任务、里程碑、锁、报告和运行证据。
- 不读取或处理凭据、`.env` 或用户数据。
- 不运行 `git reset`、`git clean`、`git commit` 或 `git push`。
- 一次只能运行一个修改型 DeepSeek 任务；不做自动重试和自动再委派。

## 审查

接受任务前必须检查 `RESULT.json`、`REPORT.md`、测试记录、范围校验和目标项目 Git diff。交互式宿主应用验证不能由本工具或单元测试替代。
