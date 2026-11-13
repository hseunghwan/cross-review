# ocr 포크 관리

이 저장소의 두 cross-review 스킬은 업스트림 배포본에 없는 기능을 쓰는 `ocr` 바이너리가
필요하다. 업스트림 소스를 통째로 들고 있지 않고, **기준 태그(`ocr/UPSTREAM`) + 변경분
(`ocr/patches/*.patch`)** 만 저장한다. `ocr/build.sh`가 업스트림을 받아 변경을 얹고 빌드한다.

## 패치 목록

| 패치 | 내용 | 쓰는 스킬 | 업스트림 상황 |
|---|---|---|---|
| `0001-core-command-group.patch` | `ocr core` 명령 그룹(diff, relocate, emit, rule, prompt, template, tools, group, render). LLM 호출 없이 엔진 내부 함수로 결정론적 단계만 노출 | `open-code-review-local` → `cross-review`(v1) | 업스트림에 없음. 비슷한 `ocr delegate`(#383)는 파일 목록·룰만 준다. 더 넓은 출력 계약을 제안한 #986은 거절됨 |
| `0002-anthropic-oauth-provider.patch` | `anthropic-oauth` 프로바이더. LLM 호출 한 번을 `claude -p` 한 번으로 바꿔 Claude Code 구독으로 엔진 모드를 돌림 | `cross-review-v2` | PR #1670(열림, 미머지)을 v1.13.8에 이식. 머지되면 이 패치는 지운다 |

두 패치는 서로 다른 파일만 건드린다(0001: `cmd/opencodereview`, `internal/agent` / 0002:
`internal/llm`, `ocr auth`, 문서). 그래서 적용 순서에 의존하지 않는다.

## 배경

- `ocr core`는 원래 v1.6.6 위에 붙인 사내 배포 포크였다(소스 미보존). v1.13.8로 올리면서
  기존 바이너리의 입출력을 기준으로 다시 구현했다. `relocate` 출력은 기존 바이너리와 바이트 단위로
  같고, 나머지는 하위 호환(필드 추가만)이다.
- `anthropic-oauth`는 Go 엔진의 흐름 제어(그룹핑, Plan, 2회차 Main, REVIEW_FILTER, 비동기 재배치,
  coverage)를 그대로 두고 LLM 호출 지점만 바꾼다. Claude Code는 `--tools ""`로 내장 도구를 끄고
  `--json-schema`로 `{content, tool_calls}` 결정만 돌려준다.

## 자주 하는 일

### 빌드·설치

```bash
ocr/build.sh               # 빌드 후 ~/.local/bin/ocr 에 설치(기존 파일은 ocr-<버전>.bak 으로 백업)
ocr/build.sh --no-install  # 빌드만. 결과: ~/.cache/cross-review/open-code-review/bin/ocr
ocr/build.sh --test        # 설치 전에 go test ./cmd/... ./internal/...
```

Go는 `go.mod`의 버전 이상이 필요하다(v1.13.8 기준 1.26.10). PATH에 없으면 `~/.local/go/bin/go`를 찾는다.

### 업스트림 버전 올리기

1. `ocr/UPSTREAM`의 `tag`와 `commit`을 새 버전으로 바꾼다
   (`git ls-remote https://github.com/alibaba/open-code-review.git refs/tags/<tag>^{}`로 커밋 확인).
2. `ocr/build.sh --no-install --test`를 실행한다.
3. 패치가 깔끔하게 적용되면 끝. 충돌이 나면 아래 "패치 고치기"로 해당 패치를 다시 만든다.
4. 업스트림이 PR #1670을 머지했다면 `0002` 패치를 지우고, `UPSTREAM`의 `version_suffix`에서 `+claude-oauth`를 뺀다.

### 패치 고치기 (소스를 직접 수정하고 싶을 때)

```bash
ocr/build.sh --no-install                     # 캐시에 '기준 태그 + 모든 패치' 상태를 만든다
cd ~/.cache/cross-review/open-code-review
# ... 소스 수정, go test ...
git add -A && git diff --cached HEAD -- <그 패치가 맡는 경로들> > /tmp/new.patch
```

새 diff 앞에 기존 패치의 머리말(Subject, Base 등 설명 부분)을 붙여 `ocr/patches/`의 해당 파일을
교체한 뒤, `ocr/build.sh --no-install`이 처음부터 다시 통과하는지 확인한다. 캐시 디렉터리는
`build.sh`를 실행할 때마다 초기화되니, 고친 내용은 반드시 패치 파일로 옮긴 뒤 다시 빌드한다.

## 라이선스

open-code-review는 Apache-2.0이다. `ocr/patches/`의 변경분과 `skills/open-code-review-local`은
그 파생물이며 같은 라이선스를 따른다. `0002` 패치의 원저작자는 PR #1670 작성자다.
