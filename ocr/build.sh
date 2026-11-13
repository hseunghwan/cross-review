#!/usr/bin/env bash
# 업스트림 open-code-review를 UPSTREAM의 태그로 받아 patches/*.patch를 순서대로 적용하고
# 통합 ocr 바이너리(core + anthropic-oauth)를 빌드·설치한다.
#
#   ocr/build.sh                 빌드 후 ~/.local/bin/ocr 에 설치(기존 파일은 백업)
#   ocr/build.sh --no-install    빌드만(결과: $OCR_SRC/bin/ocr)
#   ocr/build.sh --test          설치 전에 go test ./cmd/... ./internal/... 실행
#
# 환경변수
#   OCR_SRC     소스 캐시 위치(기본 ~/.cache/cross-review/open-code-review).
#               이 디렉터리는 매번 기준 커밋으로 강제 초기화된다 — 작업 중인 클론을 지정하지 말 것.
#   PREFIX      설치 위치(기본 ~/.local/bin)
#   GO          go 실행 파일(기본: PATH의 go, 없으면 ~/.local/go/bin/go)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091
source <(grep -E '^[a-z_]+=' "$HERE/UPSTREAM")
: "${repo:?}" "${tag:?}" "${commit:?}" "${version_suffix:=}"

OCR_SRC="${OCR_SRC:-$HOME/.cache/cross-review/open-code-review}"
PREFIX="${PREFIX:-$HOME/.local/bin}"
INSTALL=1 RUN_TESTS=0
for arg in "$@"; do
  case "$arg" in
    --no-install) INSTALL=0 ;;
    --test) RUN_TESTS=1 ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "알 수 없는 인자: $arg" >&2; exit 2 ;;
  esac
done

GO="${GO:-$(command -v go || true)}"
[ -z "$GO" ] && [ -x "$HOME/.local/go/bin/go" ] && GO="$HOME/.local/go/bin/go"
[ -n "$GO" ] || { echo "FATAL: go가 없습니다. https://go.dev/dl 에서 설치하세요(go.mod의 go 버전 이상)." >&2; exit 1; }
export PATH="$(dirname "$GO"):$PATH"

echo "==> 소스 준비: $OCR_SRC ($tag)"
if [ ! -d "$OCR_SRC/.git" ]; then
  mkdir -p "$(dirname "$OCR_SRC")"
  git clone --quiet --filter=blob:none --no-checkout "$repo" "$OCR_SRC"
fi
git -C "$OCR_SRC" fetch --quiet --force origin "refs/tags/$tag:refs/tags/$tag"
git -C "$OCR_SRC" checkout --quiet --force --detach "$commit"
git -C "$OCR_SRC" clean --quiet -fd
actual="$(git -C "$OCR_SRC" rev-parse HEAD)"
[ "$actual" = "$commit" ] || { echo "FATAL: $tag 가 $actual 을 가리킴(기대: $commit). UPSTREAM을 확인하세요." >&2; exit 1; }
tag_commit="$(git -C "$OCR_SRC" rev-parse "$tag^{commit}")"
[ "$tag_commit" = "$commit" ] || { echo "FATAL: 태그 $tag($tag_commit)와 UPSTREAM commit($commit)이 다릅니다." >&2; exit 1; }

echo "==> 패치 적용"
shopt -s nullglob
patches=("$HERE"/patches/*.patch)
[ ${#patches[@]} -gt 0 ] || { echo "FATAL: patches/*.patch 가 없습니다." >&2; exit 1; }
for p in "${patches[@]}"; do
  echo "    $(basename "$p")"
  git -C "$OCR_SRC" apply --index --whitespace=nowarn "$p"
done

if [ "$RUN_TESTS" = 1 ]; then
  echo "==> 테스트 (go test ./cmd/... ./internal/...)"
  (cd "$OCR_SRC" && LC_ALL=C "$GO" test ./cmd/... ./internal/...)
fi

version="${tag}${version_suffix}"
echo "==> 빌드: $version"
(cd "$OCR_SRC" && "$GO" build \
  -ldflags "-X main.Version=$version -X main.GitCommit=${commit:0:7} -X main.BuildDate=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  -o bin/ocr ./cmd/opencodereview)
BIN="$OCR_SRC/bin/ocr"

if [ "$INSTALL" = 1 ]; then
  mkdir -p "$PREFIX"
  dest="$PREFIX/ocr"
  if [ -e "$dest" ] && ! cmp -s "$BIN" "$dest"; then
    old="$("$dest" --version 2>/dev/null | head -1 | awk '{print $2}' || true)"
    backup="$dest-${old:-old}.bak"
    [ -e "$backup" ] || { cp -p "$dest" "$backup"; echo "==> 기존 ocr 백업: $backup"; }
  fi
  install -m 755 "$BIN" "$dest"
  BIN="$dest"
  echo "==> 설치: $dest"
fi

echo "==> 검증"
"$BIN" --version | head -1
"$BIN" core template >/dev/null || { echo "FATAL: ocr core 동작 안 함" >&2; exit 1; }
echo "    ocr core: OK"
# 출력을 먼저 받아 두고 검사한다. pipefail 아래에서 `| grep -q`는 grep이 먼저 끝나면
# ocr이 SIGPIPE로 죽어 파이프 전체가 실패로 잡힐 수 있다.
providers="$("$BIN" llm providers 2>/dev/null || true)"
grep -q '^ *anthropic-oauth ' <<<"$providers" || { echo "FATAL: anthropic-oauth 프로바이더 없음" >&2; exit 1; }
echo "    anthropic-oauth: OK"
