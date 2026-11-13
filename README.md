# cross-review

**서로 다른 두 코드리뷰 엔진**을 같은 로컬 변경에 각각 돌리고, 결과를 병합해
**"두 엔진이 함께 지적한 항목(고신뢰)"** 과 **"한쪽만 지적한 항목(상대 엔진의 사각지대)"** 으로
태깅한 단일 리포트를 내는 Claude Code 스킬 모음. MR 보내기 전 로컬 워킹트리를 교차 검증하는 용도.

별도 LLM API 키 없이 **Claude Code 구독**만으로 동작한다.

## 구성

| 스킬 | 역할 |
|---|---|
| [`cross-review`](skills/cross-review/SKILL.md) (v1) | `ce-code-review` × `open-code-review-local` |
| [`cross-review-v2`](skills/cross-review-v2/SKILL.md) (v2) | `ce-code-review` × `ocr review`(엔진 모드, `anthropic-oauth`) |
| [`open-code-review-local`](skills/open-code-review-local/SKILL.md) | v1의 엔진 B. `ocr core`를 도구로 Claude가 ocr v1.13.8 파이프라인을 따라감 |

엔진 B에 쓰는 `ocr`는 업스트림 [alibaba/open-code-review](https://github.com/alibaba/open-code-review)
v1.13.8에 패치 두 개를 얹은 포크 빌드다([`ocr/`](ocr/), [포크 관리 문서](docs/ocr-fork.md)).

## 왜 교차 검증인가

두 엔진은 룰셋과 검토 방식이 다르다.

- **ce-code-review** — 페르소나 리뷰어 + 프로젝트 표준(`AGENTS.md`/`CLAUDE.md`) 기반
- **open-code-review** — 언어별 룰 체크리스트 + 파일 그룹핑·Plan·다회차 리뷰·REVIEW_FILTER 파이프라인

사각지대가 다르기 때문에, 둘 다 잡으면 신뢰도가 높고 한쪽만 잡으면 상대 엔진이 놓친 지점을
드러낸다. 병합·합의 판정은 **신선한 격리 서브에이전트**가 해서, 방금 코딩한 세션에서 이어
돌려도 판정이 작업 맥락에 오염되지 않는다.

## v1과 v2

| | v1 `cross-review` | v2 `cross-review-v2` |
|---|---|---|
| 엔진 B | `open-code-review-local` 스킬 (`ocr core` + Claude가 절차를 따라감) | `ocr review` 엔진 모드 그대로 (Go가 흐름 제어) |
| 엔진 B의 LLM | Claude Code 서브에이전트 | `claude -p` 프로세스 (`anthropic-oauth` 프로바이더) |
| 흐름 준수 | 스킬 지시를 Claude가 따르는 데 의존 | 엔진 코드가 강제 |
| 엔진 B 출력 | Claude가 쓴 코멘트 → 정규화 | 엔진 JSON 계약(`comments[]`, `severity`, `category`, `manifest`) |
| 엔진 실행 | 순차 | 병렬 (엔진 B는 백그라운드 단일 프로세스) |
| 필요한 패치 | `0001` (ocr core) | `0002` (anthropic-oauth, 업스트림 PR #1670 미머지) |

공통: 임시 인덱스 스냅샷(미추적 파일 포함, 워킹트리·인덱스 불변), ce는 `mode:agent depth:full`,
리포트는 MR 댓글에 그대로 붙일 수 있는 블록 형식.

## 사전 요구사항

- **Claude Code** — Pro/Max/Team 구독으로 로그인(`claude auth status --json`의 `authMethod`가 `claude.ai`).
- **Go** — `ocr` 빌드용. `go.mod` 버전 이상(현재 1.26.10). PATH에 없으면 `~/.local/go`도 찾는다.
- **`ce-code-review` 스킬** — compound-engineering 플러그인. 설치된 버전을 그대로 호출한다.
  없으면 ocr 단독으로 동작(리포트에 명시).
- 로컬 git 저장소.

## 설치

```bash
git clone https://github.com/hseunghwan/cross-review.git ~/src/cross-review
cd ~/src/cross-review
./install.sh --with-ocr      # 스킬 3개 링크 + ocr 빌드·설치(기존 ~/.local/bin/ocr 은 백업)

# v2 1회 설정: 기본 프로바이더는 그대로 두고 anthropic-oauth 섹션만 추가
ocr config set providers.anthropic-oauth.model sonnet   # 또는 opus
```

Claude Code에서 `/reload-skills` 후 `/cross-review`, `/cross-review-v2`가 보이면 완료.
`install.sh`는 같은 이름의 기존 스킬을 `~/.claude/skills/.trash/`로 옮겨 백업한다.

## 사용법

로컬에서 작업한 뒤, MR을 보내기 전에:

```
/cross-review              # v1: 현재 브랜치 vs 자동 감지 base
/cross-review-v2           # v2
/cross-review-v2 base:dev  # diff base 명시 (v1도 같음)
/cross-review-v2 model:opus  # v2 엔진 B 모델 지정
/cross-review fix          # 리포트 후, 수정 범위를 상의해 적용 (v2도 같음)
```

로컬 워킹트리 전용이다. PR을 교차 검증하려면 먼저 `glab mr checkout <id>`(또는
`gh pr checkout`)로 체크아웃한 뒤 실행한다.

## 동작 개요

```
Step 1  스코프 산정   base 확정 + 임시 인덱스로 워킹트리 스냅샷 커밋 WT 생성(워킹트리·인덱스 불변)
Step 2  엔진 실행     A: ce-code-review mode:agent depth:full base:BASE
                     B: v1 open-code-review-local (ocr core, REVIEW_FILTER on)
                        v2 ocr review --from BASE --to WT --provider anthropic-oauth (백그라운드, A와 병렬)
Step 3  정규화        공통 스키마(P0~P3) — ocr critical/high/medium/low → P0/P1/P2/P3
Step 4  adjudicator   신선 격리 서브에이전트가 병합·합의 판정(미추적 파일 지적은 제외)
Step 5  리포트        ★합의 / ce 단독 / ocr 단독 / ce 범위 밖(미추적) 한국어 리포트
```

한 엔진이 실패해도 중단하지 않고 나머지 엔진 결과로 리포트한다.

## 주의사항

- **미추적 파일:** ce-code-review는 `base:` 모드에서 미추적 파일을 보지 않는다. 그 파일에 대한
  ocr 지적은 "ce 범위 밖" 구역으로 따로 나온다. 양쪽 교차가 필요하면 `git add` 후 재실행한다.
- **사용량:** v2 엔진 B는 LLM 호출마다 `claude -p`를 띄운다(호출당 수 초). 스킬은 `--concurrency 2`를
  쓰고, ce와 병렬로 돌아 사용량이 한꺼번에 몰린다. 큰 diff는 나눠서 리뷰하는 편이 안전하다.
  참고 측정: 4개 파일 +38줄에 23초, 약 58k 토큰(sonnet).
- **이용 정책:** 공식 Claude Code CLI를 본인 로컬에서 대화형으로 쓰는 용도를 전제로 한다.
  CI 같은 무인 실행이나 여러 사람이 함께 쓰는 서비스로 돌리기 전에는 Anthropic 이용 정책을 확인한다.
- **데이터:** 리뷰를 위해 소스와 diff가 Claude Code 구독 경로로 전송된다. 기밀 코드는 조직 정책을 먼저 확인한다.
- **포크 의존:** 두 스킬 모두 업스트림 배포본(npm 등)의 `ocr`로는 동작하지 않는다. 반드시 `ocr/build.sh`로 빌드한 바이너리를 쓴다.

## 디렉터리 구조

```
cross-review/
├── install.sh                 스킬 링크 (+ --with-ocr: ocr 빌드·설치)
├── skills/
│   ├── cross-review/          v1
│   ├── cross-review-v2/       v2
│   └── open-code-review-local/
├── ocr/
│   ├── UPSTREAM               업스트림 기준 태그·커밋
│   ├── patches/               0001 ocr core, 0002 anthropic-oauth (PR #1670)
│   └── build.sh               업스트림 클론 → 패치 적용 → 빌드 → 설치
└── docs/
    ├── DESIGN-v1.md, PLAN-v1.md
    ├── DESIGN-v2.md
    └── ocr-fork.md            포크 배경, 업스트림 버전 올리기, 패치 고치기
```

## 라이선스

`ocr/patches/`와 `skills/open-code-review-local`은 open-code-review(Apache-2.0)의 파생물로
같은 라이선스를 따른다. 자세한 내용은 [docs/ocr-fork.md](docs/ocr-fork.md).
