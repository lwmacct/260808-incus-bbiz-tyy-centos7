# Incus VM 网络经验

本文记录本仓库在 GitHub Actions runner 上运行 CentOS 7 Incus VM 的网络方案和
验证结论。网络测试 workflow 是可重复的 CI 实验，不等同于生产网络配置。

## 结论

默认使用 Incus managed bridge。它由 Incus 管理 DHCP、网关和 NAT，配置最少，适合
日常构建后的自动验证。Docker default bridge 方案只用于需要复用 Docker 网络的
临时实验：它必须额外运行 DHCP sidecar，故障面和地址冲突风险都更高。

| 方案 | VM 网卡父桥 | DHCP | NAT/转发 | 建议 |
| --- | --- | --- | --- | --- |
| Incus managed bridge | `incusbr0` | Incus dnsmasq | Incus 默认规则 | 默认 CI |
| Docker default bridge | `docker0` | workflow 临时 dnsmasq | Docker 默认规则 | 手动对照实验 |

## Incus managed bridge

`incus admin init --minimal` 创建 `incusbr0`。Incus 默认在该桥上提供：

- DHCP 地址和默认网关；
- 对 runner 外部网络的 IPv4 NAT；
- VM tap 设备与桥之间的二层转发。

GitHub-hosted runner 同时运行 Docker，Docker 可能在 `FORWARD` 或 `DOCKER-USER`
链中使用默认丢弃策略。workflow 在 `forward_incus=true` 时只添加两条窄规则：

```text
incusbr0 -> 外部接口：允许新连接
外部接口 -> incusbr0：只允许 RELATED,ESTABLISHED
```

规则优先写入 `DOCKER-USER`，不存在时才写入 `FORWARD`。这样不会改动 Docker
自己的 NAT 规则，也不会把所有接口的转发都放开。

适用条件：

1. runner 允许创建 bridge、dnsmasq 和 iptables 规则；
2. VM 使用 DHCP 获取地址；
3. 测试只需要出站 IPv4 和 runner 与 VM 的互 ping。

## Docker default bridge

Docker 的默认 `bridge` 网络通常有 IPAM 子网和网关，但不会为接入该 bridge 的
Incus VM tap 设备提供 DHCP。直接把 VM 接到 `docker0` 的结果通常是：二层链路
存在，但 guest 没有地址、默认路由和 DNS。

本仓库的实验按以下顺序处理：

1. `docker network inspect bridge` 读取实际 bridge 名、子网、网关和 DNS，不假设
   一定叫 `docker0` 或使用固定网段。
2. 从子网末端选择一个未被 Docker 容器使用的地址，并生成本次 run 专用的
   locally-administered MAC（以 `02:` 开头）。
3. 创建 Incus profile，把 VM 网卡以 `nictype=bridged` 接到实际父桥。
4. 在该桥上启动 dnsmasq，只监听该接口、关闭 DNS 服务（`--port=0`），只提供
   一个 DHCP 租约，并把 Docker 网关和宿主 DNS 写入 DHCP option。
5. 让 Docker 自己的转发和 NAT 继续工作，不额外插入 iptables 规则。
6. VM 停止、实例删除后终止 dnsmasq，并清理临时租约文件。

这种方式的关键点是 DHCP 地址必须和 Docker IPAM 的实际分配范围错开。当前脚本只
检查已有容器地址，并依赖 workflow concurrency 串行化实验；它不会修改 Docker
IPAM 范围，也不会为该地址建立持久 reservation。共享宿主上仍可能有外部 DHCP、
静态地址或其他进程抢占地址。因此它适合短生命周期 runner，不适合作为长期共享
网络服务。

## Guest 配置要点

镜像使用 `ifcfg-eth0`，并通过 NetworkManager 的 DHCP 获取地址。不能只把 tap
设备接入 bridge 就期待 CentOS 自动联网；必须同时满足：

- guest 网卡名称与配置文件一致（当前为 `eth0`）；
- `BOOTPROTO=dhcp` 且网卡自动启动；
- DHCP 返回地址、掩码、网关和 DNS；
- 内核包含 `virtio_net`，并且 Incus VM agent 可用。

本内核没有 9p。`agent:config` 光盘是启动 agent 的必要条件，虽然它不是网络设备，
但没有 agent 时 workflow 无法执行 guest 内的网络检查。

## CI 资源分配

网络测试使用 composite action 动态读取 runner 资源：

- VM 使用 `nproc` 返回的全部 vCPU；
- 从 `MemTotal` 中预留 4 GiB 给宿主、Incus、QEMU 和测试工具；
- 剩余内存设置为 `limits.memory`。

测试会检查 guest 在线 CPU 数，并允许 guest `MemTotal` 落在配置上限的 90% 到
100% 之间。这样可以识别资源参数没有真正传入 QEMU 的情况，同时避免因内核和
虚拟化开销造成脆弱的精确字节比较。

## 验证顺序

`scripts/incus-vm-network-check.sh` 按依赖顺序检查，失败时会打印桥、路由、DNS、
iptables/nftables、Incus 日志和 guest console：

1. Incus agent 在 10 分钟内 ready；
2. 固定内核、CPU 数和内存上限正确；
3. DHCP 在 2 分钟内提供全局 IPv4 地址；
4. guest 有默认路由，且 guest 能 ping 网关；
5. runner 能反向 ping guest，确认不是单向出站；
6. guest 能解析并探测 CentOS 7 大陆 Vault 镜像的 IPv4 地址；
7. runner 和 guest 都能访问 CentOS 7 大陆 Vault 镜像的 HTTPS `repomd.xml`。大陆镜像探测默认是硬性
   检查；GitHub-hosted runner 的 workflow 将其设为非硬性，仅在日志中记录跨境出口
   不可达，避免把地域性网络策略误报为 VM 网络故障。

逐层检查比只执行 `curl` 更容易定位问题：没有地址是 DHCP 问题，没有默认路由是
DHCP option 或 guest 配置问题，只有 guest 访问失败通常是 forwarding/NAT 问题，
DNS 正常但 HTTPS 失败则应检查外部出口或仓库可用性。

## 故障排查

先确认父桥和租约，再看 guest 状态：

```bash
docker network inspect bridge
bridge link show
sudo incus list <instance> --format=yaml
sudo incus info <instance> --show-log
sudo incus exec <instance> -- ip -4 address show
sudo incus exec <instance> -- ip -4 route show
sudo incus exec <instance> -- cat /etc/resolv.conf
```

重点判断：

- 没有 IPv4：确认 `dnsmasq` 绑定的是实际父桥，且没有第二个 DHCP 服务冲突；
- 地址正确但无外网：检查 `DOCKER-USER`/`FORWARD`、`net.ipv4.ip_forward` 和
  Docker NAT；
- guest 能出网但 runner 不能 ping guest：检查父桥 tap 链路及宿主防火墙；
- 只有 DNS 失败：检查 DHCP option 6 和宿主 `/run/systemd/resolve/resolv.conf`；
- agent 不 ready：先检查 `agent:config` 设备、virtio console 和 VM console，
  不要把 agent 故障误判成 DHCP 故障。

失败时 workflow 的诊断函数会额外输出 `incusbr0`、父桥、iptables、nftables 和
Incus service 日志，优先保留这些输出再调整规则。

## 方案边界

`macvlan` 或 `ipvlan` 可以绕开部分 bridge 转发问题，但默认无法让宿主直接访问
guest，通常还要增加 host-side shim，复杂度高于本实验。生产环境应使用明确规划的
独立 bridge/VLAN、固定 DHCP 管理和防火墙策略；不要把 CI 中的临时 dnsmasq 直接
复制到共享宿主。
