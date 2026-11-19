# 在两台新 DGX Spark 上部署三个模型

本流程从两台空白 DGX Spark 和一台 Windows x64 笔记本开始。Spark Switcher 仓库内已包含三套完整的固定版本部署源码、DeepSeek 的 TensorFold 引擎和聊天模板。两台 Spark 各保留完整的权重和镜像，运行时各启动一个计算 rank，同一时间运行一个模型。 [源码和许可证清单](../vendor/SOURCES.md)

## 1. 准备设备和基础软件

两台 Spark 各预留至少 **1 TB 可用空间**。三套权重合计约 **725 GB/台**，DeepSeek 首次启动另写入约 **99 GiB/台** 的 rank 缓存。离线打包镜像时再留归档空间。部署按双机各 128 GB 统一内存的环境准备。

在两台 Spark 分别用日常运行模型的 Linux 账号检查 DGX OS、GPU 和 Docker。原厂 DGX OS 提供 NVIDIA GPU 容器运行时。如以下命令报缺组件，按发行版和 NVIDIA 指南补齐。 [DGX Spark Docker 运行时](https://docs.nvidia.com/dgx/dgx-spark/nvidia-container-runtime-for-docker.html) · [NVIDIA Container Toolkit 安装指南](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html)

```bash
uname -m                         # aarch64
uname -r
nvidia-smi
docker info
df -h "$HOME" /var/lib/docker
```

两台 Spark 都需要 Python 3.9+、OpenSSH、rsync、iproute2 和 curl。联网时可安装缺少的 Ubuntu 包，然后启用 SSH 和 Docker 随系统启动。用 Git 获取本仓库时在主 Spark 安装 Git。

```bash
sudo apt update
sudo apt install -y openssh-client openssh-server rsync iproute2 ethtool curl python3 python3-venv util-linux
sudo systemctl enable --now ssh docker
```

如果运行账号无权访问 Docker，执行 `sudo usermod -aG docker "$(id -un)"`，退出并重新登录，再运行 `docker info`。这也适用于从 Spark 的 SSH 账号。

## 2. 接线并配置持久化地址

```text
Windows 专用 RJ45 ── 普通网线 ── 主 Spark RJ45
                                主 Spark QSFP 0 ══ ConnectX-7 线 ══ 从 Spark QSFP 0
```

下面的三个网段是可替换的内网例子。所有直链接口的默认网关和 DNS 留空，部署下载期间可另用 Wi‑Fi 或独立管理网联网。使用与环境内其它网络不重叠的网段。

| 链路 | 一端 | 另一端 |
| --- | --- | --- |
| Windows ↔ 主 Spark RJ45 | Windows `10.73.0.2/30` | 主 Spark `10.73.0.1/30` |
| Spark 间 RoCE 第一条 rail | 主 Spark `10.73.1.1/24` | 从 Spark `10.73.1.2/24` |
| Spark 间 RoCE 第二条 rail | 主 Spark `10.73.2.1/24` | 从 Spark `10.73.2.2/24` |

在两台 Spark 上分别找出接线后的接口名、短主机名和 HCA 名。一个 ConnectX‑7 物理口可对应两条 rail。用 `rdma link show` 将 RDMA 设备和网口一一对应。下文用常见的 0 口接口名举例。 [NVIDIA 接线与手工 Netplan 配置](https://build.nvidia.com/playbooks/connect-multiple-sparks/manual) · [端口与接口对应表](https://docs.nvidia.com/dgx/dgx-spark/spark-clustering.html#full-correspondence-table)

```bash
hostname -s
ip -br link
ip -br -4 addr
rdma link show
sudo netplan get
```

用各机本地控制台编辑现有 Netplan 配置或补充独立的 `/etc/netplan/80-spark-switcher.yaml`。同一专用网口如果已有 NVIDIA Sync 配置，在原配置中完成调整。主 Spark 的双 rail 例子如下。将网口名换成实际值。

```yaml
network:
  version: 2
  ethernets:
    enp1s0f0np0:
      dhcp4: false
      dhcp6: false
      addresses: [10.73.1.1/24]
      mtu: 9000
      optional: true
    enP2p1s0f0np0:
      dhcp4: false
      dhcp6: false
      addresses: [10.73.2.1/24]
      mtu: 9000
      optional: true
```

从 Spark 的文件使用它自己的接口名，把两个地址的末位改为 `.2`。主 Spark 另在现有网络配置中给专用 RJ45 网口设置 `10.73.0.1/30`，保留该网口的普通以太网 MTU。RJ45 网口若由桌面 NetworkManager 管理，可在该有线连接的 IPv4 设置里保存手动地址。

使用 Netplan 时先临时应用并确认两端可达，再确认保存。主 Spark 测试以下目的地址，从 Spark 测试相应的 `.1` 地址。两个 RDMA 设备的连接状态应为 `ACTIVE`。

```bash
sudo chmod 600 /etc/netplan/80-spark-switcher.yaml  # 仅使用此文件时执行
sudo netplan try
ip -4 route get 10.73.1.2
ping -c 3 10.73.1.2
ping -c 3 10.73.2.2
rdma link show
```

读取每台机器已使用的 HCA 的 RoCE v2 GID 表。示例里的 `rocep1s0f0` 换为实际名称。选择映射到各自 rail IPv4 的 RoCE v2 条目。当前配置文件对所有所选设备使用同一个 `gid_index`，以两端检查结果为准。

```bash
hca=rocep1s0f0
port="/sys/class/infiniband/$hca/ports/1"
for f in "$port"/gid_attrs/types/*; do
    i=${f##*/}
    [ "$(cat "$f")" = 'RoCE v2' ] && printf '%s %s\n' "$i" "$(cat "$port/gids/$i")"
done
```

现有部署使用 `kho=off`。保留样例的 `require_kho_off: true` 时两端 `/proc/cmdline` 都需包含该项。若使用出现 RDMA 内存注册报错的 NVIDIA 7.0.0-1019 内核，按 NVIDIA 的说明设置后重启验证。改用已修复内核且通过 RDMA 实测时，可按实际情况更新这一项。 [NVIDIA 的已知问题与处理办法](https://forums.developer.nvidia.com/t/dgx-spark-regression-kernel-7-0-0-1019-nvidia-causes-nccl-roce-ibv-reg-mr-iova2-enomem-6-17-0-1032-works/383023/43)

## 3. 建立主 Spark 到从 Spark 的 SSH

在从 Spark 控制台读取主机公钥和指纹。把公钥通过可信方式抄到主 Spark，并以目标 IP 为第一列加入主 Spark 当前用户的 `~/.ssh/known_hosts`。

```bash
# 从 Spark
sudo ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
sudo cat /etc/ssh/ssh_host_ed25519_key.pub
```

在主 Spark 运行下面的命令。示例中的 Linux 用户 `spark` 换为从 Spark 上的实际用户。首次生成密钥时可选择空口令，以便重启后自动启动双机任务。

```bash
# 主 Spark
install -d -m 700 ~/.ssh
test -f ~/.ssh/id_ed25519 || ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519
read -r -p '粘贴从 Spark 的 ED25519 主机公钥: ' worker_host_key
printf '%s %s\n' 10.73.1.2 "$worker_host_key" >> ~/.ssh/known_hosts
chmod 600 ~/.ssh/known_hosts
ssh-copy-id -i ~/.ssh/id_ed25519.pub -o StrictHostKeyChecking=yes spark@10.73.1.2
ssh -o BatchMode=yes -o StrictHostKeyChecking=yes spark@10.73.1.2 hostname -s
ssh -o BatchMode=yes -o StrictHostKeyChecking=yes spark@10.73.1.2 docker info --format '{{.ServerVersion}}'
```

从 Spark 若只允许公钥登录，可在它的本地控制台将主 Spark 的 `~/.ssh/id_ed25519.pub` 加入对应 Linux 用户的 `~/.ssh/authorized_keys`，目录权限设为 `700`，文件权限设为 `600`，再运行上述两条 SSH 验证。

## 4. 获取仓库并填写双机配置

在主 Spark 获取 Spark Switcher 的完整仓库。离线可解包此前下载的 tar.gz 或传输完整目录，保留 `vendor/`。 [GitHub 源码归档](https://github.com/Zx1234567891/spark-switcher/archive/refs/heads/main.tar.gz)

```bash
git clone https://github.com/Zx1234567891/spark-switcher.git
cd spark-switcher
mkdir -p ~/.config/spark-switcher
cp -n server/server.example.json ~/.config/spark-switcher/server.json
nano ~/.config/spark-switcher/server.json
```

保留样例中的 `models` 目录和版本配置，将 `head`、`worker`、`fabric` 改成两台实际值。下面的字段按本流程的 IP 举例，主机名、网口和 HCA 名以现场结果为准。

```json
{
  "head": {
    "hostname": "spark-head",
    "roce_address": "10.73.1.1",
    "roce_interface": "enp1s0f0np0",
    "roce_devices": ["rocep1s0f0", "roceP2p1s0f0"]
  },
  "worker": {
    "hostname": "spark-worker",
    "ssh_target": "spark@10.73.1.2",
    "roce_address": "10.73.1.2",
    "roce_interface": "enp1s0f0np0",
    "roce_devices": ["rocep1s0f0", "roceP2p1s0f0"]
  },
  "fabric": {
    "mtu": 9000,
    "gid_index": 3,
    "require_kho_off": true
  }
}
```

```bash
bash deploy/prepare.sh check
```

检查通过后再开始下载。脚本会核对两台主机、ARM64、Docker 权限、RoCE 路由、MTU 和 GID。示例文件包含完整的权重、引擎和缓存路径，`~/` 分别解析为各节点运行账号的家目录。 [完整配置样例](../server/server.example.json)

## 5. 准备镜像和权重

### 镜像清单

选择 **Linux ARM64**。表中的镜像大小以现机 Docker 显示的未压缩大小为参考。

| 模型 | 获取方式 | 两台的最终镜像标签 | 大小 |
| --- | --- | --- | ---: |
| GLM-5.3 Flash | 从 GHCR 拉取固定摘要，准备脚本自动打本地标签 | `tensorfold-glm53:v0.6.0` | 24.6 GB |
| DeepSeek V4.1 Flash 1017 | 拉取 NVIDIA 官方固定基础镜像，导入从现有 Spark 导出的 DeepSeek 镜像增量包 | `tensorfold-dsv41:8e0966e` | 24.6 GB |
| Qwen3.8 Flash Next | 从 Docker Hub 拉取 vLLM 0.30.0 的固定 ARM64 摘要，准备脚本自动打本地标签 | `vllm/vllm-openai:v0.30.0` | 22.1 GB |

GLM 和 Qwen 会在运行 `prepare.sh` 时按需拉取。提前拉取这两个镜像时使用下列固定版本。

```bash
glm_ref=ghcr.io/miaai-lab/glm-5.3-flash-exl3-2x-dgx-sparks-tensorfold@sha256:99fe7496d7002fd8f2ca3b1beb0aa07513835cd09989ca657b65875d60f69956
docker pull --platform linux/arm64 "$glm_ref"
docker tag "$glm_ref" tensorfold-glm53:v0.6.0

qwen_ref=docker.io/vllm/vllm-openai@sha256:4864d46625cbc3307623e29ac742030655e27249feba7b97ec925ce4cc4dfb56
docker pull --platform linux/arm64 "$qwen_ref"
docker tag "$qwen_ref" vllm/vllm-openai:v0.30.0
```

### DeepSeek 免构建导入

在主 Spark 的仓库根目录执行。NVIDIA 基础层从 NGC 下载，传输量约 11.3 GB。Spark Switcher Release 提供从现有镜像导出的 TensorFold 运行层和原始镜像配置，增量包约 112 MB。导入脚本验证镜像内容，合并成完整的 Docker 归档流并调用 `docker load`。整个过程无需运行 `docker build` 或安装容器内的 Python 依赖。 [DeepSeek 镜像发布页](https://github.com/Zx1234567891/spark-switcher/releases/tag/deepseek-arm64-8e0966e) · [NVIDIA PyTorch 26.07](https://docs.nvidia.com/deeplearning/frameworks/pytorch-release-notes/rel-26-07.html)

```bash
base=nvcr.io/nvidia/pytorch@sha256:7531d90bcbe0e43e1f7363029c7e145ce90eebeb494a7b4695fdba0329d7c3c3
release=https://github.com/Zx1234567891/spark-switcher/releases/download/deepseek-arm64-8e0966e
bundle=deepseek-8e0966e-linux-arm64-delta.tar.gz

docker pull --platform linux/arm64 "$base"
curl -fL --retry 3 -o "$bundle" "$release/$bundle"
curl -fL --retry 3 -o "$bundle.sha256" "$release/$bundle.sha256"
sha256sum -c "$bundle.sha256"
python3 deploy/import-deepseek-image.py "$bundle"
docker image inspect --format '{{.Os}}/{{.Architecture}} {{.Id}}' tensorfold-dsv41:8e0966e
```

成功时最后一条返回 `linux/arm64 sha256:193ec8579b0c3dd5bf6b122f6fd4f0cc8cfd225273d86f537892203ddff91f6e`，与 [server.json 样例](../server/server.example.json) 的 DeepSeek 镜像 ID 一致。建议为导入额外保留约 55 GB 的临时磁盘空间，可用 `--temp-dir /path/to/disk` 指定归档暂存目录。之后运行 `prepare.sh all` 或 `prepare.sh deepseek`，脚本会将最终镜像同步给从 Spark。

如果手头已有 `docker save` 导出的完整最终镜像归档，则直接用 `docker load --input /path/to/deepseek.tar` 导入。需要自行定制镜像时，可以使用随库的 Dockerfile 构建。 [本地构建文件](deepseek.Dockerfile)

### 上游代码和模型文件

| 模型 | 固定版部署代码 | 两台均需准备的文件 |
| --- | --- | --- |
| GLM | [TensorFold 双机方案 `bf5f945`](../vendor/glm) | [EXL3 4-bit 主模型 `078455ff`](https://huggingface.co/Mia-AiLab/GLM-5.3-Flash-EXL3-4bpw-TensorFold/tree/078455ffe6472f9a52fbc1139f58b9db2881b25c) 完整快照，约 175.7 GB。另需 [DFlash2 草稿模型 `bf582e4`](https://huggingface.co/incoai/GLM-5.3-Flash-DFlash2/tree/bf582e4eacc1810f76656d1811693ff6c6737d2a)，约 2.34 GB。 |
| DeepSeek | [lucataco TensorFold TP2 方案 `7b46f9d`](../vendor/deepseek) · [TensorFold 源码 `8e0966e`](../vendor/tensorfold-deepseek) | [EXL3 2.9-bit `afc7aa0a`](https://huggingface.co/LibertAIDAI/DeepSeek-V4.1-Flash-1017-EXL3-2.9bpw/tree/afc7aa0aab98ee735c0f54e0a122019af1ac08f1)，43 个分片，约 211 GB。[1017 官方快照 `1bae0e10`](https://huggingface.co/deepseek-ai/DeepSeek-V4.1-Flash-1017/tree/1bae0e1088993b9b82de08f59de5be5a34e42170) 只取第 47、48 个 Engram 分片及配置和索引，约 203 GB。聊天模板由部署脚本从本仓库安装。 |
| Qwen | [vLLM 双机方案 `cd839d0`](../vendor/qwen) | [NVIDIA NVFP4 `fc694b54`](https://huggingface.co/nvidia/Qwen3.8-Flash-Next-NVFP4/tree/fc694b54fb0174e0913e6adf86691ef85a4ead47) 完整快照，约 132.7 GB，含十个主权重分片和 `model-fp8-mtp-ple.safetensors`。仓库内含 `files/draft_vocab_zh_en_code_65k.txt`。 |

GLM 和 Qwen 使用 Hugging Face Hub 缓存布局。若已有验证过的快照，移入对应的 `models--组织--模型` 目录，保留其中的 `blobs`、`snapshots`、`refs` 和软链接。DeepSeek 使用 `server.json` 中定义的两个独立目录，分别放 EXL3 和 Engram。

### 路线 A：主 Spark 联网下载

在主 Spark 的仓库根目录运行。先按上一节导入 DeepSeek 最终镜像。以下虚拟环境用于安装 `hf` 权重下载工具，Docker 容器内的模型运行环境由镜像提供。

```bash
python3 -m venv ~/.local/share/spark-switcher/download-env
source ~/.local/share/spark-switcher/download-env/bin/activate
python -m pip install -U huggingface_hub
hf --help
bash deploy/prepare.sh all
```

可以把 `all` 换成 `glm`、`deepseek` 或 `qwen` 分开准备。脚本按固定版本下载缺失镜像和权重，复制仓库内的启动代码，经 SSH 同步资产到从 Spark，执行检查并安装控制器。网络中断后可重跑同一条命令。对于下载速度较慢或无法从 Hugging Face 直接下载 Qwen 的环境，可以先用下面的魔搭方式。

### 可选的 Qwen 魔搭下载

可在主 Spark 使用魔搭 CLI 下载固定版本，再导入 NVIDIA 格式的缓存。导入脚本按 NVIDIA 固定版清单核对文件大小和散列值，并补齐发布者的 `.gitattributes`。下载目录和 Hub 缓存分开存储时，请为两份文件预留空间。 [魔搭镜像](https://modelscope.cn/models/nv-community/Qwen3.8-Flash-Next-NVFP4) · [魔搭 CLI 文档](https://github.com/modelscope/modelscope/blob/master/docs/source/command.md#download) · [NVIDIA 文件版本](https://huggingface.co/nvidia/Qwen3.8-Flash-Next-NVFP4/tree/fc694b54fb0174e0913e6adf86691ef85a4ead47)

```bash
python -m pip install -U modelscope
modelscope download --model nv-community/Qwen3.8-Flash-Next-NVFP4 \
  --revision bb325e902fbb183287fcf009deba45d59abeb079 \
  --local_dir "$HOME/models/qwen-modelscope"
python3 deploy/import-qwen-modelscope.py "$HOME/models/qwen-modelscope"
```

导入成功后，`prepare.sh qwen` 或 `prepare.sh all` 会复用该缓存。使用自定义缓存时，以 `--hub-root` 指定和 `server.json` 中 Qwen 配置一致的 `hub` 父目录。

### 路线 B：用已有资产离线部署

在已经准备好三个最终镜像的 Linux ARM64 机器上导出。下面用 `/mnt/transfer` 表示支持 Linux 软链接且容量足够的移动盘挂载点。若使用 exFAT 等文件系统，可先将 Hub 缓存打包成 tar 归档后转移。

```bash
docker save --output /mnt/transfer/spark-images.tar \
  tensorfold-glm53:v0.6.0 tensorfold-dsv41:8e0966e vllm/vllm-openai:v0.30.0

mkdir -p /mnt/transfer/hub /mnt/transfer/models
rsync -aH --info=progress2 \
  ~/.cache/huggingface/hub/models--Mia-AiLab--GLM-5.3-Flash-EXL3-4bpw-TensorFold \
  ~/.cache/huggingface/hub/models--incoai--GLM-5.3-Flash-DFlash2 \
  ~/.cache/huggingface/hub/models--nvidia--Qwen3.8-Flash-Next-NVFP4 /mnt/transfer/hub/
rsync -aH --info=progress2 \
  ~/models/DeepSeek-V4.1-Flash-1017-EXL3-2.9bpw \
  ~/models/DeepSeek-V4.1-Flash-1017-engram /mnt/transfer/models/
```

在新主 Spark 导入。以下路径对应样例配置，改过配置时把资产放到对应位置。安装脚本从新主 Spark 的仓库根目录运行，并经 SSH 准备从 Spark。

```bash
docker load --input /mnt/transfer/spark-images.tar
mkdir -p ~/.cache/huggingface/hub ~/models
rsync -aH --info=progress2 /mnt/transfer/hub/ ~/.cache/huggingface/hub/
rsync -aH --info=progress2 /mnt/transfer/models/ ~/models/

docker image inspect --format '{{.Architecture}} {{.Id}}' tensorfold-dsv41:8e0966e
# 若此前重新构建过 DeepSeek，把上面的镜像 ID 填入 models.deepseek.digest。
bash deploy/prepare.sh check
bash deploy/prepare.sh all
```

离线导入使用三个**最终镜像**。保留 Hub 的 `snapshots` 到 `blobs` 的相对软链接。DeepSeek 的缓存可以在首次启动时重新生成。部署脚本检查 GLM 和 Qwen 固定快照中的分片及配置，按内容摘要校验 DeepSeek 资产。 [配置文件和镜像 ID 样例](../server/server.example.json)

## 6. 在主 Spark 逐个验证三个模型

| 模型 | API ID | 主 Spark 本机端口 |
| --- | --- | ---: |
| GLM | `GLM-5.3-Flash-EXL3` | 8888 |
| DeepSeek | `deepseek-v4.1-flash` | 18888 |
| Qwen | `qwen3.8-flash-next` | 18300 |

先检查三个模型的离线资产，再启动 GLM。切换命令会创建后台任务，等 `status` 的 `active` 为 `glm` 且模型为 `ready` 后继续。DeepSeek 第一次启动会编译和写入缓存，Qwen 第一次加载权重也可能需要数分钟。

```bash
controller="$HOME/.local/lib/spark-switcher/sparkctl.py"
python3 "$controller" preflight glm
python3 "$controller" preflight deepseek
python3 "$controller" preflight qwen
python3 "$controller" switch glm
python3 "$controller" status
python3 "$controller" logs --lines 50
```

用当前模型的端口和 ID 执行一轮 API 测试。以下以 GLM 为例，预期模型列表包含对应 ID，聊天返回 `SPARK_OK`。然后执行 `switch deepseek` 和 `switch qwen`，每次等待就绪后用表中 ID 及端口重复测试。

```bash
port=8888
model=GLM-5.3-Flash-EXL3
curl --noproxy '*' -fsS "http://127.0.0.1:$port/v1/models"
curl --noproxy '*' -fsS "http://127.0.0.1:$port/v1/chat/completions" \
  -H 'Content-Type: application/json' -d @- <<JSON
{"model":"$model","messages":[{"role":"user","content":"Reply exactly SPARK_OK."}],"max_tokens":64,"stream":false,"chat_template_kwargs":{"enable_thinking":false}}
JSON
```

切换器在启动前检查两台的模型资源和旧服务状态。需要手工释放模型内存时执行 `python3 "$controller" stop`，再用 `status` 确认。普通使用可直接从 Windows 界面切换。

## 7. 接入 Windows 笔记本

把完整 Spark Switcher 目录复制到笔记本。先使用 **管理员 PowerShell** 启用 OpenSSH 客户端，然后为专用 RJ45 网口保存与主 Spark 同网段的静态 IP。以下命令适合尚未配置静态地址的专用网口。已有静态地址时可在该网口的 IPv4 属性内编辑，网关与 DNS 留空。 [安装 Windows OpenSSH](https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh_install_firstuse) · [New-NetIPAddress](https://learn.microsoft.com/en-us/powershell/module/nettcpip/new-netipaddress)

```powershell
Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0
Get-NetAdapter
$nic = 'Ethernet' # 按 Get-NetAdapter 输出填写专用网口名
New-NetIPAddress -InterfaceAlias $nic -IPAddress 10.73.0.2 -PrefixLength 30
Test-NetConnection 10.73.0.1 -Port 22
```

用之后打开切换器的普通 Windows 用户，在仓库目录生成专用密钥并填入连接地址。若密钥文件已存在，沿用原有密钥。首次生成时可使用空口令，或者在启动切换器前通过 SSH agent 解锁有口令的密钥。

```powershell
$sshDir = Join-Path $env:LOCALAPPDATA 'SparkSwitcher\ssh'
New-Item -ItemType Directory -Force -Path $sshDir | Out-Null
if (!(Test-Path "$sshDir\id_ed25519")) {
    ssh-keygen.exe -t ed25519 -f "$sshDir\id_ed25519" -C spark-switcher
}
Get-Content "$sshDir\id_ed25519.pub"
if (!(Test-Path .\connection.json)) {
    Copy-Item .\connection.example.json .\connection.json
}
notepad .\connection.json
```

`connection.json` 示例。用户名填主 Spark 上运行控制器的账号。

```json
{
  "sshUser": "spark",
  "headAddress": "10.73.0.1",
  "localAddress": "10.73.0.2"
}
```

从主 Spark 控制台获取可信的主机公钥 `/etc/ssh/ssh_host_ed25519_key.pub`，用 `ssh-keygen -lf` 核对指纹。在 Windows 下执行以下命令，将公钥与 `headAddress` 一起保存。

```powershell
$serverKey = Read-Host '粘贴已核对的主 Spark ED25519 主机公钥'
"10.73.0.1 $serverKey" | Set-Content -Encoding ASCII "$sshDir\spark_known_hosts"
```

在主 Spark 上给对应运行账号的 `~/.ssh/authorized_keys` 增加一行 Windows 公钥。将示例里的 Windows 直连 IP、受限命令绝对路径和公钥换成实际值。确保 `~/.ssh` 权限为 `700`、文件权限为 `600`，SSH 服务允许该账号做本地 TCP 转发。

```text
from="10.73.0.2",restrict,port-forwarding,permitopen="127.0.0.1:8888",permitopen="127.0.0.1:18888",permitopen="127.0.0.1:18300",command="/home/spark/.local/lib/spark-switcher/ssh-command.sh" ssh-ed25519 WINDOWS_PUBLIC_KEY
```

在联网准备期间安装所需客户端。ZCode 采用适配版 **3.18.2 x64**，DeepSeek Harness 桌面版采用 **0.2.2-rc.3 x64**，OpenCode 使用 **1.19.5 Windows x64 baseline**。用 npm 压缩包安装 OpenCode 时，将 `package/bin/opencode.exe` 放到仓库的 `tools\opencode\opencode.exe`。ZCode 和 DeepSeek Harness 可按官方程序安装。 [下载地址和完整安装位置](../USAGE.md#准备客户端)

在 Windows 仓库目录检查 Spark 状态并启动界面。

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\SparkSwitcher.ps1 -Check
.\Launch.cmd
```

`-Check` 查询控制器状态。保持切换器窗口打开，以维持三个回环 API 的 SSH 转发。选模型、等待就绪，再打开 ZCode、DeepSeek Harness 或 OpenCode。Windows 端可以用 `Invoke-RestMethod http://127.0.0.1:8888/v1/models` 验证 GLM 转发，其他模型按表替换端口。

## 8. 完全断网重启验收

1. 启用并保存三台设备的有线网络配置，提前安装客户端。两台 Spark 都应有本地模型权重、镜像和 SSH 服务。
2. 断开三台设备的外网链路，保留两根直连线，重启主 Spark、从 Spark 和笔记本。
3. 在笔记本打开 Spark Switcher，用 `-Check` 确认控制器可达。依次启动 GLM、DeepSeek 和 Qwen，每次在 Windows 访问对应的 `/v1/models` 并验证一轮聊天。
4. 分别用 ZCode、DeepSeek Harness 和 OpenCode 发送短消息，确认回复来自当前模型。测试读写文件、编程和识图可使用仓库自带演示。 [离线演示](../demo/README.md)

| 现象 | 检查位置 |
| --- | --- |
| `prepare.sh check` 报 RoCE 路由、MTU 或 GID 错误 | 核对两端 `ip -4 route get`、`rdma link show` 与 `server.json`，确认每条 rail 使用独立子网。 |
| 准备镜像失败 | 检查两台的 `docker image inspect` 输出，确认是 ARM64，且同名标签的内容 ID 一致。 |
| 模型切换失败或回滚 | 在主 Spark 查询 `sparkctl.py status`、`sparkctl.py logs --lines 80`，并核对两台的磁盘空间与容器日志。 |
| Windows 显示直连未就绪 | 检查 RJ45 静态 IPv4、TCP 22、`spark_known_hosts` 第一列及主 Spark 受限公钥行。 |
| 状态可读，模型 API 不通 | 保持切换器窗口打开，确认模型就绪且 Windows 的 `8888`、`18888`、`18300` 可用于 SSH 转发。 |
