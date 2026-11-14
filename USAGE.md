# Windows 使用指南

## 准备客户端

在 Windows x64 上准备 Windows PowerShell 5.1 和 OpenSSH 客户端，按 [项目说明](README.md) 配好有线网络、Spark 控制器和 SSH。仓库提供切换器源码，客户端从各自的官方渠道下载。下表列出适配的版本和切换器查找的位置。

| 客户端 | Windows 版本 | 安装位置 |
| --- | --- | --- |
| [ZCode](https://zcode.z.ai/cn/docs/install) | 3.18.2 x64 | 按官方方式安装。切换器查找 `%LOCALAPPDATA%\Programs\ZCode\ZCode.exe`、`%ProgramFiles%\ZCode\ZCode.exe` 或仓库下的 `tools\zcode\ZCode.exe`。保留安装目录中的 `resources`。 |
| [DeepSeek Harness 桌面版](https://download.deepseek.com/dsh-desk/bin/win-x64/deepseek-harness-0.2.2-rc.3-win-x64.exe) | 0.2.2-rc.3 x64 | 安装到当前 Windows 用户。切换器可从安装登记读取 `DeepSeek Harness.exe`，也查找 `%LOCALAPPDATA%\Programs\DeepSeek Harness\` 和仓库下的 `tools\harness-desktop\`。 |
| [OpenCode](https://github.com/anomalyco/opencode/releases/tag/v1.19.5) | 1.19.5 Windows x64 baseline | 从 [官方 npm 压缩包](https://registry.npmjs.org/opencode-windows-x64-baseline/-/opencode-windows-x64-baseline-1.19.5.tgz) 提取 `package/bin/opencode.exe`，放到仓库的 `tools\opencode\opencode.exe`。 |

完成首次安装并准备好两台 Spark 上的模型及运行环境后，通过网线即可切换模型、打开客户端和使用本地推理，模型推理无需云账号。在线搜索、在线插件和第三方服务仍需要相应的网络连接。

## 启动与切换

1. 接好 Windows 到 Spark 的直连网线及两台 Spark 之间的高速线，双击仓库里的 [Launch.cmd](Launch.cmd)。
2. 选择 GLM、DeepSeek 或 Qwen，点击 **启动模型** 或 **切换模型**。同一时间运行一个模型。切换期间可查看加载阶段和耗时。
3. 界面显示模型正在运行后，点击 **打开 ZCode**、**打开 DeepSeek Harness** 或 **打开 OpenCode**。在切换器中可以为 ZCode 和 OpenCode 预选项目文件夹。DeepSeek Harness 可在客户端内选择或添加工作区。
4. 切换模型后从切换器重新打开客户端，以便进入对应模型的配置。保持切换器打开以维持本地端口转发。需要释放两台 Spark 的模型内存时，点击 **停止模型**。

客户端的 Spark 配置按工具和模型保存在 `%LOCALAPPDATA%\SparkModelSwitcher\profiles\`。没有预选项目时，ZCode 和 OpenCode 可使用该模型的独立工作目录。

## 模型配置

| 模型 | 模型 ID | Windows 本地 API | 上下文（tokens） | 单次输出配置（tokens） | 推理等级 |
| --- | --- | --- | ---: | ---: | --- |
| GLM-5.3 Flash | `GLM-5.3-Flash-EXL3` | `http://127.0.0.1:8888/v1` | 1,048,576 | 131,072 | 关 / 低 / 高 / 最大 |
| DeepSeek V4.1 Flash | `deepseek-v4.1-flash` | `http://127.0.0.1:18888/v1` | 1,048,576 | 393,216 | 关 / 低 / 中 / 高 / 最大 |
| Qwen3.8 Flash Next | `qwen3.8-flash-next` | `http://127.0.0.1:18300/v1` | 262,144 | 131,072 | 关 / 低 / 中 / 超高 |

输出额度包含思考和正文。实际输出受服务端限制和当轮剩余上下文影响，历史消息、文件及工具说明均占用上下文。项目的对应参数保存在 [models.json](models.json)，应与 Spark 服务配置保持一致。

DeepSeek Harness 在输入框旁的模型菜单里选择 **推理等级**，ZCode 使用输入框旁的思考菜单，OpenCode 按 `Ctrl+T` 切换档位。关闭档位在界面中可能显示为 `Off` 或 `disabled`，所选档位在之后发送的请求中生效。

## 验证

模型就绪后，在客户端发一条简单消息，例如“只回复 SPARK_OK”，确认回答来自当前模型。读写文件、运行测试和识图的离线练习见 [demo](demo/README.md)。

排查连接时，可在仓库根目录查询控制器状态和正在运行的本地 API。以下示例使用 GLM 的端口，测试其他模型时按上表替换。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\SparkSwitcher.ps1 -Check
Invoke-RestMethod http://127.0.0.1:8888/v1/models
```

未连接时检查网线、静态 IP 和 SSH 配置。模型显示正在加载时等待就绪，再重新打开客户端。控制器的本地单元测试可从仓库根目录执行 `python -m unittest discover -s server -p "test_*.py"`。
