> 本文作者：丁辉

# Actions 工作流说明

`workflows/containerd-bundle.yml` 一份文件同时兼容 Gitea Actions 与 GitHub Actions: Gitea 的
`WORKFLOW_DIRS` 默认为 `.gitea/workflows,.github/workflows` 并取第一个存在的目录, 本仓库没有
`.gitea`, 因此两边都能读到。

## 流水线介绍

| 步骤 |                             动作                             |
| :--: | :----------------------------------------------------------: |
|  1   |                           拉取仓库                           |
|  2   | 读 `.github/bundle-files.txt` 的唯一一行, 作为整包文件名与版本号 |
|  3   | 调 `scripts/download-containerd.sh --all` 下载并校验安装包, 已存在且校验通过的自动跳过 |
|  4   | 在 `packages/` 生成 `SHA256SUMS`, 把项目本体与 `packages` 打成整包, 临时目录随打随删 |
|  5   | 非 github.com 时按版本号建 Release 并上传整包附件, 附件已存在则跳过 |
|  6   |   github.com 时同样按版本号建 Release, 用 gh 上传整包附件    |

## 触发方式

|   方式   |                             说明                             |
| :------: | :----------------------------------------------------------: |
| 手动运行 | 仓库 Actions 页面选择 `containerd bundle`, 可选输入 `force_download=true` 强制重新下载 |
| 标签触发 |                        推送 `v*` 标签                        |

## 前置条件

| 项                        | 要求                                                                                      |
| :-----------------------: | :---------------------------------------------------------------------------------------: |
| runner                    | 标签需匹配 `runs-on: ubuntu-latest`, 且能访问 github.com                                |
| `RELEASE_TOKEN` | Gitea 访问令牌, 至少 `write:repository` |
| `REGISTRY_USER` | 上传账号, 未配置时使用触发人                                                              |
| `GITHUB_TOKEN`  | Github 访问令牌 |

## 版本获取

|            位置            |                          作用                          |
| :------------------------: | :----------------------------------------------------: |
|   `vars/containerd.yml`    |        决定下载哪个版本的安装包, 由下载脚本读取        |
| `.github/bundle-files.txt` | 决定整包文件名, 只写一行, 版本号自己填, 流水线原样读取 |

> 必须以 `.tar.gz` 结尾, 注释行会被忽略.

## Release 与附件

Release 的标签名就是版本号。

同名 Release 已存在时直接复用, 附件同名则跳过,。

## 包内结构

打包时排除 `.git`, `.github`, 其余原样保留。

```
Ansible-Containerd-bundle-<版本号>.tar.gz
└── Ansible-Containerd/
    ├── containerd.yml
    ├── containerd-uninstall.yml
    ├── ansible.cfg
    ├── hosts.ini
    ├── README.md
    ├── callback_plugins/
    ├── configs/
    ├── scripts/
    ├── templates/
    ├── vars/
    └── packages/
        ├── containerd-*-linux-amd64.tar.gz
        ├── runc.amd64
        ├── cni-plugins-linux-amd64-v*.tgz
        ├── crictl-v*-linux-amd64.tar.gz
        ├── nerdctl-*-linux-amd64.tar.gz
        └── SHA256SUMS
```

