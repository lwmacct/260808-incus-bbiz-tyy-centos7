# CentOS 7 + TYY Cloud 6.1 内核 Incus VM 镜像

本仓库使用 `distrobuilder` 构建 CentOS 7 Incus VM 镜像，并通过 GitHub Actions
验证启动、固定内核、两分区磁盘布局和网络连通性。镜像范围如下：

- 系统：CentOS Linux `7.9.2009`
- 架构：`amd64`（内核和 distrobuilder 使用 `x86_64`）
- 内核 RPM：TYY Cloud `6.1.0-2.3.ctl3`
- 运行内核：`6.1.0-2.3.ctl3.x86_64`
- 默认磁盘：`200 GiB`，仅包含 EFI 和根分区
- 预装工具：Docker Engine、Docker Compose、Buildx、`jq`、`dmidecode`、`pciutils`
- 类型：仅 VM
- 产物：`incus.tar.xz`、`disk.qcow2`、`SHA256SUMS`

镜像定义位于 [`images/standard.yaml`](images/standard.yaml)。构建、启动测试和
GHCR 发布由 [Build Incus VM image](.github/workflows/build-images-standard.yml)
workflow 完成。发布后的独立网络验证由
[Test VM network on Incus managed bridge](.github/workflows/test-network-incus-managed.yml)
workflow 完成；复用 Docker 默认 bridge 和 NAT 的对照实验由
[Test VM network on Docker default bridge](.github/workflows/test-network-docker-default.yml)
workflow 完成。

网络设计、DHCP 限制和故障排查经验见 [`docs/network.md`](docs/network.md)。中国大陆
CentOS 7 Vault 镜像的实测结果、取舍和构建限制见
[`docs/centos7-mirrors-cn.md`](docs/centos7-mirrors-cn.md)。

## 中国大陆 yum 源

成品镜像将 CentOS 7.9.2009 的 `base`、`updates`、`extras` 固定到中国大陆
Vault 镜像池，按腾讯云、阿里云、华为云、南京大学和哈尔滨工业大学排列。所有
地址使用 HTTPS，RPM 继续使用 CentOS 官方密钥验证；任一镜像不可用时 yum 可以
尝试后续地址。构建时下载 Minimal ISO 仍受 `distrobuilder v3.3.1` 限制而使用
官方 `vault.centos.org`；构建期间的包安装也使用官方 Vault，只有镜像定制完成前
的最后 `post-files` 阶段才切换成品运行时 yum 到大陆源。

## 固定内核

构建 workflow 从 GHCR 拉取固定的本地 kernel artifact，再验证归档和 RPM 的 SHA-256：

| RPM                                            | SHA-256                                                            |
| ---------------------------------------------- | ------------------------------------------------------------------ |
| `kernel-6.1.0-2.3.ctl3.x86_64.rpm` | `71efae39206f2eaa1c2b14bcfe392844392e35ce0b705cf3967c5be4327d40d3` |

VM 启动后，workflow 会精确验证 `uname -r` 为
`6.1.0-2.3.ctl3.x86_64`，并检查 RPM、默认 grub 内核、virtio 模块、Incus agent、
磁盘布局和网络。

## 默认磁盘布局

成品 `disk.qcow2` 的虚拟容量固定为 `200 GiB`，只包含第 1 个 `100 MiB` EFI
分区和第 2 个 ext4 根分区。根分区占用磁盘剩余空间，不创建独立数据分区或
不创建独立数据挂载点。

该虚拟容量也是 Incus 创建实例时的最小根盘容量；显式配置小于 `200 GiB` 的
实例或存储池 volume size 会被拒绝。把实例根盘扩大到 `200 GiB` 以上后，新增空间
与根分区相邻，可用于扩展根分区和根文件系统；镜像不会自动执行扩容。

独立网络 workflow 会把 runner 的全部可用 CPU 分配给 VM，并把总内存减去
`4 GiB` 后全部设置为 VM 内存上限。它验证 DHCP、默认路由、VM 与宿主的桥接
连通性、DNS，以及 VM 到 CentOS 7 大陆 Vault 镜像的 IPv4
HTTPS。

Docker bridge 对照 workflow 仅手动触发。它将 VM 网卡直接桥接到 `docker0`。
由于 Docker 默认网络不提供 DHCP，它在 `docker0` 上启动仅提供 DHCP 的
`dnsmasq`，并按本次 run 动态生成 MAC 和单一租约；VM 的转发和 NAT 则完全使用
Docker 的默认规则。

## GHCR 标签

CentOS 版本和内核版本由仓库配置固定，不再重复编码到 GHCR 标签中。所有标签使用
`artifact-` 前缀，后接镜像定义文件名；`standard` 对应
[`images/standard.yaml`](images/standard.yaml)。每次成功构建发布一个使用 12 位 Git
提交 ID 的可追溯标签，并更新 `artifact-standard-latest`：

```text
artifact-standard-latest
artifact-standard-sha-<git-commit-id-12>
artifact-standard-stable
```

`artifact-standard-stable` 不会随每次构建自动移动。通过
[Publish stable GHCR tag](.github/workflows/publish-stable.yml) 手动指定一个不可变
的 `artifact-standard-sha-*` 标签后，才会将它提升为 stable。

```bash
gh workflow run publish-stable.yml --ref main \
  -f source_tag=artifact-standard-sha-<git-commit-id-12>
```

发布地址：

```text
ghcr.io/lwmacct/260808-incus-bbiz-tyy-centos7
```

## 拉取和导入

```bash
mkdir -p out/centos7-tyy-kernel-vm
oras pull \
  --output out/centos7-tyy-kernel-vm \
  ghcr.io/lwmacct/260808-incus-bbiz-tyy-centos7:artifact-standard-latest
cd out/centos7-tyy-kernel-vm
sha256sum --check SHA256SUMS
sudo incus image import \
  incus.tar.xz disk.qcow2 \
  --alias centos-7-tyy-kernel-vm
```

该内核没有 9p，启动 VM 时必须挂载 Incus agent 配置光盘，同时关闭 Secure Boot：

```bash
sudo incus init centos-7-tyy-kernel-vm centos7-tyy-kernel --vm \
  -c security.secureboot=false
sudo incus config device add centos7-tyy-kernel agent disk source=agent:config
sudo incus start centos7-tyy-kernel
sudo incus exec centos7-tyy-kernel -- findmnt /
```

## 生命周期和源码

> [!WARNING]
> CentOS 7 已于 2024-06-30 结束维护，Vault 中的软件包不再接收安全更新。
> kernel artifact 未公开提供对应 SRPM。公开再分发镜像前，
> 应根据实际分发方式确认对应源码供应要求。

GHCR 中保存的是通用 OCI artifact，不是 SimpleStreams 树，不能直接作为
`incus remote add --protocol=simplestreams` 的地址。完整构建和验证说明见
[`docs/build.md`](docs/build.md)。
