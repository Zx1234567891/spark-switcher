# 在两台新 DGX Spark 上部署三个模型

在主 Spark 克隆 [Spark Switcher](https://github.com/Zx1234567891/spark-switcher)。两个 TensorFold 方案与一个 vLLM 方案共用部署入口和控制器。部署脚本获取固定版本的上游代码，并让两台 Spark 各自保留完整的权重和镜像。运行时两台各启动一个计算 rank。

## 准备环境

- 两台 Spark 各预留至少 **1 TB 可用空间**。三套权重合计约 **725 GB/台**，DeepSeek 首次启动另写入约 **99 GiB/台** 的 rank 缓存。离线打包镜像时另留归档空间。
- 两台使用 Linux ARM64，安装 NVIDIA 驱动、Docker Engine、NVIDIA Container Toolkit、Python 3.9+、OpenSSH 和 rsync。主 Spark 还需 Git、curl 和 `flock`。主 Spark 下载模型时需要 `hf` 命令，可在独立的 Python 虚拟环境安装 `huggingface_hub`，然后从该环境运行准备脚本。
- 两台 Spark 使用 ConnectX-7 有线互连，并为各自的 RoCE 网口配置静态 IP。主 Spark 用户需能用 SSH 公钥免密登录从 Spark，提前核实从 Spark 的主机公钥并加入 `known_hosts`。两端的运行账号都要能执行 Docker。 [NVIDIA ConnectX-7 互连指南](https://docs.nvidia.com/dgx/dgx-spark/spark-clustering.html)

## 镜像清单

选择 **Linux ARM64**。表中的镜像大小以现机 Docker 显示的未压缩大小为参考。

| 模型 | 获取方式 | 两台的最终镜像标签 | 大小 |
| --- | --- | --- | ---: |
| GLM-5.3 Flash | 从 GHCR 拉取固定摘要，准备脚本自动打本地标签 | `tensorfold-glm53:v0.6.0` | 24.6 GB |
| DeepSeek V4.1 Flash 1017 | 从 NGC 获取基础镜像 `nvcr.io/nvidia/pytorch:26.07-py3`，按固定配方构建 TensorFold `8e0966e`，也可导入已准备好的 ARM64 镜像 | `tensorfold-dsv41:8e0966e` | 24.6 GB |
| Qwen3.8 Flash Next | 从 Docker Hub 拉取 vLLM 0.30.0 的固定 ARM64 摘要，准备脚本自动打本地标签 | `vllm/vllm-openai:v0.30.0` | 22.1 GB |

如需提前在 ARM64 机器上手动拉取，在联网环境执行以下命令。运行 `prepare.sh` 时也会按需完成这些步骤。

```bash
glm_ref=ghcr.io/miaai-lab/glm-5.3-flash-exl3-2x-dgx-sparks-tensorfold@sha256:99fe7496d7002fd8f2ca3b1beb0aa07513835cd09989ca657b65875d60f69956
docker pull --platform linux/arm64 "$glm_ref"
docker tag "$glm_ref" tensorfold-glm53:v0.6.0

qwen_ref=docker.io/vllm/vllm-openai@sha256:4864d46625cbc3307623e29ac742030655e27249feba7b97ec925ce4cc4dfb56
docker pull --platform linux/arm64 "$qwen_ref"
docker tag "$qwen_ref" vllm/vllm-openai:v0.30.0

docker pull --platform linux/arm64 nvcr.io/nvidia/pytorch:26.07-py3
```

DeepSeek 的最后一条只准备构建基础镜像。完整镜像由 `bash deploy/prepare.sh deepseek` 构建，或通过 `docker load` 导入。脚本会核对两台的最终镜像 ID，与从注册表拉取时使用的镜像摘要分别记录。DeepSeek 重新构建后，部署脚本会把两台共同使用的新镜像 ID 写入 `server.json`。 [GLM 镜像定义](https://github.com/MiaAI-Lab/GLM-5.3-Flash-EXL3-2x-DGX-Sparks-TensorFold/blob/bf5f94523a8251029cedae86bf61f8ce37fac218/scripts/config.sh) · [DeepSeek Dockerfile](https://github.com/lucataco/DeepSeek-V4.1-Flash-2x-DGX-Spark/blob/7b46f9d9d8b21357f8998ccce8bdfa857a9ef1ce/docker/Dockerfile) · [vLLM 镜像](https://hub.docker.com/r/vllm/vllm-openai/tags?name=v0.30.0)

## 上游代码和模型文件

| 模型 | 固定版部署代码 | 两台均需准备的文件 |
| --- | --- | --- |
| GLM | [TensorFold 双机方案 `bf5f945`](https://github.com/MiaAI-Lab/GLM-5.3-Flash-EXL3-2x-DGX-Sparks-TensorFold/tree/bf5f94523a8251029cedae86bf61f8ce37fac218) | [EXL3 4-bit 主模型 `078455ff`](https://huggingface.co/Mia-AiLab/GLM-5.3-Flash-EXL3-4bpw-TensorFold/tree/078455ffe6472f9a52fbc1139f58b9db2881b25c) 完整快照，约 175.7 GB。另需 [DFlash2 草稿模型 `bf582e4`](https://huggingface.co/incoai/GLM-5.3-Flash-DFlash2/tree/bf582e4eacc1810f76656d1811693ff6c6737d2a)，约 2.34 GB。 |
| DeepSeek | [lucataco TensorFold TP2 方案 `7b46f9d`](https://github.com/lucataco/DeepSeek-V4.1-Flash-2x-DGX-Spark/tree/7b46f9d9d8b21357f8998ccce8bdfa857a9ef1ce) | [EXL3 2.9-bit `afc7aa0a`](https://huggingface.co/LibertAIDAI/DeepSeek-V4.1-Flash-1017-EXL3-2.9bpw/tree/afc7aa0aab98ee735c0f54e0a122019af1ac08f1)，43 个分片，约 211 GB。[1017 官方快照 `1bae0e10`](https://huggingface.co/deepseek-ai/DeepSeek-V4.1-Flash-1017/tree/1bae0e1088993b9b82de08f59de5be5a34e42170) 只取第 47、48 个 Engram 分片及配置和索引，约 203 GB。再安装视觉工具调用所需的补丁版聊天模板。 |
| Qwen | [vLLM 双机方案 `cd839d0`](https://github.com/MiaAI-Lab/Qwen3.8-Flash-Next-Dual-DGX-Sparks/tree/cd839d0b62f6c737178a0c2037733420e0524ebf) | [NVIDIA NVFP4 `fc694b54`](https://huggingface.co/nvidia/Qwen3.8-Flash-Next-NVFP4/tree/fc694b54fb0174e0913e6adf86691ef85a4ead47) 完整快照，约 132.7 GB，含十个主权重分片和 `model-fp8-mtp-ple.safetensors`。草稿词表 `files/draft_vocab_zh_en_code_65k.txt` 随上游代码获取。 |

GLM 和 Qwen 使用 Hugging Face Hub 缓存布局。若已有验证过的快照，移入对应的 `models--组织--模型` 目录，保留其中的 `blobs`、`snapshots`、`refs` 和软链接。DeepSeek 使用 `server.json` 中定义的两个独立目录，分别放 EXL3 和 Engram。

### 可选的 Qwen 魔搭下载

可在主 Spark 使用魔搭 CLI 下载固定版本，再导入 NVIDIA 格式的缓存。导入脚本按 NVIDIA 固定版清单核对文件大小和散列值，并补齐发布者的 `.gitattributes`。下载目录和 Hub 缓存分开存储时，请为两份文件预留空间。 [魔搭镜像](https://modelscope.cn/models/nv-community/Qwen3.8-Flash-Next-NVFP4) · [魔搭 CLI 文档](https://github.com/modelscope/modelscope/blob/master/docs/source/command.md#download) · [NVIDIA 文件版本](https://huggingface.co/nvidia/Qwen3.8-Flash-Next-NVFP4/tree/fc694b54fb0174e0913e6adf86691ef85a4ead47)

```bash
modelscope download --model nv-community/Qwen3.8-Flash-Next-NVFP4 \
  --revision bb325e902fbb183287fcf009deba45d59abeb079 \
  --local_dir "$HOME/models/qwen-modelscope"
python3 deploy/import-qwen-modelscope.py "$HOME/models/qwen-modelscope"
```

导入成功后，`prepare.sh qwen` 或 `prepare.sh all` 会复用该缓存。使用自定义缓存时，以 `--hub-root` 指定和 `server.json` 中 Qwen 配置一致的 `hub` 父目录。

## 配置和准备

在主 Spark 用日常运行模型的 Linux 账号操作。编辑 `server.json` 的 `head`、`worker` 和 `fabric`，根据两台的 `hostname -s`、`ip -br -4 addr`、`rdma link show` 填写主机名、SSH 目标、RoCE 地址、网口名及设备名。示例 IP 仅用于演示。MTU、GID 索引和 `kho=off` 检查按实际链路与内核配置填写。可以保留示例的模型目录及版本。路径中的 `~/` 分别指向各节点运行账号的家目录。

```bash
mkdir -p ~/.config/spark-switcher
cp -n server/server.example.json ~/.config/spark-switcher/server.json
# Edit ~/.config/spark-switcher/server.json.
bash deploy/prepare.sh check
bash deploy/prepare.sh all
```

下载由主 Spark 发起。脚本经 SSH 同步模型文件和 ARM64 镜像，验证两端资产并安装控制器。也可把 `all` 换成 `glm`、`deepseek` 或 `qwen` 逐个准备。启动配置由部署脚本生成，建议给新部署使用独立的上游代码目录。

已有这套模型时可用 `rsync` 转移权重，用 `docker save` 和 `docker load` 转移最终镜像。卷、容器记录和 SSH 凭据各自在新机器上配置。要完全断网准备，还需提前在对应路径放好固定版上游代码，以及补丁后的 DeepSeek 模板和最终镜像。

## 启动和验收

在主 Spark 每次切换一个模型。切换命令返回任务状态，可用 `status` 查看进度，用 `logs` 查看任务日志。

```bash
controller="$HOME/.local/lib/spark-switcher/sparkctl.py"
python3 "$controller" switch glm
python3 "$controller" status
python3 "$controller" logs
```

状态显示模型就绪后，用对应 API 端口测试 `/v1/models` 和聊天，再依次切换到另外两个模型。主 Spark 将三个 API 绑定到本机回环地址。

| 模型 | API ID | 主 Spark 本机端口 |
| --- | --- | ---: |
| GLM | `GLM-5.3-Flash-EXL3` | 8888 |
| DeepSeek | `deepseek-v4.1-flash` | 18888 |
| Qwen | `qwen3.8-flash-next` | 18300 |

配置 Windows 后，可以从 Spark Switcher 选择模型并打开客户端。验收离线场景时，先准备好模型和程序，然后拔掉外网、重启三台设备，依次验证模型切换与本地 API。 [Windows 连接说明](../README.md#配置-windows-直连)
