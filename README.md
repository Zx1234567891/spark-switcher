# Spark Switcher

Windows 上的双 NVIDIA DGX Spark 模型切换器。可启动、停止和切换 GLM-5.3 Flash、DeepSeek V4.1 Flash、Qwen3.8 Flash Next，也可用当前模型打开 ZCode、DeepSeek Harness 桌面版或 OpenCode。提前安装客户端并准备好两台 Spark 上的模型与容器后，三台设备重启后可在无互联网的情况下通过网线使用。

```text
Windows ── RJ45 直连 ── 主 Spark ── ConnectX-7 / RoCE ── 从 Spark
```

Windows 通过 SSH 把三组模型 API 转发到本机回环地址。主 Spark 管理两个计算节点，同一时间运行一组模型。切换时检查两个节点的模型文件与容器，测试新模型的 API。加载失败时尝试恢复此前模型。

## 准备两台 Spark

1. Windows 与主 Spark 的 RJ45 接口设为同一静态子网，主、从 Spark 的 RoCE 接口使用单独的静态子网。直连网络可以不配置默认网关。两台 Spark 都需要 Python 3.9 或更新版本、Docker 和 NVIDIA Container Toolkit。主 Spark 的控制器账号需要本机和从 Spark 的 Docker 操作权限，以及到从 Spark 的非交互公钥 SSH。提前从可信来源核对并记录从 Spark 的 SSH 主机公钥。
2. 在有网时准备两个节点的容器、模型权重和启动脚本。模型快照可以从官方模型源或对应的魔搭镜像获取，按控制器配置核对版本和文件完整性。将本地镜像、权重及缓存保留在两台机器上。

   | 模型 | 双机部署参考 | API ID | 端口 |
   | --- | --- | --- | ---: |
   | GLM | [GLM-5.3 Flash EXL3 / TensorFold](https://github.com/MiaAI-Lab/GLM-5.3-Flash-EXL3-2x-DGX-Sparks-TensorFold) | `GLM-5.3-Flash-EXL3` | 8888 |
   | DeepSeek | [DeepSeek V4.1 Flash 1017 EXL3 / TensorFold](https://github.com/MiaAI-Lab/DeepSeek-v4.1-Flash-1017-2x-DGX-Sparks) | `deepseek-v4.1-flash` | 18888 |
   | Qwen | [Qwen3.8 Flash Next / vLLM](https://github.com/MiaAI-Lab/Qwen3.8-Flash-Next-Dual-DGX-Sparks) | `qwen3.8-flash-next` | 18300 |

   将上游 GLM、Qwen 启动器各自配置为匹配两台机器的 SSH、RoCE 和本地模型路径。控制器调用 GLM 的 `start.sh` 和 `stop.sh`，以及 Qwen 的 `start-v030.sh --launch`。保留表中的 API ID 和端口，主 Spark 的 API 监听回环地址。DeepSeek 由控制器直接启动两份 TensorFold 容器。两个节点的模型目录应匹配配置，镜像 ID 应一致。

   Qwen 在上游 `.env` 设置 `PORT=18300`，并在 `start.sh` 的主节点 API 启动参数里将 `--host 0.0.0.0` 改为 `--host 127.0.0.1`。中英代码均衡的草稿词表可设为 `MTP_DRAFT_VOCAB=files/draft_vocab_zh_en_code_65k.txt`。
3. 在主 Spark 上，以运行控制器的账户创建配置，按 [server.example.json](server/server.example.json) 填写主机名、RoCE 地址、接口、GID、模型路径和本地镜像 ID。配置里的 IP 是文档示例。以 `docker image inspect --format '{{.Id}}' <image>` 查询本地镜像 ID。

   ```bash
   mkdir -p ~/.config/spark-switcher
   cp -n server/server.example.json ~/.config/spark-switcher/server.json
   # Fill in server.json before installation.
   bash server/install.sh
   python3 ~/.local/lib/spark-switcher/sparkctl.py status
   python3 ~/.local/lib/spark-switcher/sparkctl.py preflight glm
   python3 ~/.local/lib/spark-switcher/sparkctl.py preflight deepseek
   python3 ~/.local/lib/spark-switcher/sparkctl.py preflight qwen
   ```

## 配置 Windows 直连

1. 启用 Windows 的 OpenSSH 客户端。复制 [connection.example.json](connection.example.json) 为同目录的 `connection.json`，填入 Windows 和主 Spark 的实际 RJ45 IP 以及主 Spark 用户名。
2. 用 `ssh-keygen -t ed25519` 为切换器单独生成密钥，保存到 `%LOCALAPPDATA%\SparkSwitcher\ssh\id_ed25519`。非交互启动需要能在当前 Windows 用户下使用该密钥。通过主 Spark 本机或可信渠道取 `/etc/ssh/ssh_host_ed25519_key.pub`，把它的类型和公钥字段写到同目录的 `spark_known_hosts`，行首加上与 `headAddress` 一致的 IP 和一个空格。
3. 在主 Spark 用户的 `~/.ssh/authorized_keys` 加一行 Windows 公钥。把下面的地址、命令路径和公钥占位替换成真实值。SSH 服务为此账号启用本地 TCP 转发，可用 `AllowTcpForwarding local` 限制转发方向。

   ```text
   from="WINDOWS_IPV4",restrict,port-forwarding,permitopen="127.0.0.1:8888",permitopen="127.0.0.1:18888",permitopen="127.0.0.1:18300",command="/absolute/home/.local/lib/spark-switcher/ssh-command.sh" ssh-ed25519 PUBLIC_KEY
   ```

4. 按 [Windows 使用说明](USAGE.md) 安装所需客户端，双击 `Launch.cmd`。可从 Windows PowerShell 在仓库根目录运行状态检查，确认直连与密钥已就绪。

   ```powershell
   powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\SparkSwitcher.ps1 -Check
   ```

## 离线使用

打开切换器，选模型并等待就绪，再打开所需工具。保留切换器窗口以维持 API 转发。要腾出两台 Spark 的内存，在窗口内点「停止模型」。[离线演示](demo/README.md) 提供读写文件、编程和识图的样例。

仓库包含切换器、Spark 控制器、客户端适配脚本和演示文件。客户端安装包、模型权重和容器镜像需提前单独准备。品牌标志归相应权利人所有，来源见 [图标来源](assets/sources.md)。

## 本地检查

```bash
python3 -m unittest discover -s server -v
```

在 Windows 上可从仓库根目录生成界面预览。

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\SparkSwitcher.ps1 -PreviewPath "$env:TEMP\spark-switcher.png"
```
