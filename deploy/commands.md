# Spark Switcher 双机部署命令

```text
01 主 Spark → 02 从 Spark → 03–04 主 Spark → 05 Windows → 06 主 Spark → 07 Windows
Windows RJ45 10.73.0.2/30 ── 主 Spark RJ45 10.73.0.1/30
主 Spark QSFP 0 ══ 从 Spark QSFP 0（两条 RoCE rail）
Rail 1  主 10.73.1.1/24 ── 从 10.73.1.2/24
Rail 2  主 10.73.2.1/24 ── 从 10.73.2.2/24
```

## 主 Spark

### 01a · 初始化（DGX OS 本机终端，使用部署账号）

```bash
sudo apt update
sudo apt install -y git python3 python3-venv openssh-client openssh-server rsync curl iproute2 ethtool util-linux
sudo systemctl enable --now ssh docker

# 原厂 DGX OS。只在 Docker 缺少 NVIDIA 运行时配置时补齐。
if ! sudo docker info --format '{{json .Runtimes}}' | grep -q '"nvidia"'; then
  command -v nvidia-ctk >/dev/null || sudo apt install -y nvidia-container-toolkit
  sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker
fi
sudo usermod -aG docker "$(id -un)"

# 使用本版本验证过的 RoCE 启动参数。若触发重启，登录后继续 01b。
if ! tr ' ' '\n' </proc/cmdline | grep -Fxq 'kho=off'; then
  sudo install -d -m 755 /etc/default/grub.d
  printf '%s\n' 'GRUB_CMDLINE_LINUX_DEFAULT="${GRUB_CMDLINE_LINUX_DEFAULT} kho=off"' |
    sudo tee /etc/default/grub.d/99-spark-switcher-kho.cfg >/dev/null &&
    sudo update-grub && sudo reboot
fi
```

### 01b · 配置静态 IP 和生成 SSH 公钥

```bash
# 使用新登录的终端。两台 Spark 各留至少 1 TB，同时保留单独的外网连接供下载。
uname -m
nvidia-smi
docker info --format '{{json .Runtimes}}'
df -h "$HOME" /var/lib/docker
tr ' ' '\n' </proc/cmdline | grep -Fx 'kho=off'
ip -br link
rdma link show
sudo netplan get
nmcli device status

# 本机独立 RJ45 接已开机的 Windows。两台 Spark 的 QSFP 0 互接。
# 按 rdma link show 的 netdev 字段填两个网卡名，区分大小写。
# 三个示例网段应与其他网段错开。若已有 NVIDIA Sync/Netplan 配置管理这两条 rail，改原配置，跳过新建 rail 文件。
(
  set -e
  read -r -p '主 Spark Rail 1 网卡名: ' rail1
  read -r -p '主 Spark Rail 2 网卡名: ' rail2
  read -r -p '主 Spark 接 Windows 的 RJ45 网卡名: ' rj45
  for iface in "$rail1" "$rail2" "$rj45"; do
    [[ "$iface" =~ ^[A-Za-z0-9_.-]+$ ]]
    ip link show dev "$iface" >/dev/null
  done
  [[ "$rail1" != "$rail2" && "$rail1" != "$rj45" && "$rail2" != "$rj45" ]]
  candidate=$(mktemp /tmp/90-spark-switcher.XXXXXX.yaml)
  cat > "$candidate" <<EOF
network:
  version: 2
  ethernets:
    "$rail1":
      renderer: networkd
      dhcp4: false
      dhcp6: false
      accept-ra: false
      addresses: [10.73.1.1/24]
      mtu: 9000
      optional: true
    "$rail2":
      renderer: networkd
      dhcp4: false
      dhcp6: false
      accept-ra: false
      addresses: [10.73.2.1/24]
      mtu: 9000
      optional: true
EOF
  # 本机屏幕确认配置时按 Enter 保存。
  sudo netplan try --config-file "$candidate" --timeout 120

  if ! nmcli connection show spark-switcher-lan >/dev/null 2>&1; then
    sudo nmcli connection add type ethernet ifname "$rj45" con-name spark-switcher-lan
  fi
  sudo nmcli connection modify spark-switcher-lan connection.interface-name "$rj45" \
    connection.autoconnect yes connection.autoconnect-priority 100 \
    ipv4.method manual ipv4.addresses 10.73.0.1/30 ipv4.gateway '' ipv4.dns '' \
    ipv4.never-default yes ipv6.method disabled
  sudo nmcli connection up spark-switcher-lan ifname "$rj45"

  if command -v ufw >/dev/null && sudo env LC_ALL=C ufw status | grep -q '^Status: active$'; then
    sudo ufw allow in on "$rail1" from 10.73.1.2 to 10.73.1.1
    sudo ufw allow in on "$rail2" from 10.73.2.2 to 10.73.2.1
    sudo ufw allow in on "$rj45" proto tcp from 10.73.0.2 to 10.73.0.1 port 22
  fi
  ip -br -4 addr
  sudo netplan get
)
```

```bash
install -d -m 700 "$HOME/.ssh"
test -f "$HOME/.ssh/id_ed25519" || ssh-keygen -q -t ed25519 -N '' -C spark-head-to-worker -f "$HOME/.ssh/id_ed25519"

# 将这一行主 Spark 用户公钥带到从 Spark 的 02b。
cat "$HOME/.ssh/id_ed25519.pub"

# 将主 Spark 用户名、ED25519 主机公钥和指纹留给 Windows 的 05b。
id -un
sudo ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
sudo cat /etc/ssh/ssh_host_ed25519_key.pub

# 接着在从 Spark 执行 02a、02b。
```

### 03 · 主 Spark 信任从 Spark，验证 RoCE，生成 server.json

```bash
ip -4 route get 10.73.1.2
ip -4 route get 10.73.2.2
ping -I 10.73.1.1 -M do -s 8972 -c 3 10.73.1.2
ping -I 10.73.2.1 -M do -s 8972 -c 3 10.73.2.2

read -r -p '从 Spark 在 02b 显示的部署用户名: ' worker_user
read -r -p '粘贴从 Spark 在 02b 显示的 ED25519 主机公钥整行: ' worker_pub
read -r key_type key_data _ <<< "$worker_pub"

# 确认输出与 02b 的主机公钥指纹一致，再保存。
printf '%s %s\n' "$key_type" "$key_data" | ssh-keygen -lf -
read -r -p '指纹一致请输入 yes: ' confirmed
if [[ "$confirmed" == yes && "$key_type" == ssh-ed25519 && -n "$key_data" ]]; then
  touch "$HOME/.ssh/known_hosts"
  chmod 600 "$HOME/.ssh/known_hosts"
  worker_host_entry="10.73.1.2 $key_type $key_data"
  grep -Fxq -- "$worker_host_entry" "$HOME/.ssh/known_hosts" ||
    printf '%s\n' "$worker_host_entry" >> "$HOME/.ssh/known_hosts"
fi

worker_target="$worker_user@10.73.1.2"
ssh -o BatchMode=yes -o StrictHostKeyChecking=yes "$worker_target" hostname -s
ssh -o BatchMode=yes -o StrictHostKeyChecking=yes "$worker_target" docker info --format '{{.ServerVersion}}'
```

```bash
# 两条免密 SSH 验证成功后，在同一个主 Spark 终端执行。
cd "$HOME"
git clone https://github.com/Zx1234567891/spark-switcher.git
cd "$HOME/spark-switcher"
git checkout --detach f6af7f105af6d802b134bb7dbc291a25668a11dd
install -d -m 700 "$HOME/.config/spark-switcher"

# 以实际 IP 找网卡和 HCA，从四条本地 rail 的 RoCE v2 IPv4 GID 中选共同索引。
# 保留仓库样例中的固定模型版本、镜像 ID 和路径。
python3 - "$worker_target" <<'PY'
import json
from pathlib import Path
import subprocess
import sys

probe = r"""
import ipaddress
import json
from pathlib import Path
import socket
import subprocess
import sys

interfaces = json.loads(subprocess.check_output(["ip", "-j", "-4", "addr", "show"], text=True))
rails = []
for address in sys.argv[1:]:
    nics = [item["ifname"] for item in interfaces if any(
        entry["local"] == address for entry in item.get("addr_info", [])
    )]
    if len(nics) != 1:
        raise SystemExit(f"Expected one interface with {address}: {nics}")
    nic = nics[0]
    if (Path("/sys/class/net") / nic / "mtu").read_text().strip() != "9000":
        raise SystemExit(f"Expected MTU 9000 on {nic}")
    matches = {}
    expected = ipaddress.IPv4Address(address)
    for port in Path("/sys/class/infiniband").glob("*/ports/1"):
        if "ACTIVE" not in (port / "state").read_text():
            continue
        for entry in (port / "gid_attrs/types").iterdir():
            index = entry.name
            try:
                if entry.read_text().strip() != "RoCE v2":
                    continue
                bound = (port / "gid_attrs/ndevs" / index).read_text().strip()
                gid = ipaddress.IPv6Address((port / "gids" / index).read_text().strip())
            except (OSError, ValueError):
                continue
            if bound == nic and gid.ipv4_mapped == expected:
                matches.setdefault(port.parents[1].name, []).append(int(index))
    if len(matches) != 1:
        raise SystemExit(f"Expected one active HCA with a RoCE v2 IPv4 GID on {nic} ({address}): {matches}")
    hca, indices = next(iter(matches.items()))
    rails.append({"interface": nic, "hca": hca, "indices": indices})
print(json.dumps({"hostname": socket.gethostname().split(".")[0], "rails": rails}))
"""

target = sys.argv[1]
ssh = ["ssh", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", target]
nodes = {}
index_sets = []
for role, command, addresses in (
    ("head", [], ["10.73.1.1", "10.73.2.1"]),
    ("worker", ssh, ["10.73.1.2", "10.73.2.2"]),
):
    result = subprocess.check_output(command + ["python3", "-", *addresses], text=True, input=probe)
    data = json.loads(result)
    rails = data["rails"]
    nodes[role] = {
        "hostname": data["hostname"],
        "roce_address": addresses[0],
        "roce_interface": rails[0]["interface"],
        "roce_devices": [rail["hca"] for rail in rails],
    }
    if len(set(nodes[role]["roce_devices"])) != 2:
        raise SystemExit(f"Expected two different HCA devices on {role}")
    index_sets.extend(set(rail["indices"]) for rail in rails)

common = set.intersection(*index_sets)
if not common:
    raise SystemExit(f"No common RoCE v2 GID index across the four rail endpoints: {index_sets}")
nodes["worker"]["ssh_target"] = target

path = Path.home() / ".config/spark-switcher/server.json"
source = path if path.exists() else Path("server/server.example.json")
config = json.loads(source.read_text(encoding="utf-8"))
config.update(nodes, fabric={"mtu": 9000, "gid_index": min(common), "require_kho_off": True})
path.touch(mode=0o600, exist_ok=True)
path.write_text(json.dumps(config, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print(json.dumps({key: config[key] for key in ("head", "worker", "fabric")}, indent=2))
PY

bash deploy/prepare.sh check
```

### 04 · 下载镜像和权重，准备双机

```bash
# prepare.sh check 成功后执行。保持主 Spark 外网连接。
cd "$HOME/spark-switcher"
python3 -m venv "$HOME/.local/share/spark-switcher/download-env"
source "$HOME/.local/share/spark-switcher/download-env/bin/activate"
python -m pip install -U huggingface_hub

# Qwen 从魔搭下载；若直接使用 Hugging Face，跳过以下三条命令。
python -m pip install -U modelscope
modelscope download --model nv-community/Qwen3.8-Flash-Next-NVFP4 \
  --revision bb325e902fbb183287fcf009deba45d59abeb079 \
  --local_dir "$HOME/models/qwen-modelscope"
python3 deploy/import-qwen-modelscope.py "$HOME/models/qwen-modelscope"
```

```bash
# 魔搭导入成功后执行；若跳过魔搭，脚本会直接从 Hugging Face 获取 Qwen。
# DeepSeek 镜像会自动下载、校验、导入，并同另外两套模型一起同步到从 Spark。
bash deploy/prepare.sh all
```

```bash
# 验证本机 Docker GPU；下一条 SSH 命令在从 Spark 执行同一检查。
docker run --rm --pull=never --gpus all --entrypoint nvidia-smi tensorfold-glm53:v0.6.0 -L
worker_target=$(python3 deploy/config.py get worker.ssh_target)
ssh -o BatchMode=yes -o StrictHostKeyChecking=yes "$worker_target" \
  docker run --rm --pull=never --gpus all --entrypoint nvidia-smi tensorfold-glm53:v0.6.0 -L

# 接着到 Windows 做 05a、05b，把 Windows 用户公钥带回这里做 06。
```

### 06 · 授权 Windows 免密控制和 API 转发

```bash
(
  set -e
  gate="$HOME/.local/lib/spark-switcher/ssh-command.sh"
  test -x "$gate"
  read -r -p '粘贴 Windows 05b 显示的 ssh-ed25519 用户公钥整行: ' windows_pub
  read -r key_type key_data _ <<< "$windows_pub"
  [[ "$key_type" == ssh-ed25519 && -n "$key_data" ]]
  printf '%s %s\n' "$key_type" "$key_data" | ssh-keygen -lf -
  install -d -m 700 "$HOME/.ssh"
  touch "$HOME/.ssh/authorized_keys"
  chmod 600 "$HOME/.ssh/authorized_keys"
  entry="from=\"10.73.0.2\",restrict,port-forwarding,permitopen=\"127.0.0.1:8888\",permitopen=\"127.0.0.1:18888\",permitopen=\"127.0.0.1:18300\",command=\"$gate\" $key_type $key_data"
  grep -Fxq -- "$entry" "$HOME/.ssh/authorized_keys" ||
    printf '%s\n' "$entry" >> "$HOME/.ssh/authorized_keys"
)

sudo /usr/sbin/sshd -T -C "user=$(id -un),addr=10.73.0.2,host=windows" |
  grep -E '^(pubkeyauthentication|allowtcpforwarding|disableforwarding|permitopen) '

# 返回 Windows 执行 07。
```

## 从 Spark

### 02a · 初始化（DGX OS 本机终端，使用部署账号）

```bash
sudo apt update
sudo apt install -y python3 openssh-client openssh-server rsync curl iproute2 ethtool
sudo systemctl enable --now ssh docker
if ! sudo docker info --format '{{json .Runtimes}}' | grep -q '"nvidia"'; then
  command -v nvidia-ctk >/dev/null || sudo apt install -y nvidia-container-toolkit
  sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker
fi
sudo usermod -aG docker "$(id -un)"

# 若触发重启，登录后继续 02b。
if ! tr ' ' '\n' </proc/cmdline | grep -Fxq 'kho=off'; then
  sudo install -d -m 755 /etc/default/grub.d
  printf '%s\n' 'GRUB_CMDLINE_LINUX_DEFAULT="${GRUB_CMDLINE_LINUX_DEFAULT} kho=off"' |
    sudo tee /etc/default/grub.d/99-spark-switcher-kho.cfg >/dev/null &&
    sudo update-grub && sudo reboot
fi
```

### 02b · 配置 RoCE 静态 IP，授权主 Spark 登录

```bash
# 使用新登录的终端。
uname -m
nvidia-smi
docker info --format '{{json .Runtimes}}'
df -h "$HOME" /var/lib/docker
tr ' ' '\n' </proc/cmdline | grep -Fx 'kho=off'
ip -br link
rdma link show
sudo netplan get

# 两个网卡分别对应主 Spark 的同号 rail。若这两条 rail 已有配置，改原配置，跳过新建文件。
(
  set -e
  read -r -p '从 Spark Rail 1 网卡名: ' rail1
  read -r -p '从 Spark Rail 2 网卡名: ' rail2
  for iface in "$rail1" "$rail2"; do
    [[ "$iface" =~ ^[A-Za-z0-9_.-]+$ ]]
    ip link show dev "$iface" >/dev/null
  done
  [[ "$rail1" != "$rail2" ]]
  candidate=$(mktemp /tmp/90-spark-switcher.XXXXXX.yaml)
  cat > "$candidate" <<EOF
network:
  version: 2
  ethernets:
    "$rail1":
      renderer: networkd
      dhcp4: false
      dhcp6: false
      accept-ra: false
      addresses: [10.73.1.2/24]
      mtu: 9000
      optional: true
    "$rail2":
      renderer: networkd
      dhcp4: false
      dhcp6: false
      accept-ra: false
      addresses: [10.73.2.2/24]
      mtu: 9000
      optional: true
EOF
  # 本机屏幕确认配置时按 Enter 保存。
  sudo netplan try --config-file "$candidate" --timeout 120

  if command -v ufw >/dev/null && sudo env LC_ALL=C ufw status | grep -q '^Status: active$'; then
    sudo ufw allow in on "$rail1" from 10.73.1.1 to 10.73.1.2
    sudo ufw allow in on "$rail2" from 10.73.2.1 to 10.73.2.2
  fi
  ip -br -4 addr
  rdma link show
)
ping -I 10.73.1.2 -M do -s 8972 -c 3 10.73.1.1
ping -I 10.73.2.2 -M do -s 8972 -c 3 10.73.2.1
```

```bash
(
  set -e
  read -r -p '粘贴主 Spark 01b 显示的 ssh-ed25519 用户公钥整行: ' head_user_pub
  read -r key_type key_data _ <<< "$head_user_pub"
  [[ "$key_type" == ssh-ed25519 && -n "$key_data" ]]
  printf '%s %s\n' "$key_type" "$key_data" | ssh-keygen -lf -
  install -d -m 700 "$HOME/.ssh"
  touch "$HOME/.ssh/authorized_keys"
  chmod 600 "$HOME/.ssh/authorized_keys"
  entry="from=\"10.73.1.1\",restrict $key_type $key_data"
  grep -Fxq -- "$entry" "$HOME/.ssh/authorized_keys" ||
    printf '%s\n' "$entry" >> "$HOME/.ssh/authorized_keys"
)

# 将以下用户名、指纹和主机公钥带回主 Spark 的 03。
id -un
sudo ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
sudo cat /etc/ssh/ssh_host_ed25519_key.pub
```

## Windows 笔记本

### 05a · 静态 IP 和 OpenSSH（管理员 Windows PowerShell）

```powershell
$ErrorActionPreference = 'Stop'
$capability = 'OpenSSH.Client~~~~0.0.1.0'
if ((Get-WindowsCapability -Online -Name $capability).State -ne 'Installed') {
    Add-WindowsCapability -Online -Name $capability
}

Get-NetAdapter -Physical | Format-Table Name, InterfaceDescription, Status, LinkSpeed
$nic = Read-Host '输入接主 Spark 的专用有线网卡 Name'
Get-NetAdapter -Name $nic -Physical
if (!(Get-NetIPAddress -InterfaceAlias $nic -IPAddress 10.73.0.2 -AddressFamily IPv4 -ErrorAction SilentlyContinue)) {
    New-NetIPAddress -InterfaceAlias $nic -IPAddress 10.73.0.2 -PrefixLength 30
}
Get-NetIPConfiguration -InterfaceAlias $nic
Test-NetConnection -ComputerName 10.73.0.1 -Port 22
```

### 05b · 安装切换器和客户端，生成用户密钥（普通 Windows PowerShell）

```powershell
# 使用以后打开客户端的日常 Windows 用户。保持外网连接完成下载。
$ErrorActionPreference = 'Stop'
$rev = 'f6af7f105af6d802b134bb7dbc291a25668a11dd'
$base = Join-Path $env:LOCALAPPDATA 'SparkSwitcher'
$stage = Join-Path $base 'downloads'
$repo = Join-Path $base "spark-switcher-$rev"
$sshDir = Join-Path $base 'ssh'
New-Item -ItemType Directory -Force -Path $stage,$sshDir | Out-Null

function Get-DeploymentFile([string]$Url, [string]$Destination) {
    curl.exe -fL --retry 3 -o $Destination $Url
    if ($LASTEXITCODE -ne 0) { throw "下载失败：$Url" }
}

if (!(Test-Path -LiteralPath (Join-Path $repo 'Launch.cmd'))) {
    $archive = Join-Path $stage 'spark-switcher.zip'
    Get-DeploymentFile "https://codeload.github.com/Zx1234567891/spark-switcher/zip/$rev" $archive
    Expand-Archive -LiteralPath $archive -DestinationPath $base -Force
}
Set-Location -LiteralPath $repo

$zcode = Join-Path $stage 'ZCode-3.18.2-win-x64.exe'
$deepseek = Join-Path $stage 'deepseek-harness-0.2.2-rc.3-win-x64.exe'
$openCodeArchive = Join-Path $stage 'opencode-windows-x64-baseline-1.19.5.tgz'
Get-DeploymentFile 'https://cdn-zcode.z.ai/zcode/electron/releases/3.18.2/windows-x64/ZCode-3.18.2-win-x64.exe' $zcode
Get-DeploymentFile 'https://download.deepseek.com/dsh-desk/bin/win-x64/deepseek-harness-0.2.2-rc.3-win-x64.exe' $deepseek
Get-DeploymentFile 'https://registry.npmjs.org/opencode-windows-x64-baseline/-/opencode-windows-x64-baseline-1.19.5.tgz' $openCodeArchive

# 这两个安装程序会弹出窗口，完成安装后再继续。
Start-Process -FilePath $zcode -Wait
Start-Process -FilePath $deepseek -Wait

tar.exe -xzf $openCodeArchive -C $stage package/bin/opencode.exe
if ($LASTEXITCODE -ne 0) { throw 'OpenCode 解压失败' }
New-Item -ItemType Directory -Force -Path .\tools\opencode | Out-Null
Copy-Item -LiteralPath (Join-Path $stage 'package\bin\opencode.exe') -Destination .\tools\opencode\opencode.exe -Force
& .\tools\opencode\opencode.exe --version

$linuxUser = Read-Host '主 Spark 在 01b 显示的部署用户名'
if ($linuxUser -cnotmatch '^[a-z_][a-z0-9_-]*$') { throw '主 Spark 用户名格式不正确' }
@{ sshUser = $linuxUser; headAddress = '10.73.0.1'; localAddress = '10.73.0.2' } |
    ConvertTo-Json | Set-Content -LiteralPath .\connection.json -Encoding Ascii

if (!(Test-Path -LiteralPath "$sshDir\id_ed25519")) {
    # 询问 passphrase 时按两次 Enter，供重启后自动连接。
    ssh-keygen.exe -t ed25519 -f "$sshDir\id_ed25519" -C spark-switcher
    if ($LASTEXITCODE -ne 0) { throw 'SSH 密钥生成失败' }
}

$parts = (Read-Host '粘贴主 Spark 在 01b 显示的 ED25519 主机公钥整行').Trim() -split '\s+'
if ($parts.Count -lt 2 -or $parts[0] -cne 'ssh-ed25519') { throw '主机公钥格式不正确' }
$trusted = "10.73.0.1 $($parts[0]) $($parts[1])"
$preview = Join-Path $sshDir 'pending_known_hosts'
$trusted | Set-Content -LiteralPath $preview -Encoding Ascii
ssh-keygen.exe -lf $preview
if ($LASTEXITCODE -ne 0) { throw '无法读取主机公钥指纹' }
if ((Read-Host '与主 Spark 01b 指纹一致请输入 yes') -cne 'yes') { throw '主机公钥未确认' }
Move-Item -LiteralPath $preview -Destination "$sshDir\spark_known_hosts" -Force

# 将这一行 Windows 用户公钥带到主 Spark 执行 06。
Get-Content -LiteralPath "$sshDir\id_ed25519.pub"
```

### 07 · 验证免密和启动切换器（普通 Windows PowerShell）

```powershell
$ErrorActionPreference = 'Stop'
$base = Join-Path $env:LOCALAPPDATA 'SparkSwitcher'
Set-Location -LiteralPath (Join-Path $base 'spark-switcher-f6af7f105af6d802b134bb7dbc291a25668a11dd')
$connection = Get-Content -Raw -LiteralPath .\connection.json | ConvertFrom-Json
$sshDir = Join-Path $base 'ssh'
$target = "$($connection.sshUser)@$($connection.headAddress)"
$sshArgs = @('-n', '-b', $connection.localAddress, '-o', 'BatchMode=yes',
    '-o', 'StrictHostKeyChecking=yes', '-o', 'HostKeyAlgorithms=ssh-ed25519',
    '-o', "UserKnownHostsFile=$sshDir\spark_known_hosts", '-o', 'IdentitiesOnly=yes',
    '-i', "$sshDir\id_ed25519", $target)
$sshExe = Join-Path $env:WINDIR 'System32\OpenSSH\ssh.exe'
& $sshExe @sshArgs 'sparkctl status'
if ($LASTEXITCODE -ne 0) { throw 'Windows 到主 Spark 的免密 SSH 验证失败' }

powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\SparkSwitcher.ps1 -Check
if ($LASTEXITCODE -ne 0) { throw 'Spark Switcher 检查失败' }
.\Launch.cmd
```

```powershell
# 保持切换器窗口打开。下面每块先执行 switch，重复 status 直到对应模型为 ready，再请求 API。
# 首次验收后，断开三台设备的外网、保留两根直连线并重启，再重复 07。
```

```powershell
# GLM
& $sshExe @sshArgs 'sparkctl switch glm'
& $sshExe @sshArgs 'sparkctl status'
curl.exe --noproxy '*' -fsS http://127.0.0.1:8888/v1/models
```

```powershell
# DeepSeek
& $sshExe @sshArgs 'sparkctl switch deepseek'
& $sshExe @sshArgs 'sparkctl status'
curl.exe --noproxy '*' -fsS http://127.0.0.1:18888/v1/models
```

```powershell
# Qwen
& $sshExe @sshArgs 'sparkctl switch qwen'
& $sshExe @sshArgs 'sparkctl status'
curl.exe --noproxy '*' -fsS http://127.0.0.1:18300/v1/models
```

```powershell
# 从切换器打开 ZCode、DeepSeek Harness、OpenCode，在各自输入框发送以下测试消息。
# 只回复 SPARK_OK
```
