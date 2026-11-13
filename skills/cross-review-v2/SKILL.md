---
name: cross-review-v2
description: >
  ce-code-review와 open-code-review 엔진 모드(ocr review, anthropic-oauth 프로바이더 =
  Claude Code 구독의 claude -p)를 동일 로컬 스냅샷으로 독립 실행하고, 결과를 병합해
  '두 엔진이 함께 지적한 항목(고신뢰)'과 '한쪽만 지적한 항목(사각지대)'으로 태깅한
  단일 리포트를 낸다. MR 보내기 전 로컬 워킹트리 교차 검증에 사용. 병합/합의 판정은
  신선 컨텍스트의 격리 서브에이전트가 수행.
---

# Cross Review v2 (ce-code-review × ocr review/anthropic-oauth)

두 독립 리뷰 엔진의 결과를 대칭 병합하고 합의 태깅한다. 이 스킬은 오케스트레이터일
뿐, 리뷰 판단은 각 엔진이 한다.

- **ce-code-review** → 페르소나 리뷰어 + 프로젝트 표준(`AGENTS.md`/`CLAUDE.md`) 기반
- **ocr review (anthropic-oauth)** → alibaba open-code-review **엔진 모드 그대로**
  (파일 그룹핑, Plan, 다회차 Main, REVIEW_FILTER, 라인 재배치를 Go 엔진이 강제).
  LLM 호출만 `claude -p`(Claude Code 구독)로 대체된다.
- v1(`cross-review`)과의 차이: v1의 엔진 B는 SKILL.md 절차를 Claude가 따라가는
  재구성(`ocr core`)이었다. v2는 엔진의 흐름 제어를 그대로 쓴다.

## 사전 점검

```bash
command -v ocr >/dev/null || echo "ocr 없음"
ocr llm providers 2>/dev/null | grep '^ *anthropic-oauth ' >/dev/null || echo "anthropic-oauth 프로바이더 없음(통합 바이너리 필요)"
claude auth status --json 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get("loggedIn") and d.get("authMethod")=="claude.ai" else 1)' \
  || echo "Claude 구독 로그인 아님(authMethod != claude.ai)"
```

- 셋 중 하나라도 실패하면 **엔진 B를 건너뛰고 ce 단독으로 진행**한다(에러 격리 규칙의
  ⚠ 배너 + `✗` 상태라인). `ce-code-review` 스킬이 없으면 엔진 A를 건너뛴다. 둘 다 없으면 종료.
- `ocr` 설정에 `providers.anthropic-oauth` 섹션이 있어야 한다(README의 1회 설정). 없으면
  `ocr review`가 `provider "anthropic-oauth" is not configured`로 즉시 실패하므로, 그 메시지를
  ⚠ 배너 사유로 그대로 쓰고 1회 설정 명령을 안내한다. **이 스킬이 사용자 설정을 대신 쓰지 않는다.**
- glab/gh는 이 스킬에서 직접 쓰지 않는다(로컬 워킹트리 전용).

## 인자 파싱

| 토큰 | 효과 | 기본 |
|------|------|------|
| `base:<ref>` | diff base 명시(양쪽 엔진에 동일 주입) | 자동 감지 |
| `model:<alias>` | 엔진 B 모델(`sonnet`, `opus` 등) → `--model` | 설정값 |
| `fix` | 리포트 후 수정 범위를 사용자와 상의해 적용 | 리포트만 |

인식한 토큰은 제거하고 나머지는 무시한다(로컬 전용이라 PR/브랜치 타깃은 받지 않음).
PR을 교차 검증하려면 "먼저 `glab mr checkout <id>`(또는 `gh pr checkout`)로 체크아웃한 뒤
`/cross-review-v2` 실행"을 안내한다.

## Step 1 — 스코프 산정 (스냅샷 커밋)

`base:` 인자가 있으면 `BASE_ARG`에, 없으면 기본 브랜치에서 merge-base를 잡는다.
**임시 인덱스**로 워킹트리 전체(추적 파일의 staged+unstaged + `.gitignore`를 존중한
미추적 파일)를 스냅샷 커밋 `WT`로 만든다. 실제 워킹트리와 인덱스는 바뀌지 않는다.

```bash
BASE_REF="${BASE_ARG:-$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/@@')}"
BASE_REF="${BASE_REF:-origin/HEAD}"
BASE=$(git merge-base HEAD "$BASE_REF" 2>/dev/null) || BASE=$(git rev-parse "$BASE_REF" 2>/dev/null)
[ -z "$BASE" ] && { echo "FATAL: base 미해결 — base:<ref>로 명시하세요"; exit 1; }
git ls-files -u | grep -q . && { echo "FATAL: unmerged/충돌 경로를 먼저 해결하세요"; exit 1; }
TMPIDX=$(mktemp)
WT=$(export GIT_INDEX_FILE="$TMPIDX"   # $( ) 서브셸 안에서만 유효 → 실제 .git/index 불변
     git read-tree HEAD && git add -A && TREE=$(git write-tree) \
     && git commit-tree -p HEAD -m "cross-review-v2 snapshot" "$TREE")
rm -f "$TMPIDX"
git rev-parse --verify --quiet "$WT^{commit}" >/dev/null 2>&1 || { echo "FATAL: 스냅샷 실패"; exit 1; }
UNTRACKED=$(git ls-files --others --exclude-standard)
echo "BASE=$BASE  WT=$WT"; echo "UNTRACKED:"; echo "$UNTRACKED"
```

- **셸 변수는 Bash 호출 사이에 유지되지 않는다.** 위 출력에 나온 `BASE`·`WT`·`UNTRACKED`
  값을 기록해 두고, 이후 단계의 명령(`ocr review`, ce의 `base:`)에는 그 값을 **직접 치환해서**
  넣는다.
- `GIT_INDEX_FILE`을 서브셸에서만 바꾸므로 실제 `.git/index`는 그대로다. 스냅샷 커밋은
  어떤 ref에도 연결되지 않는 dangling 객체라 `git gc`가 나중에 정리한다.
- **스코프 비대칭(중요):** ce-code-review는 `base:` 모드에서 미추적 파일을 **범위 밖**으로
  둔다(staged가 아니면 Coverage에만 적음). 엔진 B는 `WT`를 보므로 미추적 파일까지 리뷰한다.
  따라서 `UNTRACKED` 목록의 경로에 대한 엔진 B 지적은 "ce 사각지대"가 아니라 **"ce 범위 밖"**
  이다. Step 4/5에서 별도로 다룬다. 사용자가 양쪽 모두에서 검토받길 원하면 해당 파일을
  `git add` 후 재실행하도록 리포트에 안내한다.

## Step 2 — 두 엔진 실행 (병렬)

엔진 B는 서브에이전트를 띄우지 않는 **단일 `ocr` 프로세스**다(내부에서 `claude -p`
자식 프로세스를 동시성만큼 띄움). 그래서 엔진 A와 경합하는 것은 오케스트레이터의
서브에이전트 슬롯이 아니라 **구독 사용량**뿐이다. 다음 순서로 겹쳐 돌린다.

1. 엔진 B를 **백그라운드 Bash**(`run_in_background: true`)로 먼저 시작한다.
2. 그동안 엔진 A(ce)를 Skill 도구로 실행한다.
3. ce가 끝나면 엔진 B 완료 알림을 기다린다(폴링 금지, 알림이 오면 결과 파일을 읽는다).

### Step 2B — 엔진 B: ocr review (anthropic-oauth)

```bash
OUT=$(mktemp --suffix=.json)
ocr review --from "$BASE" --to "$WT" --provider anthropic-oauth ${MODEL:+--model "$MODEL"} \
  --format json --audience agent --concurrency 2 --output "$OUT"
echo "exit=$? out=$OUT"
```

- `--concurrency 2`: 기본값 8은 `claude -p`를 8개 동시에 띄워 구독 한도를 빨리 소모한다.
  ce와 병렬로 도는 만큼 낮게 둔다. 큰 변경에서 느리면 3까지.
- `--output`으로 파일에 쓴다(stdout은 백그라운드 출력 버퍼로 가므로 파싱 대상에서 뺀다).
- 종료 코드: 일부 파일만 실패해도 0(부분 결과 게시). **선택된 항목이 전부 실패할 때만** 0이 아니다.
- JSON 최상위 `status`: `complete` | `partial` | `failed` | `skipped`
  (`manifest.terminal_state`와 같다). 다음과 같이 해석한다.
  - `complete` → `comments[]`를 정규화.
  - `partial` → `comments[]`를 정규화하고, `manifest.coverage.failed[]`(경로·분류)를 리포트의
    coverage 줄에 적는다(전체 실패 아님).
  - `skipped` → 리뷰 대상 파일 없음(`message`). 엔진 B findings 0으로 진행.
  - `failed`, 0이 아닌 종료 코드, JSON 파싱 실패 → 엔진 B 전체 실패(에러 격리).
- `summary`(`files_reviewed`, `comments`, `total_tokens`, `elapsed`)는 리포트 엔진 상태줄에 쓴다.

### Step 2A — 엔진 A: ce-code-review (mode:agent depth:full)

Skill 도구로 `ce-code-review`를 **`mode:agent depth:full base:<BASE>`** 로 호출한다(read-only, JSON 반환).

- **`depth:full` 필수.** ce의 `mode:agent`는 quick-review 단축만 우회하고, 깊이 게이트
  (lite / focused / full)는 그대로 탄다. lite가 선택되면 **호출한 컨텍스트(= 이 메인 대화)
  에서 단독 리뷰**하므로, 작업 세션 맥락에 오염되지 않은 독립 리뷰라는 교차 검증의 전제가
  깨진다. `depth:full`은 다중 에이전트 경로를 강제한다.
- 반환된 **단일 raw JSON**을 파싱:
  - `status == "failed" | "degraded"` → ce 실패로 기록(에러 격리). `findings` 없음.
  - `status == "skipped"` → 사유 기록 후 ce 없이 진행.
  - `status == "complete"` → `findings[]`(전체, `actionable_findings` 아님)를 Step 3 규칙으로 정규화.

## Step 3 — 정규화

공통 스키마:

```
{ engine: "ce" | "ocr",
  severity: "P0"|"P1"|"P2"|"P3",       // 통일 축
  severity_orig: "<원본 라벨>",         // ce: P0-P3 / ocr: critical|high|medium|low
  category: "<ocr category | null>",    // bug|security|performance|maintainability|test|style|documentation|other
  file: "<경로>",
  start_line: <int>, end_line: <int>,   // 재배치 실패 시 0,0
  claim: "<이슈 서술>",
  suggestion: "<제안 or null>",
  untracked: <bool> }                   // file ∈ UNTRACKED (ocr 전용 의미)
```

- **ce → 정규화:** `findings[]` 각 항목의 `severity`(그대로), `file`, `line`(start=end=line),
  `title` + `. ` + `why_it_matters` → `claim`, `suggested_fix` → `suggestion`, `category: null`.
- **ocr → 정규화:** `comments[]` 각 항목의 `path` → `file`, `start_line`/`end_line`,
  `content` → `claim`, `suggestion_code` → `suggestion`(빈 문자열이면 null), `category` 보존.
  severity: `critical→P0`, `high→P1`, `medium→P2`, `low→P3`(엔진이 low도 내보내므로 **버리지 않는다**).
  severity가 비어 있으면 `P2`. `untracked = file ∈ UNTRACKED`.
- `existing_code`, `thinking`은 버린다(adjudicator 입력을 작게 유지).

## Step 4 — adjudicator 서브에이전트 (병합 / 합의 판정)

**신선 격리 서브에이전트**를 1개 띄운다(Agent 도구, `subagent_type: general-purpose`).
입력은 정규화된 두 리스트(JSON 데이터)와 저장소 루트 절대경로뿐. **작업 세션의 코드 의도나
광역 컨텍스트를 절대 전달하지 않는다.** `untracked: true`인 ocr 항목은 **adjudicator에 넣지
않고** 바로 `ocr_out_of_ce_scope`로 분리한다(ce가 볼 수 없었던 파일이라 합의 판정 대상이 아님).

아래 프롬프트를 그대로 전달:

> 너는 두 코드리뷰 엔진의 findings를 병합하는 판정자다. 아래 두 JSON 리스트만 근거로
> 판단하라. 작업 세션의 코드 의도나 광역 컨텍스트를 추정하지 말 것.
>
> **합의 판정(두 findings가 "같은 이슈"인가):** ① 같은 file, AND ② 라인 범위가 겹치거나
> 3줄 이내로 근접(어느 쪽 start_line/end_line이 0이면 라인 무시하고 file+클레임으로만 판단),
> AND ③ 두 claim이 같은 문제를 가리킴. ③이 애매하면 `repo_root` 기준으로 해당 `file`의
> `start_line` 근방만 Read로 대조하되, 그 파일의 광역 로직 추정은 금지.
>
> **병합 규칙:** 합의면 `agreed`에 넣고 두 엔진 중 **더 높은(보수적) severity** 채택.
> 합의 항목의 `start_line`/`end_line`은 두 findings 범위의 **합집합**(작은 start, 큰 end).
> ce에만 있으면 `ce_only`, ocr에만 있으면 `ocr_only`(각 원 severity 유지). ocr 항목의
> `category`가 있으면 그대로 옮긴다.
>
> **출력:** 아래 스키마의 raw JSON만 출력(코드펜스 금지). 한국어 issue 서술.
> Report in Korean.
>
> repo_root = &lt;저장소 루트 절대경로&gt;
> ce_findings = &lt;정규화 ce 리스트&gt;
> ocr_findings = &lt;정규화 ocr 리스트(untracked 제외)&gt;

출력 스키마:

```json
{ "agreed":   [{"severity":"","file":"","start_line":0,"end_line":0,"issue":"","suggestion":"","category":"","ce_ref":0,"ocr_ref":0}],
  "ce_only":  [{"severity":"","file":"","start_line":0,"end_line":0,"issue":"","suggestion":""}],
  "ocr_only": [{"severity":"","file":"","start_line":0,"end_line":0,"issue":"","suggestion":"","category":""}],
  "counts":   {"agreed":0,"ce_only":0,"ocr_only":0} }
```

- `ce_ref`/`ocr_ref`는 입력 리스트의 인덱스.
- **스키마 검증:** Agent 도구에는 JSON 스키마 강제가 없다. 반환 텍스트의 앞뒤 ` ```json `/` ``` `
  코드펜스를 제거한 뒤 `python3 -c json.loads`로 파싱한다. 실패하면 "위 스키마의 raw JSON만,
  코드펜스 없이 다시 출력"으로 1회 재요청.
- adjudicator가 실패하거나 빈 응답이면 병합 없이 두 리스트를 각각 단독으로 리포트하고 그 사실을 명시한다.
- `ocr_out_of_ce_scope`(미추적 파일 지적)는 adjudicator 결과와 별개로 리포트에 붙인다. 이 항목은
  정규화 `claim`을 Step 5 블록의 **이슈** 요소로 쓰되, Step 5 규칙대로 쉬운 말 개조식 불릿로
  풀어 쓴다.

## Step 5 — 리포트 (한국어)

정렬: 합의 → ce단독 → ocr단독 → ce 범위 밖, 각 그룹 내 severity 내림차순(P0→P3).

**출력은 그대로 MR/PR 리뷰 댓글로 붙여넣을 수 있는 통일된 블록 형식**이다. 각 finding을
`위치 / 이슈 / 제안` 3요소로 렌더링하며, 표가 아니라 항목 블록으로 쓴다(댓글 붙여넣기·모바일
가독성·긴 서술 수용). 세 요소는 항상 이 순서·이 라벨로 고정한다.

```
## Cross-Review v2 결과  (base: <BASE 짧은sha>, N개 파일)

**엔진:** ce-code-review ✓ (depth:full) / ocr review (anthropic-oauth) ✓ (<model>, <elapsed>, <total_tokens> tok)
**합의 {agreed} · ce-단독 {ce_only} · ocr-단독 {ocr_only} · ce 범위 밖 {out_of_scope}**

### ★ 합의 (고신뢰 — 두 엔진 모두 지적)

#### 1. {severity} — {한 줄 제목}
> ⭐ {어느 엔진/관점들이 수렴했는지}
- **위치:** `file:start_line`
- **이슈:**
  - {쉬운 말 개조식 불릿 1 — 무슨 일이 벌어지는지}
  - {불릿 2 — 왜 문제인지 / 언제 터지는지}
  - {필요시 불릿 3 — 결과·영향}
- **제안:** {구체적 수정. 코드 조각이 명확히 도움되면 ```블록``` 포함}

### ce 단독 (ocr 사각지대?)

#### 2. {severity} — {제목}
- **위치:** ...
- **이슈:** ...
- **제안:** ...

### ocr 단독 (ce 사각지대? — 엔진 REVIEW_FILTER 통과분)

#### 3. {severity} · {분류} — {제목}
- **위치:** ...
- **이슈:** ...
- **제안:** ...

### ocr 단독 — ce 범위 밖 (미추적 파일)
> 미추적 파일은 ce-code-review가 검토하지 않는다. 양쪽 교차가 필요하면 `git add` 후 재실행.

#### 4. {severity} · {분류} — {제목}
- **위치:** ...
- **이슈:** ...
- **제안:** ...

**교차 검증 핵심**
- ce 사각지대: ... / ocr 사각지대: ... / 함께 잡은 것: ...

**판정:** Ready | Ready with fixes | Not ready — 우선 착수: #1, #3
```

- **번호는 전체 그룹 통틀어 단조 증가**(합의→ce→ocr→ce 범위 밖 순, 각 그룹 내 severity 내림차순).
  댓글에서 "#2 관련해서…"로 참조 가능하게.
- **이슈는 개조식 불릿, 쉬운 말 우선.** `claim`/`issue`의 서술을 그대로 붙여넣지 말고, 비전문가도
  이해할 짧은 불릿로 풀어 쓴다(전문 용어는 괄호로 보조). 코드의 *증상*과 *왜/언제 터지는지*를
  먼저, 메커니즘은 뒤에. 한 finding당 불릿 1~3개.
- **제안은 실행 가능하게.** 한 줄로 충분하면 한 줄, 코드 조각이 이해를 확실히 돕는 경우(예: 3줄
  가드 추가)만 fenced 코드블록을 넣는다.
- 합의 항목엔 제목 아래 `> ⭐ {어느 엔진/관점들이 수렴했는지}` 한 줄로 고신뢰 근거를 덧붙인다.
- **마무리 블록(권장):** finding들 뒤에 `**교차 검증 핵심**`(ce/ocr 각 사각지대 1줄, 함께 잡은 것
  1줄)과 `**판정**`(Ready / Ready with fixes / Not ready + 우선 착수 항목)을 붙인다. 같은 함수·
  같은 근본원인으로 묶이는 finding은 "한 번에 처리" 힌트를 준다.

- `N개 파일` = 엔진 B `manifest.coverage.selected` 수. 엔진 B가 죽었으면
  `git diff --name-only $BASE $WT` 파일 수.
- 엔진 B가 `partial`이면 엔진 줄 아래에 `ocr coverage: <completed>/<selected> (실패: <path> — <classification>, …)`.
- 위치는 `file:start_line`(`end_line`>`start_line`이면 `file:start-end`). `start_line`이 0이면 `file(라인미상)`.
- `분류`는 ocr `category`(제목 줄의 `{severity} · {분류}`). 비면 생략.
- `**엔진:**` 상태줄은 실제 결과와 맞춘다. 실패/미실행 엔진은 `✗`로 표시하고 ⚠ 배너와 모순되지 않게 한다.
- 각 그룹이 비면 "해당 없음" 한 줄. 미추적 파일이 없으면 마지막 구역은 생략. 두 엔진 findings가
  모두 0이면 "지적 없음"으로 보고. 기본은 리포트 전용(파일 저장은 요청 시).

## 에러 격리

- **엔진 전체 실패 판정:** ce는 `status: failed/degraded` 또는 스킬 미설치. ocr은 사전 점검 실패,
  0이 아닌 종료 코드, `status: failed`, JSON 파싱 실패. `partial`은 전체 실패가 아니다(coverage에만 표시).
- 한 엔진이 전체 실패해도 **중단하지 않는다.** 나머지 엔진 결과만으로 리포트하되 상단에
  `⚠ <엔진> 실패(<사유>): 다른 엔진 결과만 표시`를 붙이고 상태줄의 해당 엔진을 `✗`로 표시한다.
  이때 **adjudicator 호출은 건너뛴다** — 살아있는 쪽 findings를 전부 해당 엔진 단독 섹션에 넣고
  합의는 0. counts는 직접 채운다. 단독 섹션의 **이슈** 요소는 정규화 `claim`을 근거로 하되,
  통째로 붙이지 말고 Step 5 규칙대로 쉬운 말 개조식 불릿로 풀어 쓴다.
- ocr이 살아있고 ce가 죽은 경우에도 미추적 파일 구역 분리는 유지한다.
- 두 엔진 모두 실패 → 실패 사유를 명시하고 종료.
- 엔진 B 실패 사유로 흔한 것: `provider "anthropic-oauth" is not configured`(1회 설정 누락),
  `Claude subscription login required`(구독 로그인 아님), 구독 사용량 한도 도달. 사유를 배너에 그대로 쓴다.

## PR/브랜치 안내

로컬 워킹트리 전용이다. PR을 교차 검증하려면 먼저 `glab mr checkout <id>`로 MR 브랜치를
체크아웃한 뒤 `/cross-review-v2`를 실행하도록 안내한다.

## fix (선택)

`fix` 인자가 없으면 리포트만 하고 종료한다. `fix`가 있으면 리포트를 먼저 보여준 뒤,
**어디까지 고칠지 사용자와 상의**한다(예: ★합의 P0/P1만, 또는 사용자가 지정한 항목). 정한
수정 대상에 대해서만 `suggestion`을 근거로 Edit로 적용하고, 적용분을 리포트 하단에 요약한다.
자동 일괄 적용은 하지 않는다.
