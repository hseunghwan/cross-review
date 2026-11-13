---
name: cross-review
description: >
  ce-code-review와 open-code-review-local 두 리뷰 엔진을 동일 로컬 diff로 독립
  실행하고, 결과를 병합해 '두 엔진이 함께 지적한 항목(고신뢰)'과 '한쪽만 지적한
  항목(사각지대)'으로 태깅한 단일 리포트를 낸다. MR 보내기 전 로컬 워킹트리
  교차 검증에 사용. 병합/합의 판정은 신선 컨텍스트의 격리 서브에이전트가 수행.
---

# Cross Review (ce-code-review × open-code-review-local)

두 독립 리뷰 엔진의 결과를 대칭 병합하고 합의 태깅한다. 이 스킬은 오케스트레이터일
뿐, 리뷰 판단은 두 엔진 각자의 격리 서브에이전트가 한다.

- **ce-code-review** → 페르소나 리뷰어 + 프로젝트 표준 기반
- **open-code-review-local** → alibaba `ocr` v1.13.8 파이프라인(그룹핑·Plan·다회차 Main·
  REVIEW_FILTER)을 `ocr core` 빌딩 블록으로 재현, 판단은 Claude 구독
- 두 엔진은 블라인드 스팟이 달라서 교차에 가치가 있다: **둘 다 지적 = 고신뢰**,
  **한쪽만 지적 = 상대의 사각지대 신호**.

## 사전 점검

```bash
ocr core template >/dev/null 2>&1 || echo "주의: ocr core(v1.13.8+core) 없음 → open-code-review-local을 건너뛰고 ce 단독 진행"
ocr --version
```
- `ocr`는 **`core` 명령 그룹이 들어간 포크 빌드(v1.13.8+core)** 여야 한다. 업스트림
  npm/GitHub 릴리스(`@alibaba-group/open-code-review`)에는 `core`가 없다. 예전 v1.6.6+core
  바이너리는 `ocr core template`가 없어 위 점검에서 걸러진다.
- `ocr core`(open-code-review-local용) 또는 `ce-code-review` 스킬 중 하나가 없어도 **중단하지
  않는다.** 없는 엔진은 아래 "에러 격리" 규칙대로 처리한다(⚠ 배너 + `✗` 상태라인, 나머지 엔진
  단독 리포트). 둘 다 없으면 종료.
- glab은 이 스킬에서 직접 쓰지 않는다(로컬 워킹트리 전용).

## 인자 파싱

| 토큰 | 효과 | 기본 |
|------|------|------|
| `base:<ref>` | diff base 명시(ce/ocr 양쪽에 동일 주입) | 자동 감지 |
| `fix` | 리포트 후 수정 범위를 사용자와 상의해 적용 | 리포트만 |

인식한 토큰(`base:`, `fix`)은 제거하고 나머지는 무시한다(로컬 전용이라 PR/브랜치
타깃은 받지 않음). PR을 교차 검증하려면 "먼저 `glab mr checkout <id>`로 체크아웃한 뒤
`/cross-review` 실행"을 안내한다.

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
     && git commit-tree -p HEAD -m "cross-review snapshot" "$TREE")
rm -f "$TMPIDX"
git rev-parse --verify --quiet "$WT^{commit}" >/dev/null 2>&1 || { echo "FATAL: 스냅샷 실패"; exit 1; }
UNTRACKED=$(git ls-files --others --exclude-standard)
echo "BASE=$BASE  WT=$WT"; echo "UNTRACKED:"; echo "$UNTRACKED"
```

- **셸 변수는 Bash 호출 사이에 유지되지 않는다.** 위 출력의 `BASE`·`WT`·`UNTRACKED` 값을
  기록해 두고, 이후 명령에는 그 값을 **직접 치환해서** 넣는다.
- ce 엔진에는 `base:$BASE`를 전달한다(ce는 `git diff $BASE`로 base..워킹트리를 본다).
- ocr 엔진의 모든 `ocr core diff|group|render` 호출에는 `--from $BASE --to $WT`를 똑같이
  전달한다. 스냅샷 커밋이라 리뷰 도중 파일이 바뀌어도 ocr 쪽 diff가 흔들리지 않는다.
- `GIT_INDEX_FILE`을 서브셸에서만 바꾸므로 실제 `.git/index`는 그대로다. 스냅샷 커밋은
  어떤 ref에도 연결되지 않는 dangling 객체라 `git gc`가 나중에 정리한다.
- **스코프 비대칭(중요):** ce-code-review는 `base:` 모드에서 미추적 파일을 **범위 밖**으로
  둔다. ocr은 `WT`를 보므로 미추적 파일까지 리뷰한다. 따라서 `UNTRACKED` 경로에 대한 ocr
  지적은 "ce 사각지대"가 아니라 **"ce 범위 밖"**이다. Step 4/5에서 따로 다룬다. 양쪽
  교차가 필요하면 해당 파일을 `git add` 후 재실행하도록 리포트에 안내한다.

## Step 2A — 엔진 A: ce-code-review (mode:agent depth:full)

Skill 도구로 `ce-code-review`를 **`mode:agent depth:full base:<BASE>`** 로 호출한다(read-only,
JSON 반환).

- **`depth:full` 필수.** ce의 `mode:agent`는 quick-review 단축만 우회하고, 깊이 게이트
  (lite / focused / full)는 그대로 탄다(ce `references/modes-and-output.md`의 Quick Review
  Short-Circuit·Review depth gate). lite가 선택되면 **호출한 컨텍스트(= 이 메인 대화)에서
  단독 리뷰**하므로, 작업 세션 맥락에 오염되지 않은 독립 리뷰라는 교차 검증의 전제가 깨진다.
  `depth:full`은 다중 에이전트 경로(full spine)를 강제한다.
- 반환된 **단일 raw JSON**을 파싱:
  - `status == "failed" | "degraded"` → ce 실패로 기록(에러 격리 섹션 참조). `findings` 없음.
  - `status == "skipped"` → ce가 리뷰 대상 아님으로 판단(로컬 워킹트리에선 드묾). 사유 기록 후 ce 없이 진행.
  - `status == "complete"` → `findings[]`를 Step 3 규칙으로 `ce_findings[]`로 정규화.
    (`actionable_findings`가 아니라 전체 `findings`를 쓴다 — 교차 대상은 모든 지적.)
- `ce-code-review` 스킬이 없으면 이 단계를 건너뛰고 ocr 단독 진행 — 에러 격리 규칙대로
  ⚠ 배너 + `✗` 상태라인으로 표기(미설치도 "전체 실패"와 동일 처치).
- ce는 로컬에 설치된 compound-engineering 플러그인 버전을 그대로 쓴다. 이 스킬이 기대하는
  `mode:agent` 계약(`status`, `findings[].severity/file/line/title/why_it_matters/suggested_fix`)은
  3.33.0 ~ 3.38.1에서 같다.

## Step 2B — 엔진 B: open-code-review-local (REVIEW_FILTER ON)

`open-code-review-local` 스킬을 **재구현하지 말고 그 SKILL.md(v0.3.0+)의 절차를 따른다**.
스코프와 필터만 이 스킬이 고정한다:

1. **대상:** `ocr core diff --repo . --from "$BASE" --to "$WT"`. `will_review: true`인 파일만 대상.
2. **그룹핑:** `ocr core group --repo . --from "$BASE" --to "$WT"`(필요하면 grouping 답을
   `--response-file`로 돌려줌). 이후 리뷰 단위는 **그룹**이다.
3. **리뷰:** 그룹마다 그 스킬의 Plan(`plan_required`일 때) → Main 라운드(최대
   `max_review_rounds`, 확정 코멘트 전달, 새 발견 없으면 중단) → relocate 파이프라인.
   모든 `ocr core render` 호출에 `--from "$BASE" --to "$WT"`를 쓴다.
4. **REVIEW_FILTER:** **항상 켠다**(사용자 opt-out 무시). 라운드마다 격리 diff-only
   서브에이전트로 거짓양성 필터 패스 실행.
5. **분류:** 생존 코멘트는 엔진 `code_comment` 스키마대로 `severity`
   (`critical|high|medium|low`)와 `category`를 이미 갖는다. **low도 버리지 않는다.**

생존 코멘트를 Step 3 규칙으로 `ocr_findings[]`로 정규화한다. `ocr core emit`은
사용하지 않는다(로컬 리포트 전용).

두 엔진은 **순차 실행**한다. Skill 도구는 메인 대화에서 실행되므로 ce·ocr 둘 다 메인
오케스트레이터의 1단계 fan-out이다(중첩 아님). 다만 두 파이프라인 모두 다수의 leaf
서브에이전트를 광범위하게 띄우므로, 동시에 돌리면 서브에이전트 동시성/용량 한도에서
경합한다(ce-code-review 자체가 bounded parallel dispatch를 명시). 순차가 보수적으로
안전하다. 실제 리뷰는 양쪽 모두 leaf 서브에이전트에서 격리 수행되므로 순서에 따른 오염은 없다.

## Step 3 — 정규화

두 엔진 결과를 공통 스키마로 변환한다.

```
{ engine: "ce" | "ocr",
  severity: "P0"|"P1"|"P2"|"P3",       // 통일 축
  severity_orig: "<원본 라벨>",         // ce: P0-P3 / ocr: critical|high|medium|low
  category: "<ocr category | null>",    // bug|security|performance|maintainability|test|style|documentation|other
  file: "<경로>",
  start_line: <int>, end_line: <int>,   // ocr relocation 실패 시 0,0
  claim: "<이슈 서술>",                 // ce: title + '. ' + why_it_matters / ocr: 코멘트 content
  suggestion: "<제안 or null>",          // ce: suggested_fix / ocr: suggestion_code
  untracked: <bool> }                   // file ∈ UNTRACKED (ocr 전용 의미)
```

- **ce → 정규화:** `mode:agent` JSON의 `findings[]`에서 각 항목의
  `severity`(그대로), `file`, `line`(start=end=line), `title`+`. `+`why_it_matters`→`claim`,
  `suggested_fix`→`suggestion`, `category: null`. `severity_orig`=원본 severity.
- **ocr → 정규화:** 생존 코멘트에서 `path`→`file`, `start_line`/`end_line`,
  `content`→`claim`, `suggestion_code`→`suggestion`(빈 문자열이면 null), `category` 보존.
  severity: `critical→P0`, `high→P1`, `medium→P2`, `low→P3`. 비어 있으면 `P2`.
  `severity_orig`=원본 라벨. `untracked = file ∈ UNTRACKED`.
- `existing_code`, `thinking`은 버린다(adjudicator 입력을 작게 유지).

## Step 4 — adjudicator 서브에이전트 (병합 / 합의 판정)

**신선 격리 서브에이전트**를 1개 띄운다(Agent 도구, `subagent_type: general-purpose`).
입력은 정규화된 두 리스트(JSON 데이터)와 저장소 루트 절대경로뿐. **작업 세션의 코드 의도나
광역 컨텍스트를 절대 전달하지 않는다.** `untracked: true`인 ocr 항목은 **adjudicator에 넣지
않고** 바로 `ocr_out_of_ce_scope`로 분리한다(ce가 볼 수 없었던 파일이라 합의 판정 대상이 아님).
저장소 루트는 ③ 대조용 Read에만 쓴다. 아래 프롬프트를 그대로 전달:

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

출력 스키마 (adjudicator는 이 형태의 raw JSON만 반환):

```json
{ "agreed":   [{"severity":"","file":"","start_line":0,"end_line":0,"issue":"","suggestion":"","category":"","ce_ref":0,"ocr_ref":0}],
  "ce_only":  [{"severity":"","file":"","start_line":0,"end_line":0,"issue":"","suggestion":""}],
  "ocr_only": [{"severity":"","file":"","start_line":0,"end_line":0,"issue":"","suggestion":"","category":""}],
  "counts":   {"agreed":0,"ce_only":0,"ocr_only":0} }
```

- `ce_ref`/`ocr_ref`는 입력 리스트의 인덱스.
- **스키마 강제:** Agent 도구에는 JSON 스키마 강제 옵션이 없다(그건 Workflow `agent()`의
  `schema` 옵션). 따라서 프롬프트로 raw JSON을 지시하고, 반환 텍스트를 `python3 -c json.loads`로
  파싱해 검증한다. **파싱 전 앞뒤 ` ```json `/` ``` ` 코드펜스가 있으면 제거한다** — 서브에이전트가
  "코드펜스 금지" 지시를 어기고 감싸는 경우가 실제로 있다(E2E에서 확인). 펜스 제거 후에도 파싱
  실패 시 "위 스키마의 raw JSON만, 코드펜스 없이 다시 출력"으로 1회 재요청.
- adjudicator가 실패/빈 응답이면 병합 없이 두 리스트를 각각 단독으로 리포트하고 그 사실을 명시한다.
- `ocr_out_of_ce_scope`(미추적 파일 지적)는 adjudicator 결과와 별개로 리포트에 붙인다. 이 항목은
  정규화 `claim`을 Step 5 블록의 **이슈** 요소로 쓰되, Step 5 규칙대로 쉬운 말 개조식 불릿로
  풀어 쓴다. `out_of_scope` 개수 = 그 항목 수.

## Step 5 — 리포트 (한국어)

adjudicator 출력과 `ocr_out_of_ce_scope`로 아래 형식을 렌더링한다. 정렬: 합의 → ce단독 →
ocr단독 → ce 범위 밖, 각 그룹 내 severity 내림차순(P0→P3).

**출력은 그대로 MR/PR 리뷰 댓글로 붙여넣을 수 있는 통일된 블록 형식**이다. 각 finding을
`위치 / 이슈 / 제안` 3요소로 렌더링하며, 표가 아니라 항목 블록으로 쓴다(댓글 붙여넣기·모바일
가독성·긴 서술 수용). 세 요소는 항상 이 순서·이 라벨로 고정한다.

```
## Cross-Review 결과  (base: <BASE 짧은sha>, N개 파일)

**엔진:** ce-code-review ✓ (depth:full) / open-code-review-local ✓ (v1.13.8+core, REVIEW_FILTER on)
**합의 {counts.agreed} · ce-단독 {counts.ce_only} · ocr-단독 {counts.ocr_only} · ce 범위 밖 {out_of_scope}**

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

### ocr 단독 (ce 사각지대? — 필터 통과분이라 신뢰도 있음)

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
- `N개 파일` = 공통 diff 스코프(`ocr core diff`의 `reviewable_count`) 파일 수.
- ocr에서 그룹이 일부 실패했으면 엔진 줄 아래에 `ocr coverage: <완료 파일>/<대상 파일> (건너뜀: <path> — <사유>, …)`.
- 위치는 `file:start_line`(`end_line`>`start_line`이면 `file:start-end`).
  `start_line`이 0이면 `file(라인미상)`.
- `분류`는 ocr `category`(제목 줄의 `{severity} · {분류}`). 비면 생략.
- `**엔진:**` 상태 라인은 실제 결과와 정합을 맞춘다 — 실패/미실행 엔진은 `✗`로 표시하고
  아래 에러 격리의 `⚠` 배너와 모순되지 않게 한다.
- 각 그룹이 비면 "해당 없음" 한 줄. 미추적 파일이 없으면(`UNTRACKED`가 비면) 마지막 구역과
  요약줄의 `ce 범위 밖` 항목은 생략. 두 엔진 findings가 모두 0이면 "지적 없음"으로 보고.
  기본은 리포트 전용(파일 저장은 요청 시).

## 에러 격리

- **엔진 전체 실패 판정:** ce는 `status: failed/degraded`. ocr은 사전 점검 실패, `ocr core diff`
  자체 실패, 또는 전(全) 그룹 리뷰 실패를 "전체 실패"로 본다. 개별 그룹 서브에이전트 하나가
  실패하는 부분 실패는 `open-code-review-local`의 자체 failure-isolation으로 처리되어
  coverage만 줄어드는 것이며(건너뛴 파일을 리포트에 명시), 전체 실패 배너 대상이 아니다.
- 한 엔진이 전체 실패해도 **중단하지 않는다.** 나머지 엔진 결과만으로 리포트하되, 상단에
  `⚠ <엔진> 실패(<사유>): 다른 엔진 결과만 표시`를 붙이고 `**엔진:**` 상태 라인의 해당
  엔진을 `✗`로 표시한다. 이때 **adjudicator 호출은 건너뛴다**(병합할 상대가 없음) — 살아있는
  쪽 findings를 전부 해당 엔진 단독 섹션에 넣고 합의는 0. counts는 adjudicator 없이 직접
  채운다(agreed=0, 살아있는 엔진 단독=finding 수, 실패 엔진=0).
- ocr이 살아있고 ce가 죽은 경우에도 **미추적 파일 구역 분리는 유지한다**: `untracked`
  ocr 항목은 `ce 범위 밖` 구역으로, 나머지만 ocr 단독 구역으로 간다.
- 단독 섹션 렌더 시, adjudicator를 거치지 않으므로 생존 엔진 정규화 findings의 `claim`을
  Step 5 블록의 **이슈** 요소로 쓴다(정상 경로의 `issue` 변환이 없음). 단 `claim`을 통째로
  붙이지 말고 Step 5 규칙대로 쉬운 말 개조식 불릿로 풀어 쓴다. `N개 파일`은 ocr이 죽어 `reviewable_count`를 못 구하면
  `git diff --name-only $BASE $WT` 파일 수로 대체한다.
- 두 엔진 모두 실패 → 실패 사유를 명시하고 종료.

## PR/브랜치 안내

로컬 워킹트리 전용이다. PR을 교차 검증하려면 먼저 `glab mr checkout <id>`로 MR 브랜치를
체크아웃한 뒤 `/cross-review`를 실행하도록 안내한다.

## fix (선택)

`fix` 인자가 없으면 리포트만 하고 종료한다. `fix`가 있으면 리포트를 먼저 보여준 뒤,
**어디까지 고칠지 사용자와 상의**한다(예: ★합의 P0/P1만, 또는 사용자가 지정한 항목 —
ce_only/ocr_only/ce 범위 밖 포함 가능). 사용자와 정한 수정 대상에 대해서만 `suggestion`을
근거로 Edit로 적용하고, 적용분을 리포트 하단에 요약한다. 자동 일괄 적용은 하지 않는다.
