# 中国大陆 CentOS 7 Vault 镜像调查

CentOS Linux 7 已于 2024-06-30 结束维护，原 `mirrorlist.centos.org` 不再是
CentOS 7 的可用更新入口。CentOS 7.9.2009 的最终包集仍保存在 Vault；中国大陆
也有多个站点保留了 `centos-vault/7.9.2009`。

本页记录 2026-08-09 的探测结果。镜像状态会变化，构建和运行时验证仍应以实际
`repomd.xml` 和 RPM 签名为准。

## 调查结论

以下镜像包含 `os`、`updates`、`extras` 和 Minimal ISO。使用测试 VM 自带的
CentOS 7 `yum 3.4.3`、`curl 7.29.0` 和 CA 包进行验证，而不是只用新系统的
浏览器或 `curl` 探测首页。

| 提供方 | Vault 根地址 | 测试 VM 的 yum 结果 | 是否写入成品 repo |
| --- | --- | --- | --- |
| 腾讯云 | `https://mirrors.cloud.tencent.com/centos-vault/` | 通过 | 首选 |
| 阿里云 | `https://mirrors.aliyun.com/centos-vault/` | 通过 | 备用 1 |
| 华为云 | `https://mirrors.huaweicloud.com/centos-vault/` | 通过 | 备用 2 |
| 南京大学 | `https://mirrors.nju.edu.cn/centos-vault/` | 通过 | 备用 3 |
| 哈尔滨工业大学 | `https://mirrors.hit.edu.cn/centos-vault/` | 通过 | 备用 4 |
| 中国科学技术大学 | `https://mirrors.ustc.edu.cn/centos-vault/` | 通过，但 `updates` 停留在较早快照 | 否 |
| 清华大学 | `https://mirrors.tuna.tsinghua.edu.cn/centos-vault/` | 旧版 yum 下载元数据时返回 403 | 否 |
| 浙江大学 | `https://mirrors.zju.edu.cn/centos-vault/` | 旧版 yum 下载元数据时返回 403 | 否 |

写入成品的五个镜像在探测时具有相同的仓库 revision：

```text
os       1604001756
updates  1718987347
extras   1712079707
```

它们的三个 `repomd.xml` 与 `vault.centos.org` 内容一致，ISO 的
`sha256sum.txt.asc` 也一致。测试 VM 能通过这组源解析并安装
`virt-what-1.18-4.el7` 及其依赖，执行 `virt-what` 输出 `qemu`。

## 成品 repo 设计

镜像内只启用 `base`、`updates` 和 `extras`，版本固定为 `7.9.2009`，不使用已
失效的 mirrorlist，也不使用会随 `$releasever` 漂移的普通 `centos/7` 路径。
每个 repo 的 `baseurl` 按腾讯、阿里、华为、南大、哈工大排列，并设置：

```ini
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-centosofficial
failovermethod=priority
```

一个 repo 下的多条 `baseurl` 由 yum 作为同一仓库的候选镜像处理；首选地址失败
时可以换到后续地址。`yum-plugin-fastestmirror` 仍可能根据已测速度选择候选站点，
所以这不是强制永远使用腾讯，而是“中国大陆镜像池 + 声明顺序”的容错配置。

在构建的 `post-files` 最后阶段，其他 `.repo` 文件会移入
`/etc/yum.repos.d/disabled/`。这样构建期间仍使用官方 Vault，最终成品 yum 不会
扫描旧文件，同时保留原文件供排查；成品的 `/etc/yum.repos.d` 顶层只留下大陆源
`CentOS-Base.repo`。

## 构建 ISO 的限制

`distrobuilder v3.3.1` 的 `centos-http` 下载器对 `7.9.2009` 这类三段版本有
硬编码限制：`source.url` 不包含 `vault.centos.org` 时直接返回
`Patch releases are only supported when using vault.centos.org as the mirror`。
当前上游主分支仍有同一限制。

因此当前方案明确分成两段：

1. Minimal ISO 仍从官方 `vault.centos.org` 获取，并使用 CentOS 内嵌公钥验证
   `sha256sum.txt.asc` 和 ISO 摘要；
2. 构建包安装完成、镜像文件定制的最后 `post-files` 阶段才写入中国大陆 Vault
   repo；构建期间和内核安装期间仍使用官方 Vault。

如果中国大陆构建节点无法访问官方 Vault，应在升级或修补 distrobuilder 下载器
后，把 `source.url` 切到已验证的大陆 Vault。不要仅通过在 URL 中拼入
`vault.centos.org` 字符串来绕过检查；这种配置依赖 URL 转发细节，难以审计。

## 运维验证

在实例中执行：

```bash
yum clean all
yum repolist
yum --disablerepo='*' --enablerepo=base info virt-what
yum install virt-what
virt-what
```

预期 `base`、`updates`、`extras` 都可加载，`virt-what` 来自 `base`。CentOS 7
Vault 是冻结快照，即使 `yum update` 成功也不会获得 2024-06-30 之后的安全修复。
