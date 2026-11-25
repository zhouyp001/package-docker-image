#!/usr/bin/env bash
# =============================================================================
# package-release.sh
# 流程: docker pull -> docker save (tar/tar.gz) -> 发布到 GitHub Release
#
# 用法示例:
#   ./scripts/package-release.sh -i nginx:1.25.3 -r owner/repo
#   ./scripts/package-release.sh            # 交互式输入镜像地址
#
# 未指定 --tag 时，发布 tag 默认使用镜像地址本身（已 sanitize 成合法 Git tag），
# 例如 quay.io/keycloak/keycloak:latest -> quay.io_keycloak_keycloak_latest
# =============================================================================
set -euo pipefail

# ---------- 日志 ----------
if [[ -t 1 ]]; then
  C_RED=$'\033[0;31m'; C_GREEN=$'\033[0;32m'; C_YELLOW=$'\033[1;33m'; C_RESET=$'\033[0m'
else
  C_RED=''; C_GREEN=''; C_YELLOW=''; C_RESET=''
fi
log()  { printf '%s[INFO]%s  %s\n'  "$C_GREEN"  "$C_RESET" "$*"; }
warn() { printf '%s[WARN]%s  %s\n'  "$C_YELLOW" "$C_RESET" "$*"; }
err()  { printf '%s[ERROR]%s %s\n'  "$C_RED"    "$C_RESET" "$*" >&2; }
die()  { err "$*"; exit 1; }

# ---------- 默认参数 ----------
IMAGE=""
RELEASE_TAG=""
REPO="${GITHUB_REPOSITORY:-}"
OUTPUT_DIR="./dist"
MODE="github-release"        # github-release | local
COMPRESS="true"
PLATFORM=""
DRY_RUN="false"
NOTES=""

ARCHIVE=""
PARTIAL_FILE=""

usage() {
  cat <<'EOF'
用法: package-release.sh [选项]

选项:
  -i, --image <ref>        镜像地址, 如 registry.example.com/app:1.2.3
                           (不传则交互式输入)
  -t, --tag <tag>          GitHub Release tag, 默认使用镜像地址本身
                           (sanitize 后, 如 quay.io/keycloak/keycloak:latest
                            -> quay.io_keycloak_keycloak_latest)
  -r, --repo <owner/repo>  目标仓库, 默认 $GITHUB_REPOSITORY 或当前仓库
  -o, --output-dir <dir>   打包输出目录, 默认 ./dist
  -m, --mode <mode>        发布方式: github-release | local, 默认 github-release
      --platform <p>       docker pull 的平台, 如 linux/amd64
      --no-compress        不压缩, 直接输出 .tar
      --notes <text>       Release 说明
      --dry-run            只拉取与打包, 不上传
  -h, --help               显示帮助

环境变量:
  GH_TOKEN / GITHUB_TOKEN  发布到 GitHub Release 时使用
EOF
}

# ---------- 参数解析 ----------
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -i|--image)      IMAGE="${2:?-i/--image 缺少参数}";       shift 2 ;;
      -t|--tag)
        if [[ -n "${2:-}" ]]; then
          RELEASE_TAG="$2"; shift 2
        else
          shift
        fi
        ;;
      -r|--repo)       REPO="${2:?-r/--repo 缺少参数}";         shift 2 ;;
      -o|--output-dir) OUTPUT_DIR="${2:?-o/--output-dir 缺少参数}"; shift 2 ;;
      -m|--mode)       MODE="${2:?-m/--mode 缺少参数}";         shift 2 ;;
      --platform)      PLATFORM="${2:?--platform 缺少参数}";    shift 2 ;;
      --notes)
        if [[ -n "${2:-}" ]]; then
          NOTES="$2"; shift 2
        else
          shift
        fi
        ;;
      --no-compress)   COMPRESS="false"; shift ;;
      --dry-run)       DRY_RUN="true";   shift ;;
      -h|--help)       usage; exit 0 ;;
      *) die "未知参数: $1 (使用 -h 查看帮助)" ;;
    esac
  done

  [[ "$MODE" =~ ^(github-release|local)$ ]] || die "--mode 只能是 github-release 或 local"
}

# ---------- 工具函数 ----------
require_cmd() { command -v "$1" >/dev/null 2>&1 || die "缺少依赖命令: $1"; }

# 镜像名转安全字符串（用于文件名 / Release tag）
# quay.io/keycloak/keycloak:latest -> quay.io_keycloak_keycloak_latest
sanitize_name() {
  printf '%s' "$1" | sed -e 's|[@:]|_|g' -e 's|/|_|g'
}

# 将镜像地址转换为合法的 GitHub Release tag
# 未指定 --tag 时使用。digest 形式会附加 sha 前缀短摘要。
image_to_tag() {
  local ref="$1"
  if [[ "$ref" == *"@sha256:"* ]]; then
    local base="${ref%%@*}"
    local digest="${ref##*@sha256:}"
    printf '%s-sha%s' "$(sanitize_name "$base")" "${digest:0:12}"
    return
  fi
  sanitize_name "$ref"
}

hash_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    die "缺少 sha256sum/shasum，无法计算校验和"
  fi
}

# 注意：EXIT trap 的返回值会覆盖脚本退出码，
# 因此必须保证 cleanup 在无临时文件时也返回 0。
cleanup() {
  if [[ -n "${PARTIAL_FILE:-}" && -f "$PARTIAL_FILE" ]]; then
    rm -f "$PARTIAL_FILE"
  fi
  return 0
}
trap cleanup EXIT

# ---------- 各步骤 ----------
collect_inputs() {
  if [[ -z "$IMAGE" ]]; then
    if [[ -t 0 ]]; then
      read -r -p "请输入镜像地址 (例如 nginx:1.25.3): " IMAGE
    else
      die "非交互环境请使用 --image 指定镜像地址"
    fi
  fi
  [[ -n "$IMAGE" ]] || die "镜像地址不能为空"

  # 未指定 --tag 时，直接使用镜像地址作为发布 tag
  if [[ -z "$RELEASE_TAG" ]]; then
    RELEASE_TAG="$(image_to_tag "$IMAGE")"
  fi
  # 兜底（正常不会触发）
  [[ -n "$RELEASE_TAG" ]] || RELEASE_TAG="$(date +%Y%m%d-%H%M%S)"

  log "镜像地址 : $IMAGE"
  log "Release  : $RELEASE_TAG"
  log "发布方式 : $MODE"
}

check_deps() {
  require_cmd docker
  if [[ "$MODE" == "github-release" && "$DRY_RUN" != "true" ]]; then
    require_cmd gh
  fi
}

resolve_repo() {
  [[ "$MODE" == "github-release" ]] || return 0
  [[ "$DRY_RUN" == "true" ]] && return 0

  if [[ -z "$REPO" ]]; then
    REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
  fi
  [[ -n "$REPO" ]] || die "无法推断仓库，请用 --repo owner/repo 指定"
  log "目标仓库 : $REPO"
}

pull_image() {
  local args=(pull)
  [[ -n "$PLATFORM" ]] && args+=(--platform "$PLATFORM")
  args+=("$IMAGE")

  log "拉取镜像: docker ${args[*]}"
  if ! docker "${args[@]}"; then
    local registry="${IMAGE%%/*}"
    # 镜像名里不含 registry 时，registry 就是 docker.io
    [[ "$registry" != *.* && "$registry" != *:* && "$registry" != "localhost" ]] && registry="docker.io"

    err "拉取镜像失败。常见原因:"
    err "  1. 镜像是私有的，但未登录 registry '$registry'"
    err "     本地:  docker login $registry"
    err "     CI  :  在 pull 前执行 docker login $registry --password-stdin"
    err "  2. 账号无该镜像的访问权限"
    err "  3. 镜像 tag 不存在或已删除"
    die "请检查后重试"
  fi
}

package_image() {
  mkdir -p "$OUTPUT_DIR"

  local name; name="$(sanitize_name "$IMAGE")"
  if [[ "$COMPRESS" == "true" ]]; then
    ARCHIVE="$OUTPUT_DIR/${name}.tar.gz"
  else
    ARCHIVE="$OUTPUT_DIR/${name}.tar"
  fi

  [[ -f "$ARCHIVE" ]] && warn "将覆盖已存在的文件: $ARCHIVE"
  PARTIAL_FILE="${ARCHIVE}.part"

  log "开始打包镜像 -> $ARCHIVE"
  if [[ "$COMPRESS" == "true" ]]; then
    local comp="gzip -9"
    command -v pigz >/dev/null 2>&1 && comp="pigz -9"
    docker save "$IMAGE" | $comp > "$PARTIAL_FILE"
  else
    docker save "$IMAGE" -o "$PARTIAL_FILE"
  fi
  mv "$PARTIAL_FILE" "$ARCHIVE"
  PARTIAL_FILE=""

  local size; size="$(du -h "$ARCHIVE" | awk '{print $1}')"
  log "打包完成: $ARCHIVE ($size)"
}

gen_checksum() {
  log "计算 SHA256..."
  HASH="$(hash_file "$ARCHIVE")"
  printf '%s  %s\n' "$HASH" "$(basename "$ARCHIVE")" > "${ARCHIVE}.sha256"
  log "SHA256   : $HASH"
}

publish() {
  if [[ "$DRY_RUN" == "true" ]]; then
    warn "--dry-run 已启用，跳过发布"
    return 0
  fi

  case "$MODE" in
    local)
      log "本地模式，产物已生成:"
      log "  $ARCHIVE"
      log "  ${ARCHIVE}.sha256"
      ;;
    github-release)
      publish_github_release
      ;;
  esac
}

publish_github_release() {
  gh auth status >/dev/null 2>&1 \
    || die "gh 未认证，请先执行 'gh auth login' 或设置 GH_TOKEN 环境变量"

  local digest
  digest="$(docker inspect --format '{{index .RepoDigests 0}}' "$IMAGE" 2>/dev/null || true)"

  local notes="$NOTES"
  if [[ -z "$notes" ]]; then
    notes=$(cat <<EOF
## Docker Image Package

| 项目 | 值 |
| --- | --- |
| Image | \`$IMAGE\` |
| Digest | \`${digest:-n/a}\` |
| Release Tag | \`$RELEASE_TAG\` |
| File | \`$(basename "$ARCHIVE")\` |
| SHA256 | \`$HASH\` |

### 使用方式
\`\`\`bash
# 下载后校验
sha256sum -c $(basename "$ARCHIVE").sha256

# 加载镜像
docker load -i $(basename "$ARCHIVE")
\`\`\`
EOF
)
  fi

  local assets=("$ARCHIVE" "${ARCHIVE}.sha256")

  if gh release view "$RELEASE_TAG" --repo "$REPO" >/dev/null 2>&1; then
    warn "Release '$RELEASE_TAG' 已存在，追加/覆盖资产"
    gh release upload "$RELEASE_TAG" "${assets[@]}" --repo "$REPO" --clobber
  else
    log "创建 Release '$RELEASE_TAG' 并上传资产"
    gh release create "$RELEASE_TAG" "${assets[@]}" \
      --repo "$REPO" \
      --title "$RELEASE_TAG" \
      --notes "$notes"
  fi

  log "发布完成: https://github.com/$REPO/releases/tag/$RELEASE_TAG"
}

# 注意：summary 是 main 的最后一条命令，
# 必须显式 return 0，否则条件为假时会以 1 退出。
summary() {
  printf '\n'
  log "====== 完成 ======"
  log "镜像     : $IMAGE"
  log "Release  : $RELEASE_TAG"
  if [[ -n "${ARCHIVE:-}" && -f "$ARCHIVE" ]]; then
    log "产物     : $ARCHIVE"
  fi
  return 0
}

# ---------- 主流程 ----------
main() {
  parse_args "$@"
  collect_inputs
  check_deps
  resolve_repo
  pull_image
  package_image
  gen_checksum
  publish
  summary
  exit 0   # 显式声明成功，避免 EXIT trap 返回值影响退出码
}

main "$@"