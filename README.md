# Spark Switcher

Windows 上的双 NVIDIA DGX Spark 模型切换器。可启动、停止和切换 GLM-5.3 Flash、DeepSeek V4.1 Flash、Qwen3.8 Flash Next，也可用当前模型打开 ZCode、DeepSeek Harness 桌面版或 OpenCode。提前安装客户端并准备好两台 Spark 上的模型与容器后，三台设备重启后可在无互联网的情况下通过网线使用。

```text
Windows ── RJ45 直连 ── 主 Spark ── ConnectX-7 / RoCE ── 从 Spark
```

Windows 通过 SSH 把三组模型 API 转发到本机回环地址。主 Spark 管理两个计算节点，同一时间运行一组模型。切换时检查两个节点的模型文件与容器，测试新模型的 API。加载失败时尝试恢复此前模型。

## 准备两台 Spark

三套双机部署共用 [server.json 配置样例](server/server.example.json)。按部署指南配置 RoCE 和 SSH，并在主 Spark 导入 DeepSeek 预构建镜像，再运行下面的命令。 [部署指南](deploy/README.md) · [DeepSeek 免构建导入](deploy/README.md#deepseek-免构建导入)

```bash
mkdir -p ~/.config/spark-switcher
cp -n server/server.example.json ~/.config/spark-switcher/server.json
# Edit server.json using your hostnames, SSH target and RoCE interfaces.
bash deploy/prepare.sh check
bash deploy/prepare.sh all
```

`all` 使用仓库自带的三套完整固定版上游源码，为两台 Spark 准备权重、ARM64 镜像和启动配置，然后安装控制器。也可把 `all` 换成 `glm`、`deepseek` 或 `qwen` 逐个准备。部署后的启动和切换由 Windows 界面或主 Spark 上的 `sparkctl.py` 控制。 [镜像与模型下载清单](deploy/README.md#镜像清单) · [上游源码](vendor/SOURCES.md)

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

仓库包含双 Spark 部署脚本、切换器、Spark 控制器、客户端适配脚本和演示文件。运行部署脚本可以准备模型权重和容器镜像。Windows 客户端安装包按使用指南准备。品牌标志归相应权利人所有，来源见 [图标来源](assets/sources.md)。

## 本地检查

```bash
python3 -m unittest discover -s server -v
```

在 Windows 上可从仓库根目录生成界面预览。

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\SparkSwitcher.ps1 -PreviewPath "$env:TEMP\spark-switcher.png"
```
