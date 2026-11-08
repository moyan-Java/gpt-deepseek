# GPT–DeepSeek 受控编排器

这是一个与业务项目解耦的本地 DeepSeek Harness：GPT 负责定义并审查有限任务，DeepSeek 只在指定目标项目中执行该任务。

它不包含宿主应用 API、宿主项目路径或任何业务源码。任务、报告、运行日志和锁全部写入外部控制目录；目标项目只作为 DeepSeek 的工作目录和范围校验对象。

## 使用方式

先准备一个控制目录，例如：

```powershell
$tool = 'D:\YSW\Projects\20231020_\agent\gpt-deepseek'
$target = 'D:\path\to\target-project'
$control = Join-Path $tool 'workspaces\target-project'
New-Item -ItemType Directory -Force -Path $control
Copy-Item "$tool\templates\MILESTONE.md" "$control\MILESTONE.md"
```

由 GPT 明确任务后创建任务文件：

```powershell
& "$tool\dev_tool\agent\New-DeepSeekTask.ps1" `
  -ProjectRoot $target -ControlRoot $control `
  -Title '任务标题' -Goal '明确目标' `
  -Scope 'src/' -AcceptanceCriteria '测试通过' `
  -TestCommand 'pytest'
```

执行一项任务并打开中文监视窗口：

```powershell
& "$tool\dev_tool\agent\Invoke-DeepSeekTask.ps1" `
  -ProjectRoot $target -ControlRoot $control -RunTests -OpenMonitor
```

结果写入 `$control\runs\<run-id>\RESULT.json`。只有审查通过且里程碑预先定义下一任务时，才可创建下一任务；失败、越界、测试失败或需要交互式宿主验证时必须停止。

## 验证

```powershell
.\dev_tool\test\test-deepseek-tool.ps1
```
