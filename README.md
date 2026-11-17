> 本文作者：丁辉

# Ansible-Containerd

## 介绍

> Ansible 以二进制方式安装 / 卸载
>
> containerd 及配套组件, 版本, 路径, 镜像仓库全部变量化, 可重复执行

- 安装剧本 `containerd.yml`
- 卸载剧本 `containerd-uninstall.yml`

|  组件名称  |                           功能                            |       必要性        |
| :--------: | :-------------------------------------------------------: | :-----------------: |
| Containerd | 容器运行时守护进程，镜像与容器生命周期管理，提供 CRI 接口 |        必需         |
|    Runc    |               OCI 运行时，实际创建容器进程                |        必需         |
|  CNI 插件  |                  容器网络配置与 IP 分配                   | Kubernetes 场景必需 |
|   Crictl   |                      CRI 调试命令行                       |    可选，排错用     |
|  Nerdctl   |                     Docker 兼容命令行                     | 可选，日常操作方便  |

## 环境要求

| 角色 | 要求 |
|---|---|
| 控制节点 | Ansible 2.10.x, Python 3.10, 可直连 GitHub |
| 目标机 | Linux amd64 或 arm64, root 权限, systemd |
| 连通性 | 控制节点可免密 SSH 登录目标机 |

## 目录结构

```text
Ansible-Containerd/
├── containerd.yml            安装剧本
├── containerd-uninstall.yml  卸载剧本
├── ansible.cfg               精简回调, 关闭指纹确认
├── hosts.ini                 目标机清单
├── vars/
│   ├── containerd.yml        版本, 开关, 路径, 行为, 输出样式
│   └── registry.yml          镜像仓库与加速配置
├── templates/hosts.toml.j2   渲染每个仓库的 hosts.toml
├── configs/                  containerd.service, crictl.yaml
├── packages/                 二进制安装包, 缺失时由脚本下载
├── scripts/download-containerd.sh  下载脚本
└── callback_plugins/compact.py     精简输出回调
```

## 使用Ansible-Containerd开始安装

### 1. 准备主机

修改 `hosts.ini` 中目标机 IP 与私钥路径, 组名固定为 `containerd_nodes`

```ini
[containerd_nodes]
192.168.1.100
192.168.1.200
192.168.1.300

[containerd_nodes:vars]
ansible_user=root
ansible_password=你的密码
# ansible_port=22
# ansible_ssh_private_key_file=～/.ssh/user.pem
# 普通用户提权
# ansible_become=true
# 提权到哪个用户
# ansible_become_user=root
# ansible_become_password=密码
```

### 2. 常用命令

| 命令 | 作用 |
|:-:|:-:|
| `ansible-playbook containerd.yml --syntax-check` | 只校验语法, 不连目标机 |
| `ansible-playbook containerd.yml -e containerd_install_all=true` | 全量安装 5 个组件 |
| `ansible-playbook containerd.yml -e containerd_install_only=runc` | 只装 Runc, 忽略其他开关 |
| `ansible-playbook containerd.yml -e containerd_install_all=true -e containerd_auto_download=true` | 缺包时自动下载 |
| `ansible-playbook containerd.yml -e containerd_install_containerd=true -e containerd_install_runc=true` | 只装 Containerd 与 Runc |
| `ansible-playbook containerd.yml -e containerd_install_all=true -e containerd_install_nerdctl=false` | 全量安装但排除 Nerdctl |

> 一个开关都不给时, 任务将报错退出

**优先级：**`containerd_install_only` > `containerd_install_*=true` / `containerd_install_*=false` > `containerd_install_all ` > 未指定

**可用的组件名：**  `containerd`, `runc`, `cni`, `crictl`, `nerdctl`

### 3. 组件开关

|                             参数                             |  默认值   |                             作用                             |
| :----------------------------------------------------------: | :-------: | :----------------------------------------------------------: |
|                  `containerd_auto_download`                  |  `false`  | 控制节点缺少安装包时，是否允许剧本自动调用 `scripts/download-containerd.sh --need` 下载。为 `false` 时只报错并提示手动执行脚本 |
|                `containerd_check_config_warn`                |  `true`   | 安装完成后读取 `containerd config dump`，判断 stderr 有无告警并输出结果：无告警时输出 “配置加载无告警”，有告警时列出内容 |
|                 `containerd_cleanup_staging`                 |  `true`   | 安装结束后是否删除目标机的临时目录 `staging_dir`（默认 `/tmp/containerd-install`，存放分发文件和解压产物） |
|                  `containerd_force_restart`                  |  `false`  | 是否无条件重启 containerd。默认只在 systemd 单元、`config.toml`、`hosts.toml` 有变更时重启 |
|                  `containerd_output_color`                   |  `true`   | 输出绿色字体。默认在 配置告警结果 / 各组件版本 / 安装完成 输出。 |
| `ANSIBLE_STDOUT_CALLBACK=default ansible-playbook containerd.yml` | `compact` | 临时覆盖 `ansible.cfg` 里的回调设置，让这次执行输出 Ansible 原生的逐任务日志。 |

## 使用Ansible-Containerd卸载

> **卸载剧本默认保护：** 不追加 `-e containerd_uninstall_confirm=true` 会直接拒绝执行

| 命令 | 作用 |
|:-:|:-:|
| `ansible-playbook containerd-uninstall.yml -e containerd_uninstall_confirm=true --check` | 预览将被删除的路径, 不实际删除 |
| `ansible-playbook containerd-uninstall.yml -e containerd_uninstall_confirm=true` | 清理全部组件, 保留 `/var/lib/containerd` |
| `ansible-playbook containerd-uninstall.yml -e containerd_uninstall_confirm=true -e containerd_install_only=nerdctl` | 只清理 Nerdctl |
| `ansible-playbook containerd-uninstall.yml -e containerd_uninstall_confirm=true -e containerd_uninstall_remove_nerdctl=false` | 保留 Nerdctl 插件 |
| `ansible-playbook containerd-uninstall.yml -e containerd_uninstall_confirm=true -e containerd_uninstall_purge_data=true` | 同时删除镜像与容器数据, 不可恢复 |

**可用的组件名：**  `containerd`, `runc`, `cni`, `crictl`, `nerdctl`

## 脚本配置以及变量

- `vars/containerd.yml`
- `vars/registry.yml`

## 包下载脚本

```bash
bash scripts/download-containerd.sh                       # 按组件开关下载缺失的包
bash scripts/download-containerd.sh --list                # 只打印包名与地址, 不下载
bash scripts/download-containerd.sh --all                 # 下载全部 5 个组件
bash scripts/download-containerd.sh --component runc      # 只下载指定组件
bash scripts/download-containerd.sh --need crictl,nerdctl # 按缺包清单下载, 剧本自动下载时即用此参数
bash scripts/download-containerd.sh --force               # 已存在且校验通过的包也重新下载
bash scripts/download-containerd.sh --vars <path>         # 指定变量文件
```

## 排错

| 现象 | 原因与处理 |
|:-:|:-:|
| `cannot import name 'environmentfilter' from 'jinja2.filters'` | Ansible 2.10 与 jinja2 3.1 不兼容。临时处理：命令前加 `PYTHONPATH=/usr/lib/python3/dist-packages` |
