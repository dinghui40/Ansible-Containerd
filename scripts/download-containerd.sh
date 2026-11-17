#!/usr/bin/env bash
# =============================================================
# containerd 二进制安装包下载脚本
#
# 版本, 组件开关, 下载源均从 vars/containerd.yml 读取, 改版本只需改该文件
#
# 用法:
#   bash scripts/download-containerd.sh                     按组件开关下载缺失的包
#   bash scripts/download-containerd.sh --all               下载全部 5 个组件
#   bash scripts/download-containerd.sh --component runc    只下载指定组件
#   bash scripts/download-containerd.sh --need crictl,nerdctl  按缺包清单下载, 由剧本调用
#   bash scripts/download-containerd.sh --force            已存在且校验通过的包也重新下载
#   bash scripts/download-containerd.sh --list             只打印包名与下载地址, 不下载
#   bash scripts/download-containerd.sh --vars <path>      指定变量文件
#
# 组件名: containerd runc cni crictl nerdctl
# --only 为 --component 的别名
# =============================================================
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
VARS_FILE=${VARS_FILE:-${SCRIPT_DIR}/../vars/containerd.yml}

FORCE=0
DRY_RUN=0
COMPONENT=""
NEED=""
ALL_ARG=0
CONNECT_TIMEOUT=${CONNECT_TIMEOUT:-10}
MAX_TIME=${MAX_TIME:-900}

log()  { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date '+%F %T')" "$*" >&2; }
die()  { printf '[%s] ERROR: %s\n' "$(date '+%F %T')" "$*" >&2; exit 1; }

usage() {
  awk 'NR>2 && /^#/ { sub(/^# ?/, ""); print; next } NR>2 { exit }' "${BASH_SOURCE[0]}"
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force)          FORCE=1; shift ;;
    --dry-run|--list) DRY_RUN=1; shift ;;
    --all)            ALL_ARG=1; shift ;;
    --component|--only) COMPONENT=${2:-}; shift 2 ;;
    --need)           NEED=${2:-}; shift 2 ;;
    --vars)           VARS_FILE=${2:-}; shift 2 ;;
    -h|--help)        usage ;;
    *) die "未知参数: $1 (用 --help 查看用法)" ;;
  esac
done

# ---------- 变量文件 ------------------------------------------
yaml_get() {
  local key=$1 def=${2:-} line val
  [[ -f $VARS_FILE ]] || { printf '%s' "$def"; return; }
  line=$(grep -m1 -E "^${key}:" "$VARS_FILE" || true)
  [[ -n $line ]] || { printf '%s' "$def"; return; }
  val=${line#*:}
  val=$(printf '%s' "$val" | sed -E 's/#.*$//; s/[[:space:]]+$//; s/^[[:space:]]+//')
  val=${val#\"}; val=${val%\"}; val=${val#\'}; val=${val%\'}
  if [[ -n $val ]]; then printf '%s' "$val"; else printf '%s' "$def"; fi
}

[[ -f $VARS_FILE ]] || die "找不到变量文件: $VARS_FILE"

ARCH=$(yaml_get containerd_arch amd64)
CV=$(yaml_get containerd_version 2.4.2)
RV=$(yaml_get runc_version 1.5.2)
CNIV=$(yaml_get cni_plugins_version 1.9.1)
CRIV=$(yaml_get crictl_version 1.37.0)
NDV=$(yaml_get nerdctl_version 2.4.2)
INSTALL_ALL_RAW=$(yaml_get containerd_install_all false)
MIRRORS=$(yaml_get download_mirror_prefixes "")

GH=https://github.com
COMPONENTS=(containerd runc cni crictl nerdctl)

# ---------- 组件到包名 / 地址 / 校验方式 ----------
pkg_name() {
  case $1 in
    containerd) printf 'containerd-%s-linux-%s.tar.gz\n' "$CV" "$ARCH" ;;
    runc)       printf 'runc.%s\n' "$ARCH" ;;
    cni)        printf 'cni-plugins-linux-%s-v%s.tgz\n' "$ARCH" "$CNIV" ;;
    crictl)     printf 'crictl-v%s-linux-%s.tar.gz\n' "$CRIV" "$ARCH" ;;
    nerdctl)    printf 'nerdctl-%s-linux-%s.tar.gz\n' "$NDV" "$ARCH" ;;
  esac
}

pkg_url() {
  local name
  name=$(pkg_name "$1")
  case $1 in
    containerd) printf '%s/containerd/containerd/releases/download/v%s/%s\n' "$GH" "$CV" "$name" ;;
    runc)       printf '%s/opencontainers/runc/releases/download/v%s/%s\n' "$GH" "$RV" "$name" ;;
    cni)        printf '%s/containernetworking/plugins/releases/download/v%s/%s\n' "$GH" "$CNIV" "$name" ;;
    crictl)     printf '%s/kubernetes-sigs/cri-tools/releases/download/v%s/%s\n' "$GH" "$CRIV" "$name" ;;
    nerdctl)    printf '%s/containerd/nerdctl/releases/download/v%s/%s\n' "$GH" "$NDV" "$name" ;;
  esac
}

pkg_kind() {
  if [[ $1 == runc ]]; then printf 'elf\n'; else printf 'tar\n'; fi
}

valid_component() {
  local c
  for c in "${COMPONENTS[@]}"; do
    [[ $c == $1 ]] && return 0
  done
  return 1
}

# ---------- 组件开关求值 --------------------------------------
# 三态: 显式 true 装 / 显式 false 不装 / 未指定时跟随 containerd_install_all
ALL_ON=false
if [[ $ALL_ARG -eq 1 || $INSTALL_ALL_RAW == true ]]; then ALL_ON=true; fi

normalize() {
  case ${1:-} in
    true)  printf 'true' ;;
    false) printf 'false' ;;
    *)     if [[ $ALL_ON == true ]]; then printf 'true'; else printf 'false'; fi ;;
  esac
}

declare -A ON
ONLY_TOGGLE=${COMPONENT:-$(yaml_get containerd_install_only "")}
if [[ -n $ONLY_TOGGLE ]]; then
  if valid_component "$ONLY_TOGGLE"; then :; else
    die "组件名非法: $ONLY_TOGGLE (可选 ${COMPONENTS[*]})"
  fi
  for c in "${COMPONENTS[@]}"; do ON[$c]=false; done
  ON[$ONLY_TOGGLE]=true
else
  for c in "${COMPONENTS[@]}"; do
    ON[$c]=$(normalize "$(yaml_get "containerd_install_$c" "")")
  done
fi

# 剧本缺包时通过 --need 传入清单, 覆盖上面的求值结果
if [[ -n $NEED ]]; then
  IFS=', ' read -r -a need_items <<< "$NEED"
  for c in "${need_items[@]}"; do
    [[ -z $c ]] && continue
    if valid_component "$c"; then :; else
      die "--need 取值非法: $c (可选 ${COMPONENTS[*]})"
    fi
    ON[$c]=true
  done
fi

enabled=0
for c in "${COMPONENTS[@]}"; do
  if [[ ${ON[$c]} == true ]]; then enabled=$((enabled+1)); fi
done

if [[ $enabled -eq 0 ]]; then
  log "未启用任何组件, 无需下载安装包."
  log "全量下载: 加 --all, 或将变量文件中的 containerd_install_all 设为 true"
  log "全量下载并排除组件: 加 --all, 并在变量文件中将该组件设为 false"
  log "单个组件: 加 --component <组件名>, 或在变量文件中将对应开关设为 true"
  exit 0
fi

# ---------- 包目录 --------------------------------------------
PKG_DIR=$(yaml_get packages_dir "")
PKG_DIR=${PKG_DIR:-"{{ playbook_dir }}/packages"}
PROJ_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
PKG_DIR=${PKG_DIR//\{\{ playbook_dir \}\}/$PROJ_DIR}
if [[ $PKG_DIR != /* ]]; then PKG_DIR="${PROJ_DIR}/${PKG_DIR}"; fi
mkdir -p "$PKG_DIR"

# ---------- 校验与下载 ----------------------------------------
verify_file() {
  local f=$1 kind=$2
  [[ -s $f ]] || return 1
  case $kind in
    tar) tar -tzf "$f" >/dev/null 2>&1 || return 1 ;;
    elf) if [[ $(head -c 4 "$f" | od -An -c | tr -d ' ') == '177ELF' ]]; then :; else return 1; fi ;;
  esac
  return 0
}

fetch() {
  local url=$1 out=$2 tmp="${2}.part" prefix u ok=0
  local -a prefixes=()
  # 先走加速前缀, 最后直连 GitHub: 国内网络直连 GitHub 通常较慢
  for prefix in $MIRRORS; do prefixes+=("$prefix"); done
  prefixes+=("")
  for prefix in "${prefixes[@]}"; do
    if [[ -z $prefix ]]; then u=$url; else u="${prefix%/}/${url}"; fi
    log "尝试下载: $u"
    if command -v curl >/dev/null 2>&1; then
      if curl -fL --retry 2 --retry-delay 2 --connect-timeout "$CONNECT_TIMEOUT" \
              --max-time "$MAX_TIME" -C - -A 'Mozilla/5.0' -o "$tmp" "$u" 2>/dev/null; then
        ok=1
      fi
    else
      if wget -q -c -T "$CONNECT_TIMEOUT" -O "$tmp" "$u"; then ok=1; fi
    fi
    if [[ $ok -eq 1 ]]; then mv -f "$tmp" "$out"; return 0; fi
    warn "该来源失败: $u"
  done
  rm -f "$tmp"
  return 1
}

# ---------- 主流程 --------------------------------------------
log "变量文件: $VARS_FILE"
log "包目录  : $PKG_DIR"
log "版本信息: containerd=$CV runc=$RV cni=$CNIV crictl=$CRIV nerdctl=$NDV arch=$ARCH"

DONE=0
SKIP=0
FAIL=0

for c in "${COMPONENTS[@]}"; do
  name=$(pkg_name "$c")
  kind=$(pkg_kind "$c")
  dest="$PKG_DIR/$name"

  if [[ ${ON[$c]} != true ]]; then log "已关闭 $c, 跳过: $name"; continue; fi

  if [[ $DRY_RUN -eq 1 ]]; then
    printf '%-42s %s\n' "$name" "$(pkg_url "$c")"
    continue
  fi

  if [[ $FORCE -eq 0 && -f $dest ]] && verify_file "$dest" "$kind"; then
    log "已存在且校验通过, 跳过: $name"
    SKIP=$((SKIP+1)); continue
  fi

  if [[ -f $dest ]] && ! verify_file "$dest" "$kind"; then
    warn "本地文件损坏, 重新下载: $name"
  fi

  log "开始下载: $name"
  if fetch "$(pkg_url "$c")" "$dest" && verify_file "$dest" "$kind"; then
    log "下载完成并校验通过: $name ($(du -h "$dest" | cut -f1))"
    DONE=$((DONE+1))
  else
    warn "下载失败: $name (可手动放置到 $dest, 或更换网络环境后重试)"
    FAIL=$((FAIL+1))
  fi
done

if [[ $DRY_RUN -eq 1 ]]; then exit 0; fi

echo "---------------------------------------------"
log "汇总: 新下载 $DONE 个, 跳过 $SKIP 个, 失败 $FAIL 个"
if [[ $FAIL -gt 0 ]]; then die "仍有 $FAIL 个包未就绪, 请检查网络或手动补齐"; fi
log "全部安装包已就绪, 可执行: ansible-playbook containerd.yml"