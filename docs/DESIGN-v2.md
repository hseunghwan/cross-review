# `/cross-review-v2` 설계 문서

- **작성일:** 2026-11-13
- **상태:** 구현 완료, E2E(스킬 전체 실행) 미검증. 엔진 B 단독 실사용 검증 완료.
- **배경:** v1 `cross-review`의 엔진 B는 `ocr core`(v1.6.6 기반 포크)로 원본 프롬프트와
  도구를 꺼내 Claude가 SKILL.md 절차대로 리뷰를 재구성했다. 원본 엔진의 설계 원칙
  ("Deterministic Engineering × Agent Hybrid") 중 결정론적 **도구**는 옮겼지만 결정론적
  **흐름 제어**는 자연어 지시로 바뀌어 있었다. 업스트림 PR #1670(`anthropic-oauth`)은
  엔진의 `llm.Client`만 `claude -p` 호출로 바꿔, 흐름 제어를 Go 엔진에 남긴 채 Claude 구독을
  쓸 수 있게 한다. v2는 이 경로를 엔진 B로 쓴다.

---

## 1. 목적

로컬 변경을 서로 다른 룰셋·파이프라인을 가진 두 리뷰 엔진으로 각각 독립 검토하고,
병합·태깅해 고신뢰 항목과 사각지대 신호를 구분한 단일 리포트를 만든다(v1과 동일).
v2의 추가 목표:

1. 엔진 B를 **원본 엔진 모드 그대로** 쓴다(그룹핑, Plan, 다회차, REVIEW_FILTER, 재배치,
   coverage를 엔진이 강제). 업스트림 엔진 개선을 패치 재적용만으로 따라간다.
2. 엔진 B 결과를 **엔진의 JSON 계약**으로 받는다(텍스트 재구성 없음).
3. 두 엔진을 **병렬**로 돌린다.

## 2. 엔진 B 동작 (PR #1670)

```
ocr review (Go 엔진, 흐름 제어 그대로)
  └─ llm.Client = ClaudeOAuthClient
       각 LLM 호출마다:
       1) claude auth status --json  → authMethod == "claude.ai" 확인
       2) system 메시지 → --system-prompt-file, 나머지 대화+도구 정의 → stdin JSON
       3) claude -p --tools "" --json-schema '{content(≤400자), tool_calls[{name(enum), arguments}]}'
                    --no-session-persistence --setting-sources "" --strict-mcp-config ...
       4) structured_output → ChatResponse{tool_calls}
  엔진이 도구(file_read, code_search, code_comment, task_done …)를 실행하고 다음 호출에 결과를 붙인다.
```

- Claude Code의 내장 도구는 전부 끈다. Claude는 "다음 행동을 고르는 모델"로만 쓰인다.
- 대화는 매 호출마다 전체를 다시 보내지만 앞부분이 고정이라 서버 프롬프트 캐시가 맞는다
  (측정에서 `cache_read_tokens` 확인).
- `content` 400자 제한은 "이슈를 산문으로 쓰고 `task_done`만 호출해 이슈가 사라지는" 버그(#1670
  리뷰 중 발견)를 스키마로 막는 장치다.

## 3. 아키텍처 / 데이터 흐름

```
/cross-review-v2 [base:<ref>] [model:<alias>] [fix]
        │
   [1. 스코프] BASE = merge-base, WT = 임시 인덱스 스냅샷 커밋(미추적 포함), UNTRACKED 목록
        │
   ┌────┴─────────────────────────────────────────────────────────────┐
   │ [2B] ocr review --from BASE --to WT --provider anthropic-oauth   │  백그라운드 Bash
   │      --format json --audience agent --concurrency 2 --output F   │
   │ [2A] ce-code-review mode:agent depth:full base:BASE              │  Skill (동시에)
   └────┬─────────────────────────────────────────────────────────────┘
        │
   [3. 정규화] P0~P3 통일, ocr category 보존, untracked 플래그
        │
   [4. adjudicator]  ★신선 격리 서브에이전트★  (untracked ocr 항목은 입력에서 제외)
        │   출력: {agreed[], ce_only[], ocr_only[], counts}
        │
   [5. 리포트] 합의 / ce 단독 / ocr 단독 / ce 범위 밖(미추적)
```

## 4. 결정과 근거

### 4.1 스냅샷: `git stash create` → 임시 인덱스 + `commit-tree`
- `stash create`는 추적 파일만 담는다. 새로 만든 파일을 아직 `git add`하지 않은 상태가
  MR 직전 로컬에서 흔하다. 엔진 B(`ocr review --to <sha>`)는 커밋을 받으므로, 미추적 파일까지
  담은 커밋을 만들어 넘긴다.
- `GIT_INDEX_FILE`을 `$( )` 서브셸 안에서만 바꿔 실제 `.git/index`와 워킹트리를 건드리지 않는다.
  `git add -A`는 `.gitignore`를 존중한다. 스냅샷은 dangling 커밋이라 `gc`가 정리한다.
- 검증: staged, unstaged, 미추적 파일이 모두 스냅샷에 들어가고, 무시 대상 파일은 빠지며,
  실행 전후 `git write-tree`와 `git status --porcelain`이 같음을 샘플 저장소에서 확인.
- `--to <임의 커밋 SHA>`: 엔진이 `merge-base(BASE, WT)..WT` 범위로 해석함을 확인
  (`manifest.input.mode = range`, `exact_range = <base>..<WT>`).

### 4.2 미추적 파일 비대칭 처리
- ce-code-review는 `base:` 모드에서 `UNTRACKED:`를 **범위 밖**으로 두고 Coverage에만 적는다.
  엔진 B만 미추적 파일을 리뷰하므로, 그 지적을 `ocr_only`에 넣으면 "ce 사각지대"로 오독된다.
- 그래서 `file ∈ UNTRACKED`인 ocr 항목은 adjudicator 입력에서 빼고 "ce 범위 밖" 구역으로 분리한다.
  사용자는 `git add` 후 재실행해 양쪽 교차를 받을 수 있다.
- 대안(스냅샷에서 미추적 파일 제외 = v1과 동일 범위)도 가능하지만, 미추적 파일 리뷰를 아예
  잃는 것보다 구역 분리가 낫다고 판단.

### 4.3 ce `depth:full`
- 설치된 ce-code-review(3.33.0)에서 `mode:agent`는 quick-review 단축만 우회한다. 깊이 게이트가
  lite를 고르면 **호출한 컨텍스트(메인 대화) 단독**으로 리뷰한다. 메인 대화는 방금 코딩한 작업
  세션일 수 있으므로 독립성 전제가 깨진다. `depth:full`로 다중 에이전트 경로를 강제한다.
- 비용은 늘지만 교차 검증의 전제(각 엔진의 리뷰가 작업 맥락에 오염되지 않음)가 우선이다.

### 4.4 병렬 실행
- v1은 두 엔진이 모두 오케스트레이터의 서브에이전트 슬롯을 크게 쓰므로 순차였다.
- v2 엔진 B는 서브에이전트가 아니라 OS 프로세스(`ocr` + `claude -p` 자식)다. 슬롯 경합이 없고
  경합 대상은 구독 사용량뿐이다. 엔진 B를 백그라운드 Bash로 먼저 띄우고 ce를 돌린 뒤 완료
  알림을 기다린다. `--concurrency 2`로 동시 `claude -p` 수를 제한한다.
- 순서 오염 없음: 엔진 B는 별도 프로세스, ce 리뷰어는 격리 leaf 서브에이전트(`depth:full`).

### 4.5 정규화
- ocr severity: `critical→P0`, `high→P1`, `medium→P2`, `low→P3`. v1(`ocr core`)은 low를 버렸지만
  엔진 모드는 low도 REVIEW_FILTER를 통과한 지적이라 보존한다.
- `category`(bug/security/…)는 ocr에만 있으므로 리포트의 ocr 구역에 열로 보인다.
- `existing_code`, `thinking`은 adjudicator 입력에서 뺀다.

### 4.6 엔진 B 결과 해석
- 종료 코드는 선택된 항목이 **전부** 실패할 때만 0이 아니다(부분 결과 게시).
- `status`(= `manifest.terminal_state`): `complete` | `partial` | `failed` | `skipped`.
  `partial`은 전체 실패가 아니라 coverage 저하로 다룬다(`manifest.coverage.failed[]` 표시).

### 4.7 사용자 설정 불간섭
- 스킬은 `ocr config`를 쓰지 않는다. 사용자가 1회 `providers.anthropic-oauth.model`만 추가하고,
  스킬은 매번 `--provider anthropic-oauth`로 지정한다. 기본 프로바이더는 그대로다.

## 5. 검증 결과 (엔진 B 단독, 2026-11-13)

샘플 저장소(파일 4개, +38줄: SQL 인젝션, 하드코딩 시크릿, 출금 검증 누락, 비원자적 이체,
`int(None)`, 빈 리스트 평균. `src/config.py`는 미추적 파일), sonnet, `--concurrency 2`:

| 항목 | 값 |
|---|---|
| 결과 | `status: complete`, 종료 코드 0, coverage 4/4 |
| 시간 | 23초 (프로세스 전체 26초) |
| 토큰 | 58,040 (input 55,846 / output 2,194 / cache read 23,893 / cache write 31,937) |
| 코멘트 | 7개 — critical 2(SQL 인젝션, 하드코딩 시크릿), high 1, medium 3, low 1. 심어 둔 버그 전부 검출 |
| 그룹핑 | 소스 3개 파일 1그룹 + `.gitignore` 1그룹 |
| 미추적 파일 | `src/config.py` 지적 3건 (스냅샷 경유로 리뷰됨) |

JSON 최상위 필드: `status`, `llm{provider,model}`, `message`, `summary{files_reviewed, comments,
total_tokens, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, elapsed}`,
`tool_calls`, `comments[]{path, content, suggestion_code, existing_code, start_line, end_line,
category, severity}`, `groups[]{label, files}`, `session_id`, `manifest{input, execution, coverage{selected,
completed, reused, failed, waived}, terminal_state}`.

Claude Code 세션 안의 Bash에서 실행해도(중첩 `claude -p`) 정상 동작함을 확인.

## 6. 엣지케이스

- 1회 설정 누락 → `provider "anthropic-oauth" is not configured …` 즉시 실패 → ⚠ 배너 + 설정 명령 안내.
- 구독 로그인 아님 → 사전 점검에서 엔진 B 건너뜀.
- 구독 한도 도달 → 일부 그룹 실패 시 `partial`, 전부 실패 시 종료 코드 ≠ 0 → 에러 격리.
- 변경 파일 0 → 엔진 B `skipped`.
- unmerged 경로 → Step 1에서 FATAL.

## 7. 비목표

- MR/PR 댓글 게시, CI 무인 실행, 원격 PR 직접 리뷰, 순차 반박 사이클(v1과 동일).
- 엔진 B 모델 다양화(GPT 등): `chatgpt` 프로바이더로 가능하지만 범위 밖.

## 8. 남은 확인

- 스킬 전체 E2E(ce `depth:full` + 엔진 B 병렬 + adjudicator)는 아직 돌려보지 않았다.
- 큰 diff(수십 파일)에서의 시간·사용량.
- PR #1670 머지 여부와 머지 시 변경점 추적.
