---
name: cross-review-ship
description: >
  ce-code-review, open-code-review 엔진 모드(ocr review, anthropic-oauth), Claude Code 내장
  code-review(/ship의 리뷰 단계와 같은 엔진) 세 리뷰 엔진을 동일 로컬 스냅샷으로 독립 실행하고,
  결과를 병합해 '세 엔진 합의 / 두 엔진 합의 / 단독(사각지대)'으로 태깅한 단일 리포트를 낸다.
  MR 보내기 전 로컬 워킹트리 교차 검증에 사용. 병합/합의 판정은 신선 컨텍스트의 격리
  서브에이전트가 수행.
---

# Cross Review Ship (ce-code-review × ocr review × ship 리뷰)

세 독립 리뷰 엔진의 결과를 대칭 병합하고 합의 수준을 태깅한다. 이 스킬은 오케스트레이터일
뿐, 리뷰 판단은 각 엔진이 한다. v2(`cross-review-v2`)에 엔진 C를 더한 형태다.

- **엔진 A · ce-code-review** → 페르소나 리뷰어 + 프로젝트 표준(`AGENTS.md`/`CLAUDE.md`) 기반
- **엔진 B · ocr review (anthropic-oauth)** → alibaba open-code-review **엔진 모드 그대로**
  (파일 그룹핑, Plan, 다회차 Main, REVIEW_FILTER, 라인 재배치를 Go 엔진이 강제).
  LLM 호출만 `claude -p`(Claude Code 구독)로 대체된다.
- **엔진 C · ship 리뷰 (`code-review`)** → Claude Code 내장 `code-review` 스킬. `/ship`이
  PR 리뷰 단계에서 쓰는 엔진과 같다(내장 별칭 `ship:review`). 여러 finder 각도(라인 스캔,
  삭제된 동작 감사, 정리·컨벤션 등) → 검증(verify) 패스 → 상위 N개를 남긴다.
  `/ship` 자체는 커밋·push·PR 생성·감시까지 하므로 **부르지 않는다.** 리뷰 단계만 쓴다.

## 사전 점검

- `ocr`가 PATH에 있어야 한다.
- `ocr llm providers`에 `anthropic-oauth`가 있어야 한다(통합 바이너리 필요).
- `claude auth status --json`이 `loggedIn: true`와 `authMethod: claude.ai`를 반환해야 한다.

- 셋 중 하나라도 실패하면 **엔진 B를 건너뛴다**(에러 격리 규칙의 ⚠ 배너 + `✗` 상태라인).
- 엔진 A는 호출 호스트의 CLI(`claude` 또는 `codex`)에 `ce-code-review` 스킬이 설치되어 있어야 한다.
- 엔진 C는 두 호스트 모두 `claude` CLI의 내장 `code-review`를 쓴다. CLI나 내장 스킬을
  사용할 수 없으면 엔진 C 실패로 기록한다.
- 세 엔진이 모두 없으면 종료.
- `ocr` 설정에 `providers.anthropic-oauth` 섹션이 있어야 한다(README의 1회 설정). 없으면
  `ocr review`가 `provider "anthropic-oauth" is not configured`로 즉시 실패하므로, 그 메시지를
  ⚠ 배너 사유로 그대로 쓰고 1회 설정 명령을 안내한다. **이 스킬이 사용자 설정을 대신 쓰지 않는다.**
- glab/gh는 이 스킬에서 직접 쓰지 않는다(로컬 워킹트리 전용).

## 인자 파싱

| 토큰 | 효과 | 기본 |
|------|------|------|
| `base:<ref>` | diff base 명시(세 엔진에 동일 주입) | 자동 감지 |
| `model:<alias>` | 이번 실행의 엔진 B 모델 → `--ocr-model` | 엔진 B 설정값 |
| `level:<low\|medium\|high\|xhigh\|max>` | 이번 실행의 엔진 C effort → `--ship-level` | 엔진 C 설정값 |
| `fix` | 리포트 후 수정 범위를 사용자와 상의해 적용 | 리포트만 |

- 스킬과 함께 설치된 `run_engine.py`를 Python 3으로 호출한다(Windows에서 `py -3` 사용 가능).
  호출 중인 호스트를 `HOST`로 기록한다. Claude Code에서는 `claude`, Codex에서는 `codex`다.
  대상 저장소에서 `run_engine.py resolve --host <HOST>`로 설정을 확인한다. 설정 오류는 리뷰 전에 보고한다.
- 저장소 루트의 `.cross-review-ship.json`, 사용자 홈의 동명 파일 순서로 첫 파일을 읽는다.
  생략한 엔진은 기본값을 쓴다. 기본 모델은 Claude 계열 엔진에 `claude-sonnet-5-5`,
  Codex에서 실행하는 엔진 A에 `gpt-6-luna`다. effort는 모두 `medium`이다.
- `max`는 인자 또는 설정에서 명시한 경우에만 사용한다. `ultra`(클라우드 리뷰)는 받지 않는다.
- 인식한 토큰은 제거하고 나머지는 무시한다(로컬 전용이라 PR/브랜치 타깃은 받지 않음).
  PR을 교차 검증하려면 "먼저 `glab mr checkout <id>`(또는 `gh pr checkout`)로 체크아웃한 뒤
  `/cross-review-ship` 실행"을 안내한다.

## Step 1 — 스코프 산정 (스냅샷 커밋)

`base:` 인자가 있으면 `BASE_ARG`에, 없으면 기본 브랜치에서 merge-base를 잡는다.
**임시 인덱스**로 워킹트리 전체(추적 파일의 staged+unstaged + `.gitignore`를 존중한
미추적 파일)를 스냅샷 커밋 `WT`로 만든다. 실제 워킹트리와 인덱스는 바뀌지 않는다.

`run_engine.py snapshot --host <HOST>`를 실행한다. `base:`를 받았으면 `--base <ref>`를
추가한다. JSON 결과의 `base`와 `snapshot`을 각각 `BASE`, `WT`로 기록하고
`untracked` 배열을 `UNTRACKED`로 보관한다. 스냅샷 커밋은 ref에 연결되지 않아 Git이 나중에 정리한다.

- **스코프 비대칭(중요):** 엔진 B와 C는 `WT` 스냅샷 범위를 보므로 미추적 파일까지 리뷰한다.
  ce-code-review는 `base:` 모드에서 미추적 파일을 **범위 밖**으로 둔다(staged가 아니면 Coverage에만
  적음). 따라서 `UNTRACKED` 경로에 대한 B·C 지적은 "ce 사각지대"가 아니라 **"ce 범위 밖"**이다.
  이 구역에서는 B·C 둘 사이의 합의만 판정한다(Step 4/5). 사용자가 세 엔진 모두에서 검토받길
  원하면 해당 파일을 `git add` 후 재실행하도록 리포트에 안내한다.

## Step 2 — 세 엔진 실행

세 엔진은 `run_engine.py`로 실행한다. 아래 명령의 `RUNNER`는 이 스킬에 포함된 스크립트의
절대 경로다. `PYTHON`은 Python 3 실행 명령이다. 인자와 경로는 현재 셸에서 안전하게 인용한다.
엔진 B의 `ocr`는 내부에서 `claude -p` 자식 프로세스를 띄운다. A와 C는 각각 별도의
CLI 세션에서 서브에이전트를 쓰므로 차례로 실행한다.

1. 호스트의 백그라운드 명령 실행 도구로 엔진 B를 먼저 시작한다.
2. 엔진 A를 실행하고 결과 JSON을 기록한다.
3. 엔진 C를 실행하고 결과를 기록한다.
4. 호스트의 완료 알림 또는 명령 세션 대기로 엔진 B가 끝나면 결과 파일을 읽는다.

### Step 2B — 엔진 B: ocr review (anthropic-oauth)

```bash
# OUT은 호스트의 임시 디렉터리에 잡은 출력 파일 경로
"$PYTHON" "$RUNNER" ocr --host "$HOST" --base "$BASE" --snapshot "$WT" --output "$OUT"
echo "exit=$? out=$OUT"
```

- `model:` 인자가 있으면 `--ocr-model <MODEL>`을 추가한다. 실행기는 OCR에 `--model`을 넘기고,
  자식 Claude의 effort는 `CLAUDE_CODE_EFFORT_LEVEL`로 지정한다. OCR 동시성은 2다.
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

`run_engine.py ce --host <HOST> --base <BASE>`로 `ce-code-review`에
**`mode:agent depth:full base:<BASE>`**를 전달한다(검토 전용, JSON 반환).
Claude는 모델과 effort를 지정한 `claude -p`에서, Codex는 `codex exec`에서 실행한다.
Codex의 CE 서브에이전트에도 같은 값을 지정하라는 지시를 전달한다.

- **`depth:full` 필수.** ce의 `mode:agent`는 quick-review 단축만 우회하고, 깊이 게이트
  (lite / focused / full)는 그대로 탄다. lite가 선택되면 **호출한 컨텍스트(= 이 메인 대화)
  에서 단독 리뷰**하므로, 작업 세션 맥락에 오염되지 않은 독립 리뷰라는 교차 검증의 전제가
  깨진다. `depth:full`은 다중 에이전트 경로를 강제한다.
- 반환된 **단일 raw JSON**을 파싱:
  - `status == "failed" | "degraded"` → ce 실패로 기록(에러 격리). `findings` 없음.
  - `status == "skipped"` → 사유 기록 후 ce 없이 진행.
  - `status == "complete"` → `findings[]`(전체, `actionable_findings` 아님)를 Step 3 규칙으로 정규화.

### Step 2C — 엔진 C: ship 리뷰 (code-review)

`run_engine.py ship --host <HOST> --base <BASE> --snapshot <WT>`로 실행한다.
`level:`이 있으면 `--ship-level <LEVEL>`을 추가한다. 실행기는 두 호스트에서 모두
모델과 effort를 지정한 `claude -p`에 내장 스킬 호출을 전달한다.

```
/code-review <effort> <BASE 전체 SHA>...<WT 전체 SHA>
```

- **타깃은 반드시 `BASE...WT` 범위 형식**으로 준다. code-review는 `a...b`/`a..b` 범위를 타깃으로
  받아 그 diff만 리뷰한다. 타깃을 비우면 `@{upstream}...HEAD` + 워킹트리를 스스로 찾으므로
  다른 엔진과 범위가 어긋난다. `WT`가 미추적 파일까지 담은 스냅샷이라 엔진 B와 범위가 같다.
- **`--fix`, `--comment`, `--max-findings`는 넘기지 않는다.** 리뷰만 받는다(수정은 이 스킬의
  `fix` 단계에서 상의 후 적용). findings 상한은 code-review 기본값을 따른다.
- code-review는 CLI에서 **fork 컨텍스트**(대화 기록 없는 격리 서브에이전트)로 돈다. 따라서
  ce의 `depth:full` 같은 독립성 강제 옵션이 따로 필요 없다.
- 반환 형태와 파싱:
  - 정상: `N findings (…): ` 다음에 번호 목록. 각 항목은
    ``<번호>. [🔴 Important | 🟣 Pre-existing | 🟡 Nit] `<file>:<line>`: <summary>``
    한 줄과, 이어지는 `Failure scenario: <시나리오>` 줄로 이뤄진다. 심각도 라벨과 `:<line>`은
    없을 수 있다. 앞에 레벨 안내 한 줄("No effort level given — …")이 붙을 수 있으니 무시한다.
  - 반환이 `[`로 시작하면 JSON 배열(`[{file, line, summary, failure_scenario, severity?}]`)이므로
    그대로 파싱한다.
  - `Code review found no issues.` 또는 `[]` → findings 0(정상).
  - CLI 호출 오류, 위 두 형식 어느 것으로도 읽히지 않는 응답 → 엔진 C 전체 실패(에러 격리).
    읽히지 않은 응답 원문 앞부분 200자를 배너 사유에 붙인다.
- 엔진 상태줄에는 설정에서 해석한 모델과 effort(호출 인자 우선), findings 수를 쓴다.

## Step 3 — 정규화

공통 스키마:

```
{ engine: "ce" | "ocr" | "ship",
  severity: "P0"|"P1"|"P2"|"P3",       // 통일 축
  severity_orig: "<원본 라벨>",         // ce: P0-P3 / ocr: critical|high|medium|low / ship: important|pre_existing|nit|none
  category: "<ocr category | null>",    // bug|security|performance|maintainability|test|style|documentation|other
  file: "<경로>",
  start_line: <int>, end_line: <int>,   // 라인 미상이면 0,0
  claim: "<이슈 서술>",
  suggestion: "<제안 or null>",
  untracked: <bool> }                   // file ∈ UNTRACKED (ocr·ship만 true 가능)
```

- **ce → 정규화:** `findings[]` 각 항목의 `severity`(그대로), `file`, `line`(start=end=line),
  `title` + `. ` + `why_it_matters` → `claim`, `suggested_fix` → `suggestion`, `category: null`,
  `untracked: false`.
- **ocr → 정규화:** `comments[]` 각 항목의 `path` → `file`, `start_line`/`end_line`,
  `content` → `claim`, `suggestion_code` → `suggestion`(빈 문자열이면 null), `category` 보존.
  severity: `critical→P0`, `high→P1`, `medium→P2`, `low→P3`(엔진이 low도 내보내므로 **버리지 않는다**).
  severity가 비어 있으면 `P2`. `untracked = file ∈ UNTRACKED`.
- **ship → 정규화:** 각 항목의 `file`, `line`(start=end=line, 없으면 0),
  `summary` + ` 실패 시나리오: ` + `failure_scenario` → `claim`, `category: null`.
  `summary`에 `Fix:`가 있으면 그 뒤 문장을 `suggestion`으로 떼어 내고, 없으면 `null`.
  severity: `important→P1`, `pre_existing→P2`, `nit→P3`, 라벨 없음→`P2`.
  `untracked = file ∈ UNTRACKED`.
  - `important`는 "이 변경이 만든 버그"라 P0/P1을 구분하지 않는다. P1로 두고, 합의 병합에서
    다른 엔진이 P0이면 보수 규칙으로 P0이 된다.
- `existing_code`, `thinking`은 버린다(adjudicator 입력을 작게 유지).

## Step 4 — adjudicator 서브에이전트 (병합 / 합의 판정)

**신선 격리 서브에이전트**를 1개 띄운다. Claude Code는 Agent 도구의 `general-purpose`,
Codex는 `spawn_agent`의 `fork_turns: none`을 쓴다.
입력은 정규화된 세 리스트(JSON 데이터)와 저장소 루트 절대경로뿐. **작업 세션의 코드 의도나
광역 컨텍스트를 절대 전달하지 않는다.** 실패한 엔진의 리스트는 빈 배열로 넘기고, 살아 있는
엔진이 하나뿐이면 adjudicator를 건너뛴다(에러 격리 참고).

아래 프롬프트를 그대로 전달:

> 너는 세 코드리뷰 엔진(ce, ocr, ship)의 findings를 병합하는 판정자다. 아래 세 JSON 리스트만
> 근거로 판단하라. 작업 세션의 코드 의도나 광역 컨텍스트를 추정하지 말 것.
>
> **같은 이슈 판정(두 finding 사이):** ① 같은 file, AND ② 라인 범위가 겹치거나
> 3줄 이내로 근접(어느 쪽 start_line/end_line이 0이면 라인 무시하고 file+클레임으로만 판단),
> AND ③ 두 claim이 같은 문제를 가리킴. ③이 애매하면 `repo_root` 기준으로 해당 `file`의
> `start_line` 근방만 Read로 대조하되, 그 파일의 광역 로직 추정은 금지.
>
> **클러스터링:** 같은 이슈인 finding들을 한 클러스터로 묶는다. 모든 입력 finding은 정확히
> 하나의 클러스터에 들어간다(빠뜨리거나 두 번 넣지 말 것). 한 엔진이 같은 이슈를 여러 번
> 냈으면 같은 클러스터에 함께 넣는다. `untracked: true`인 finding은 `untracked: true`인
> finding과만 묶는다(ce는 그 파일을 보지 않았다).
>
> **병합 규칙:** 클러스터의 `engines`는 포함된 엔진 이름(중복 없이, `ce`→`ocr`→`ship` 순).
> severity는 포함된 finding 중 **가장 높은(보수적) 값**. `start_line`/`end_line`은 범위의
> **합집합**(작은 start, 큰 end, 0은 무시하고 모두 0이면 0). ocr finding의 `category`가 있으면
> 옮긴다. `issue`는 클러스터 전체를 한 서술로, `suggestion`은 가장 구체적인 제안을 고른다.
>
> **출력:** 아래 스키마의 raw JSON만 출력(코드펜스 금지). 한국어 issue 서술.
> Report in Korean.
>
> repo_root = &lt;저장소 루트 절대경로&gt;
> ce_findings = &lt;정규화 ce 리스트&gt;
> ocr_findings = &lt;정규화 ocr 리스트&gt;
> ship_findings = &lt;정규화 ship 리스트&gt;

출력 스키마:

```json
{ "clusters": [
    {"engines":["ce","ocr","ship"],"severity":"","file":"","start_line":0,"end_line":0,
     "issue":"","suggestion":"","category":"","untracked":false,
     "refs":{"ce":[0],"ocr":[0],"ship":[0]}}
  ] }
```

- `refs`는 엔진별 입력 리스트 인덱스 배열(해당 엔진이 없으면 빈 배열).
- **스키마 검증:** Agent 도구에는 JSON 스키마 강제가 없다. 반환 텍스트의 앞뒤 ` ```json `/` ``` `
  코드펜스를 제거한 뒤 `python3 -c json.loads`로 파싱한다. 실패하면 "위 스키마의 raw JSON만,
  코드펜스 없이 다시 출력"으로 1회 재요청.
- **누락 검증:** 세 리스트의 모든 인덱스가 `refs`에 정확히 한 번씩 나오는지 확인한다. 빠진
  finding은 단독 클러스터(`engines`=그 엔진 하나)로 직접 추가하고, 두 번 나온 finding은 첫
  클러스터에만 남긴다. 보정한 건수를 리포트 하단에 한 줄로 적는다.
- adjudicator가 실패하거나 빈 응답이면 병합 없이 각 엔진 리스트를 단독 구역으로 리포트하고 그 사실을 명시한다.

## Step 5 — 리포트 (한국어)

클러스터를 다음 구역으로 나눈다.

| 구역 | 조건 |
|---|---|
| ★★ 세 엔진 합의 | `untracked: false`, `engines` 3개 |
| ★ 두 엔진 합의 | `untracked: false`, `engines` 2개 (제목 줄에 조합 표기: `ce+ocr` 등) |
| ce 단독 / ocr 단독 / ship 단독 | `untracked: false`, `engines` 1개 |
| ce 범위 밖 (미추적 파일) | `untracked: true` (ocr+ship 합의 → 단독 순) |

정렬: 위 표 순서, 각 구역 안에서 severity 내림차순(P0→P3).

**출력은 그대로 MR/PR 리뷰 댓글로 붙여넣을 수 있는 통일된 블록 형식**이다. 각 finding을
`위치 / 이슈 / 제안` 3요소로 렌더링하며, 표가 아니라 항목 블록으로 쓴다(댓글 붙여넣기·모바일
가독성·긴 서술 수용). 세 요소는 항상 이 순서·이 라벨로 고정한다.

```
## Cross-Review Ship 결과  (base: <BASE 짧은sha>, N개 파일)

**엔진:** ce-code-review ✓ (<model>, <effort>, depth:full) / ocr review ✓ (<model>, <effort>, <elapsed>, <total_tokens> tok) / ship 리뷰 ✓ (<model>, <effort>)
**3엔진 합의 {n3} · 2엔진 합의 {n2} · ce 단독 {ce} · ocr 단독 {ocr} · ship 단독 {ship} · ce 범위 밖 {out}**

### ★★ 세 엔진 합의 (최고 신뢰)

#### 1. {severity} — {한 줄 제목}
> ⭐⭐ {세 엔진이 각각 어떤 관점으로 같은 문제에 수렴했는지}
- **위치:** `file:start_line`
- **이슈:**
  - {쉬운 말 개조식 불릿 1 — 무슨 일이 벌어지는지}
  - {불릿 2 — 왜 문제인지 / 언제 터지는지}
  - {필요시 불릿 3 — 결과·영향}
- **제안:** {구체적 수정. 코드 조각이 명확히 도움되면 ```블록``` 포함}

### ★ 두 엔진 합의 (고신뢰)

#### 2. {severity} · ce+ship — {제목}
> ⭐ {두 엔진이 수렴한 근거}
- **위치:** ...
- **이슈:** ...
- **제안:** ...

### ce 단독 (ocr·ship 사각지대?)
### ocr 단독 (ce·ship 사각지대? — 엔진 REVIEW_FILTER 통과분)
#### 3. {severity} · {분류} — {제목}
### ship 단독 (ce·ocr 사각지대? — code-review verify 통과분)

### ce 범위 밖 (미추적 파일 — ocr·ship만 검토)
> 미추적 파일은 ce-code-review가 검토하지 않는다. 세 엔진 교차가 필요하면 `git add` 후 재실행.

#### 4. {severity} · ocr+ship — {제목}
- **위치:** ...
- **이슈:** ...
- **제안:** ...

**교차 검증 핵심**
- 세 엔진이 함께 잡은 것: ... / 엔진별 사각지대: ce ... · ocr ... · ship ...

**판정:** Ready | Ready with fixes | Not ready — 우선 착수: #1, #2
```

- **번호는 전체 구역 통틀어 단조 증가**(위 표 순서, 각 구역 안 severity 내림차순).
  댓글에서 "#2 관련해서…"로 참조 가능하게.
- **이슈는 개조식 불릿, 쉬운 말 우선.** `claim`/`issue`의 서술을 그대로 붙여넣지 말고, 비전문가도
  이해할 짧은 불릿로 풀어 쓴다(전문 용어는 괄호로 보조). 코드의 *증상*과 *왜/언제 터지는지*를
  먼저, 메커니즘은 뒤에. 한 finding당 불릿 1~3개.
- **제안은 실행 가능하게.** 한 줄로 충분하면 한 줄, 코드 조각이 이해를 확실히 돕는 경우(예: 3줄
  가드 추가)만 fenced 코드블록을 넣는다. ship finding처럼 `suggestion`이 null이면 이슈에서
  수정 방향을 끌어내 한 줄로 쓴다.
- 합의 구역 항목엔 제목 아래 `> ⭐⭐`(3엔진) 또는 `> ⭐`(2엔진) 한 줄로 고신뢰 근거를 덧붙인다.
- **마무리 블록(권장):** finding들 뒤에 `**교차 검증 핵심**`과 `**판정**`(Ready / Ready with fixes /
  Not ready + 우선 착수 항목)을 붙인다. 같은 함수·같은 근본원인으로 묶이는 finding은 "한 번에
  처리" 힌트를 준다.
- `N개 파일` = `git diff --name-only $BASE $WT` 파일 수(엔진 B가 살아 있으면 `manifest.coverage.selected` 수와 대조).
- 엔진 B가 `partial`이면 엔진 줄 아래에 `ocr coverage: <completed>/<selected> (실패: <path> — <classification>, …)`.
- 위치는 `file:start_line`(`end_line`>`start_line`이면 `file:start-end`). `start_line`이 0이면 `file(라인미상)`.
- `분류`는 ocr `category`(제목 줄의 `{severity} · {분류}`). 비면 생략. 합의 구역에서는 엔진 조합 표기를 먼저 쓴다.
- `**엔진:**` 상태줄은 실제 결과와 맞춘다. 실패/미실행 엔진은 `✗`로 표시하고 ⚠ 배너와 모순되지 않게 한다.
- 각 구역이 비면 "해당 없음" 한 줄. 미추적 파일이 없으면 마지막 구역은 생략. 모든 엔진 findings가
  0이면 "지적 없음"으로 보고. 기본은 리포트 전용(파일 저장은 요청 시).

## 에러 격리

- **엔진 전체 실패 판정:**
  - ce: `status: failed/degraded` 또는 스킬 미설치.
  - ocr: 사전 점검 실패, 0이 아닌 종료 코드, `status: failed`, JSON 파싱 실패. `partial`은 전체 실패가 아니다.
  - ship: CLI 호출 오류, 반환 형식 파싱 실패.
- 일부 엔진이 실패해도 **중단하지 않는다.** 상단에 `⚠ <엔진> 실패(<사유>): 나머지 엔진 결과만 표시`를
  엔진마다 붙이고 상태줄의 해당 엔진을 `✗`로 표시한다.
  - **두 엔진이 살아 있으면** adjudicator를 그대로 돌리되 죽은 엔진 리스트는 빈 배열로 넘긴다.
    "세 엔진 합의" 구역은 "해당 없음(<엔진> 실패)"으로 쓴다.
  - **한 엔진만 살아 있으면** adjudicator를 건너뛴다. 그 엔진 findings를 전부 해당 엔진 단독 구역에
    넣고(미추적 파일은 ce 범위 밖 구역), 합의는 0. 단독 구역의 **이슈** 요소는 정규화 `claim`을
    근거로 하되 Step 5 규칙대로 쉬운 말 개조식 불릿로 풀어 쓴다.
- ce가 죽어도 미추적 파일 구역 분리는 유지한다(그래야 ocr·ship 결과의 의미가 이 스킬 전체에서 같다).
- 세 엔진 모두 실패 → 실패 사유를 명시하고 종료.
- 엔진 B 실패 사유로 흔한 것: `provider "anthropic-oauth" is not configured`(1회 설정 누락),
  `Claude subscription login required`(구독 로그인 아님), 구독 사용량 한도 도달. 사유를 배너에 그대로 쓴다.

## PR/브랜치 안내

로컬 워킹트리 전용이다. PR을 교차 검증하려면 먼저 `glab mr checkout <id>`로 MR 브랜치를
체크아웃한 뒤 `/cross-review-ship`를 실행하도록 안내한다. PR을 올리면서 리뷰·감시까지 맡기려면
사용자가 직접 `/ship`을 입력해야 한다(이 스킬은 `/ship`을 부르지 않는다).

## fix (선택)

`fix` 인자가 없으면 리포트만 하고 종료한다. `fix`가 있으면 리포트를 먼저 보여준 뒤,
**어디까지 고칠지 사용자와 상의**한다(예: ★★/★ 합의 P0/P1만, 또는 사용자가 지정한 항목). 정한
수정 대상에 대해서만 `suggestion`을 근거로 Edit로 적용하고, 적용분을 리포트 하단에 요약한다.
자동 일괄 적용은 하지 않는다.
