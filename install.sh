#!/usr/bin/env bash
# skills/ 아래 스킬들을 ~/.claude/skills/<이름> 에 심볼릭 링크로 설치한다.
# 같은 이름의 기존 디렉터리·다른 곳을 가리키는 링크는 ~/.claude/skills/.trash/ 로 옮겨 백업한다.
#
#   ./install.sh              스킬 링크만
#   ./install.sh --with-ocr   스킬 링크 + ocr/build.sh(통합 ocr 빌드·설치)
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SKILLS_DIR="${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"
WITH_OCR=0
for arg in "$@"; do
  case "$arg" in
    --with-ocr) WITH_OCR=1 ;;
    -h|--help) sed -n '2,7p' "$0"; exit 0 ;;
    *) echo "알 수 없는 인자: $arg" >&2; exit 2 ;;
  esac
done

mkdir -p "$SKILLS_DIR"
BACKUP="$SKILLS_DIR/.trash/backup-$(date +%Y%m%d-%H%M%S)"

for src in "$REPO"/skills/*/; do
  src="${src%/}"
  [ -f "$src/SKILL.md" ] || continue
  name="$(basename "$src")"
  dest="$SKILLS_DIR/$name"
  if [ -L "$dest" ] && [ "$(cd "$dest" 2>/dev/null && pwd -P)" = "$src" ]; then
    echo "  = $name (이미 연결됨)"
    continue
  fi
  if [ -e "$dest" ] || [ -L "$dest" ]; then
    mkdir -p "$BACKUP"
    mv "$dest" "$BACKUP/$name"
    echo "  ↻ $name: 기존 것을 $BACKUP/$name 로 백업"
  fi
  ln -s "$src" "$dest"
  echo "  + $name → $src"
done

if [ "$WITH_OCR" = 1 ]; then
  "$REPO/ocr/build.sh"
fi

echo
command -v ocr >/dev/null && ocr core template >/dev/null 2>&1 \
  || echo "참고: cross-review(v1)에는 ocr core가 필요합니다 → ./install.sh --with-ocr"
# pipefail 아래 `| grep -q`의 SIGPIPE 오판을 피하려고 출력을 먼저 받는다.
providers="$( (command -v ocr >/dev/null && ocr llm providers 2>/dev/null) || true)"
grep -q '^ *anthropic-oauth ' <<<"$providers" \
  || echo "참고: cross-review-v2에는 anthropic-oauth 프로바이더가 필요합니다 → ./install.sh --with-ocr"
grep -q '"anthropic-oauth"' "$HOME/.opencodereview/config.json" 2>/dev/null \
  || echo "참고: cross-review-v2 1회 설정 → ocr config set providers.anthropic-oauth.model sonnet"
echo "완료. Claude Code에서 /reload-skills 후 사용하세요."
