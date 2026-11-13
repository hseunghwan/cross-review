# `/cross-review` 스킬 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `ce-code-review`와 `open-code-review-local` 두 리뷰 엔진을 동일 diff로 독립 실행하고, 결과를 격리 서브에이전트가 병합·합의 태깅한 단일 한국어 리포트를 내는 `/cross-review` 스킬을 만든다.

**Architecture:** 얇은 오케스트레이션 레이어. 엔진 A(`ce-code-review`)는 Skill 도구로 `mode:agent` 호출해 JSON을 받고, 엔진 B(`open-code-review-local`)는 agent 모드가 없어 그 파이프라인을 직접 실행해 구조화 코멘트를 모은다. 두 결과를 공통 스키마로 정규화한 뒤, **신선 컨텍스트의 adjudicator 서브에이전트**가 데이터만 받아 병합/합의 판정한다.

**Tech Stack:** Markdown 스킬(SKILL.md), bash(git/ocr core), Skill 도구, Agent(서브에이전트) 도구. 코드 리뷰 대상 저장소는 임의(로컬 워킹트리).

## Global Constraints

- **언어:** 리포트·문서·서브에이전트 응답 모두 한국어 (전역 지침). 코드 식별자/명령/고유명사는 원문 유지.
- **스킬 위치:** `~/.claude/skills/cross-review/`. 이 경로는 **git 저장소가 아님** → 각 태스크는 `git commit` 대신 **"체크포인트"**(파일 저장 + 검증 관찰)로 종료. (마지막에 선택적 버전관리 안내.)
- **스코프:** 로컬 워킹트리 전용. base 자동감지 또는 `base:<ref>`.
- **스코프 정합성 불변식:** ocr에 주는 diff는 ce의 `git diff $BASE`와 반드시 동일해야 한다 → `WT=$(git stash create); WT=${WT:-HEAD}` 후 `ocr core diff --from $BASE --to $WT`. (비파괴, 검증 완료.)
- **REVIEW_FILTER:** 항상 ON (인자 아님).
- **얇은 레이어 원칙:** `ce-code-review`/`open-code-review-local`을 **재구현하지 않는다**. ce는 Skill 도구 호출, ocr은 그 스킬의 Step 1~4를 그대로 따른다(상세는 해당 SKILL.md 참조).
- **fix:** 기본 off (리포트 전용). `fix` 인자 시 리포트 후 수정 범위를 사용자와 상의해 적용.
- **adjudicator:** 반드시 신선 격리 서브에이전트. 입력은 정규화 findings JSON "데이터"만(작업 히스토리·광역 코드 컨텍스트 없음).

---

### Task 1: 스킬 스캐폴드 + 스코프 산정 (결정론적·단위 테스트 가능)

**Files:**
- Create: `~/.claude/skills/cross-review/SKILL.md`
- Test(임시): `/tmp/claude-1000/-data-workspace-weboffice/857d2eeb-a4f4-4389-889a-104ae5dac3ee/scratchpad/t1repo/` (스크래치 git 저장소)

**Interfaces:**
- Produces: SKILL.md의 프론트매터, `## 사전 점검`, `## 인자 파싱`, `## Step 1 — 스코프 산정` 섹션. 스코프 산정이 산출하는 셸 변수 계약: `BASE`(merge-base SHA), `WT`(워킹트리 스냅샷 커밋 SHA 또는 `HEAD`).

- [ ] **Step 1: SKILL.md 프론트매터 + 사전 점검 + 인자 파싱 작성**

`~/.claude/skills/cross-review/SKILL.md` 생성:

````markdown
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

## 사전 점검

```bash
ocr core -h >/dev/null 2>&1 || echo "FATAL: ocr core 없음 — open-code-review-local 사용 불가"
```
- `ce-code-review` 스킬이 설치돼 있어야 한다(Skill 도구로 호출). 없으면 ocr 단독으로 진행하고 리포트에 명시.
- glab은 이 스킬에서 직접 쓰지 않는다(로컬 워킹트리 전용).

## 인자 파싱

| 토큰 | 효과 | 기본 |
|------|------|------|
| `base:<ref>` | diff base 명시(ce/ocr 양쪽에 동일 주입) | 자동 감지 |
| `fix` | 리포트 후 수정 범위를 사용자와 상의해 적용 | 리포트만 |

인식한 토큰은 제거하고 나머지는 무시(로컬 전용이라 PR/브랜치 타깃 안 받음). PR을 교차
검증하려면 "먼저 `glab mr checkout <id>`로 체크아웃한 뒤 `/cross-review` 실행"을 안내한다.
````

- [ ] **Step 2: Step 1(스코프 산정) 섹션 작성**

SKILL.md에 이어서:

````markdown
## Step 1 — 스코프 산정 (로컬 워킹트리 전용)

`base:` 인자가 있으면 `BASE_ARG`에, 없으면 기본 브랜치에서 merge-base를 잡는다.
`git stash create`로 워킹트리(추적 파일의 staged+unstaged)를 **비파괴** 스냅샷해,
ce의 `git diff $BASE`와 동일한 base..워킹트리 범위를 ocr에도 준다.

```bash
BASE_REF="${BASE_ARG:-$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/@@')}"
BASE_REF="${BASE_REF:-origin/HEAD}"
BASE=$(git merge-base HEAD "$BASE_REF" 2>/dev/null) || BASE=$(git rev-parse "$BASE_REF" 2>/dev/null)
[ -z "$BASE" ] && { echo "FATAL: base 미해결 — base:<ref>로 명시하세요"; exit 1; }
WT=$(git stash create); WT="${WT:-HEAD}"   # 빈 값(클린 트리) → HEAD
echo "BASE=$BASE  WT=$WT"
```

- ce 엔진에는 `base:$BASE`를 전달한다(ce는 `git diff $BASE`로 base..워킹트리를 본다).
- ocr 엔진에는 `--from $BASE --to $WT`를 전달한다(동일 범위).
````

- [ ] **Step 3: 스코프 정합성 테스트 — 스크래치 저장소 구성**

Run:
```bash
T1=/tmp/claude-1000/-data-workspace-weboffice/857d2eeb-a4f4-4389-889a-104ae5dac3ee/scratchpad/t1repo
rm -rf "$T1"; mkdir -p "$T1"; cd "$T1"
git init -q; git config user.email t@t; git config user.name t
printf 'l1\nl2\nl3\n' > a.py; git add a.py; git commit -qm base
BASE=$(git rev-parse HEAD)
printf 'l1\nl2X\nl3\n' > a.py; git commit -qam committed      # 커밋된 변경
printf 'l1\nl2X\nl3\nS\n' > a.py; git add a.py                # staged
printf 'l1\nl2X\nl3\nS\nU\n' > a.py                           # unstaged
echo "GIT_CE=$(git diff --numstat $BASE | awk '{print $1+$2}')"
```
Expected: `GIT_CE=4` (ce 스코프의 add+del 합).

- [ ] **Step 4: 스코프 정합성 테스트 — ocr이 동일 범위를 보는지 확인**

Run:
```bash
cd "$T1"; BASE=$(git rev-parse HEAD~1)
WT=$(git stash create); WT="${WT:-HEAD}"
OCR=$(ocr core diff --repo . --from "$BASE" --to "$WT" | python3 -c "import sys,json;print(sum(f.get('changed_lines',0) for f in json.load(sys.stdin).get('files',[])))")
echo "OCR=$OCR ; STATUS=$(git status --porcelain)"
```
Expected: `OCR=4` (GIT_CE와 일치) 이고 `STATUS=MM a.py`(워킹트리 미변경).
불일치하면 Step 2의 bash를 수정하고 재실행.

- [ ] **Step 5: 체크포인트**

SKILL.md 저장 확인. 스코프 산정이 `BASE`/`WT`를 올바로 산출하고 정합성 테스트가 통과함을 관찰로 확정.

---

### Task 2: 정규화 스키마 + adjudicator 서브에이전트 (핵심 로직, 격리 단위 테스트)

**Files:**
- Modify: `~/.claude/skills/cross-review/SKILL.md` (`## Step 3 — 정규화`, `## Step 4 — adjudicator` 추가)

**Interfaces:**
- Consumes: Task 3이 산출할 `ce_findings[]`, `ocr_findings[]` (아래 정규화 스키마 형태).
- Produces: adjudicator 서브에이전트의 입출력 계약. 출력 스키마: `{ agreed[], ce_only[], ocr_only[], counts }`.

- [ ] **Step 1: 정규화 스키마 섹션 작성**

SKILL.md에 추가:

````markdown
## Step 3 — 정규화

두 엔진 결과를 공통 스키마로 변환한다.

```
{ engine: "ce" | "ocr",
  severity: "P0"|"P1"|"P2"|"P3",
  severity_orig: "<원본 라벨>",       // ce: P0-P3 / ocr: high|medium
  file: "<경로>",
  start_line: <int>, end_line: <int>,  // ocr relocation 실패 시 0,0
  claim: "<이슈 서술>",                // ce: title + '. ' + why_it_matters / ocr: 코멘트 content
  suggestion: "<제안 or null>" }        // ce: suggested_fix / ocr: suggestion_code
```

- **ce → 정규화:** `mode:agent` JSON의 `findings[]`에서 각 항목의
  `severity`(그대로), `file`, `line`(start=end=line), `title`+`why_it_matters`→`claim`,
  `suggested_fix`→`suggestion`. `severity_orig`=원본 severity.
- **ocr → 정규화:** 생존 코멘트에서 `path`→`file`, `start_line`/`end_line`,
  `content`→`claim`, `suggestion_code`→`suggestion`. severity는 Step 4 분류의
  priority 매핑: `high→P1`, `medium→P2`, `low→P3`(low는 ocr이 폐기하므로 사실상 미유입).
  `severity_orig`=high|medium.
````

- [ ] **Step 2: adjudicator 서브에이전트 섹션 작성 (프롬프트 + 출력 스키마)**

SKILL.md에 추가:

````markdown
## Step 4 — adjudicator 서브에이전트 (병합 / 합의 판정)

**신선 격리 서브에이전트**를 1개 띄운다(Agent 도구, `subagent_type: general-purpose`).
입력은 정규화된 두 리스트(JSON 데이터)와 저장소 경로뿐. 다음 프롬프트를 그대로 전달:

> 너는 두 코드리뷰 엔진의 findings를 병합하는 판정자다. 아래 두 JSON 리스트만 근거로
> 판단하라. 작업 세션의 코드 의도나 광역 컨텍스트를 추정하지 말 것.
>
> **합의 판정(두 findings가 "같은 이슈"인가):** ① 같은 file, AND ② 라인 범위가 겹치거나
> 3줄 이내로 근접(어느 쪽 start_line/end_line이 0이면 라인 무시하고 file+클레임으로만 판단),
> AND ③ 두 claim이 같은 문제를 가리킴. ③이 애매하면 해당 `file`의 `start_line` 근방만
> Read로 대조하되, 그 파일의 광역 로직 추정은 금지.
>
> **병합 규칙:** 합의면 `agreed`에 넣고 두 엔진 중 **더 높은(보수적) severity** 채택.
> ce에만 있으면 `ce_only`, ocr에만 있으면 `ocr_only`(각 원 severity 유지).
>
> **출력:** 아래 스키마의 raw JSON만 출력(코드펜스 금지). 한국어 issue 서술.
> Report in Korean.
>
> ce_findings = <정규화 ce 리스트>
> ocr_findings = <정규화 ocr 리스트>

출력 스키마(`schema` 옵션으로 강제 권장):
```json
{ "agreed":   [{"severity":"","file":"","start_line":0,"end_line":0,"issue":"","suggestion":"","ce_ref":0,"ocr_ref":0}],
  "ce_only":  [{"severity":"","file":"","start_line":0,"end_line":0,"issue":"","suggestion":""}],
  "ocr_only": [{"severity":"","file":"","start_line":0,"end_line":0,"issue":"","suggestion":""}],
  "counts":   {"agreed":0,"ce_only":0,"ocr_only":0} }
```
`ce_ref`/`ocr_ref`는 입력 리스트의 인덱스.
````

- [ ] **Step 3: adjudicator 단위 테스트 — 합성 입력 준비**

합성 정규화 리스트를 만든다(겹침 1 + ce단독 1 + ocr단독 1). 스크래치 파일로 저장:

Run:
```bash
T2=/tmp/claude-1000/-data-workspace-weboffice/857d2eeb-a4f4-4389-889a-104ae5dac3ee/scratchpad/t2
mkdir -p "$T2"
cat > "$T2/ce.json" <<'EOF'
[{"engine":"ce","severity":"P0","severity_orig":"P0","file":"auth.js","start_line":42,"end_line":42,"claim":"사용자 입력을 쿼리에 직접 연결해 SQL 인젝션 위험","suggestion":"파라미터 바인딩 사용"},
 {"engine":"ce","severity":"P1","severity_orig":"P1","file":"api.go","start_line":88,"end_line":88,"claim":"nil 포인터 역참조 가능","suggestion":null}]
EOF
cat > "$T2/ocr.json" <<'EOF'
[{"engine":"ocr","severity":"P1","severity_orig":"high","file":"auth.js","start_line":43,"end_line":43,"claim":"쿼리 문자열에 미검증 입력 결합 — 인젝션","suggestion":"prepared statement"},
 {"engine":"ocr","severity":"P2","severity_orig":"medium","file":"util.js","start_line":12,"end_line":12,"claim":"사용하지 않는 변수","suggestion":"제거"}]
EOF
echo "합성 입력 준비 완료"
```
Expected: `auth.js`의 두 항목은 같은 이슈(라인 42 vs 43, ≤3줄, 인젝션) → 합의 1. `api.go`=ce단독, `util.js`=ocr단독.

- [ ] **Step 4: adjudicator 단위 테스트 — 실행 및 검증**

`$T2/ce.json`, `$T2/ocr.json` 내용을 Step 2의 프롬프트에 넣어 Agent 도구로 adjudicator 서브에이전트를 실제 dispatch한다(schema 옵션 사용).

Expected(구조적 검증):
- `counts.agreed == 1` 이고 그 항목의 `file=="auth.js"`, `severity=="P0"`(보수적 채택).
- `counts.ce_only == 1` 이고 `file=="api.go"`.
- `counts.ocr_only == 1` 이고 `file=="util.js"`.
어긋나면 Step 2 프롬프트(합의 기준 문구/라인 근접 규칙)를 조정하고 재실행.

- [ ] **Step 5: 체크포인트**

정규화 스키마와 adjudicator 프롬프트/스키마가 SKILL.md에 있고, 합성 테스트가 통과함을 확정.

---

### Task 3: 엔진 A(ce) + 엔진 B(ocr) 실행·정규화 섹션

**Files:**
- Modify: `~/.claude/skills/cross-review/SKILL.md` (`## Step 2A`, `## Step 2B` 추가; Step 3 정규화 참조)

**Interfaces:**
- Consumes: Task 1의 `BASE`/`WT`. `ce-code-review`(Skill 도구), `open-code-review-local`(Step 1~4 파이프라인).
- Produces: `ce_findings[]`, `ocr_findings[]` (Task 2의 정규화 스키마). 순차 실행.

- [ ] **Step 1: Step 2A(엔진 A — ce-code-review) 섹션 작성**

SKILL.md에 추가(Step 1과 Step 3 사이 배치):

````markdown
## Step 2A — 엔진 A: ce-code-review (mode:agent)

Skill 도구로 `ce-code-review`를 `mode:agent base:<BASE>`로 호출한다(read-only, JSON 반환).
반환된 **단일 raw JSON**을 파싱:

- `status == "failed" | "degraded"` → ce 실패로 기록(Step 5 에러 격리). `findings` 없음.
- `status == "complete"` → `findings[]`를 Step 3 규칙으로 `ce_findings[]`로 정규화.
  (`actionable_findings`가 아니라 전체 `findings`를 쓴다 — 교차 대상은 모든 지적.)
- `ce-code-review` 스킬이 없으면 이 단계를 건너뛰고 ocr 단독 진행(리포트에 명시).
````

- [ ] **Step 2: Step 2B(엔진 B — open-code-review-local) 섹션 작성**

SKILL.md에 추가:

````markdown
## Step 2B — 엔진 B: open-code-review-local (REVIEW_FILTER ON)

`open-code-review-local` 스킬을 **재구현하지 말고 그 SKILL.md의 절차를 따른다**. 단
스코프와 필터만 이 스킬이 고정한다:

1. **Step 1(대상):** `ocr core diff --repo . --from "$BASE" --to "$WT"` (Task 1의 BASE/WT).
   `will_review: true`인 파일만 대상.
2. **Step 2(리뷰):** 파일당 격리 서브에이전트로 리뷰(그 스킬의 2a~2d 파이프라인, relocate 포함).
3. **Step 3(REVIEW_FILTER):** **켠다.** 격리 diff-only 서브에이전트로 거짓양성 필터 패스 실행.
4. **Step 4(분류):** 생존 코멘트를 high/medium/low로 분류(low는 폐기).

생존·분류된 코멘트를 Step 3 규칙으로 `ocr_findings[]`로 정규화한다. `ocr core emit`은
사용하지 않는다(로컬 리포트 전용).

두 엔진은 **순차 실행**한다(각자 서브에이전트를 띄우므로 중첩 스폰 회피). 실제 리뷰는
양쪽 모두 leaf 서브에이전트에서 격리 수행되므로 순서에 따른 오염은 없다.
````

- [ ] **Step 3: 엔진별 정규화 스모크 테스트 (스크래치 diff)**

Task 1의 `$T1` 저장소(또는 작은 실제 변경)에서 실제로 한 번씩 돌려 정규화 출력 형태를 확인:
- ce: Skill 도구 `ce-code-review mode:agent base:$BASE` 호출 → JSON `status`/`findings` 파싱 → `ce_findings[]`가 Task 2 스키마 형태인지.
- ocr: Step 2B 파이프라인 → `ocr_findings[]`가 Task 2 스키마 형태인지.

Expected: 두 리스트 모두 `{engine,severity,file,start_line,end_line,claim,suggestion}` 형태. (findings 개수는 diff에 따라 다름 — 형태만 검증.)

- [ ] **Step 4: 체크포인트**

Step 2A/2B가 SKILL.md에 있고, 두 엔진이 정규화 리스트를 산출함을 확정.

---

### Task 4: 리포트 렌더링 + 에러 격리 + PR 안내 + fix 게이트

**Files:**
- Modify: `~/.claude/skills/cross-review/SKILL.md` (`## Step 5 — 리포트`, `## 에러 격리`, `## fix` 추가)

**Interfaces:**
- Consumes: Task 2 adjudicator 출력 `{agreed[], ce_only[], ocr_only[], counts}`.
- Produces: 최종 사용자 리포트(한국어), 에러 배너 규칙, fix 동작.

- [ ] **Step 1: Step 5(리포트) 섹션 작성**

SKILL.md에 추가:

````markdown
## Step 5 — 리포트 (한국어)

adjudicator 출력으로 아래 형식을 렌더링한다. 정렬: 합의 → ce단독 → ocr단독, 각 그룹 내
severity 내림차순(P0→P3).

```
## Cross-Review 결과  (base: <BASE 짧은sha>, N개 파일)

**엔진:** ce-code-review ✓ / open-code-review-local ✓ (REVIEW_FILTER on)
**합의 {counts.agreed} · ce-단독 {counts.ce_only} · ocr-단독 {counts.ocr_only}**

### ★ 합의 (고신뢰 — 두 엔진 모두 지적)
| 심각도 | 위치 | 이슈 | 제안 |
|--------|------|------|------|
| P0 | auth.js:42 | SQL 인젝션 위험 | 파라미터 바인딩 |

### ce 단독 (ocr 사각지대?)
| 심각도 | 위치 | 이슈 | 제안 |

### ocr 단독 (ce 사각지대? — 필터 통과분이라 신뢰도 있음)
| 심각도 | 위치 | 이슈 | 제안 |
```
- 위치는 `file:start_line`. start_line이 0이면 `file(라인미상)`.
- 각 그룹이 비면 "해당 없음" 한 줄. 기본은 리포트 전용(파일 저장은 요청 시).
````

- [ ] **Step 2: 에러 격리 + PR 안내 섹션 작성**

SKILL.md에 추가:

````markdown
## 에러 격리

- 한 엔진이 통째 실패(ce `status: failed/degraded`, 또는 ocr 파이프라인 예외)해도 **중단하지
  않는다.** 나머지 엔진 결과만으로 리포트하되, 상단에
  `⚠ <엔진> 실패(<사유>): 다른 엔진 결과만 표시`를 붙인다. 이때 adjudicator에는 살아있는
  쪽만 넘기고, 그쪽 findings는 전부 해당 엔진 단독으로 표기.
- 두 엔진 모두 실패 → 실패 사유를 명시하고 종료.

## PR/브랜치 안내

로컬 워킹트리 전용이다. PR을 교차 검증하려면 먼저 `glab mr checkout <id>`로 MR 브랜치를
체크아웃한 뒤 `/cross-review`를 실행하도록 안내한다.
````

- [ ] **Step 3: fix 게이트 섹션 작성**

SKILL.md에 추가:

````markdown
## fix (선택)

`fix` 인자가 없으면 리포트만 하고 종료한다. `fix`가 있으면 리포트를 먼저 보여준 뒤,
**어디까지 고칠지 사용자와 상의**한다(예: 합의 P0/P1만). 합의된 범위에 대해서만
`suggestion`을 근거로 Edit로 적용하고, 적용분을 리포트 하단에 요약한다. 자동 일괄 적용은
하지 않는다.
````

- [ ] **Step 4: 렌더링 검증 (Task 2 합성 출력 재사용)**

Task 2 Step 4의 adjudicator 출력(agreed 1/ce_only 1/ocr_only 1)을 Step 1 형식으로 렌더링해보고:
Expected: 3개 섹션이 모두 나오고, 합의 행이 P0로 최상단, 요약줄이 `합의 1 · ce-단독 1 · ocr-단독 1`.

- [ ] **Step 5: 체크포인트**

리포트/에러/PR/fix 섹션이 SKILL.md에 있고 렌더링 형식이 맞음을 확정.

---

### Task 5: 엔드투엔드 통합 실행 + 반복

**Files:**
- Test: 실제 로컬 변경(작은 브랜치 diff) 또는 `$T1` 스크래치 저장소.

**Interfaces:**
- Consumes: 완성된 `~/.claude/skills/cross-review/SKILL.md` 전체.

- [ ] **Step 1: 통제된 diff에서 `/cross-review` 전체 실행**

의도적으로 결함 1개(예: 인젝션/누락된 null 체크)를 심은 작은 변경을 만든 뒤 `/cross-review` 실행.
Expected: Step 1~5가 순서대로 돌고, 두 엔진이 동일 BASE/WT를 보며, 병합 리포트가 3개 섹션으로 출력.

- [ ] **Step 2: 합의/단독 태깅 정확성 확인**

심은 결함이 (양쪽이 잡으면) 합의에, 한쪽만 잡으면 해당 단독 섹션에 위치하는지 확인.
Expected: 태깅이 실제 findings 출처와 일치.

- [ ] **Step 3: 에러 격리 경로 확인**

`ocr` 실행이 불가한 상황을 흉내(예: `ocr` PATH 제거한 셸에서 실행)해 ce 단독 리포트 + `⚠` 배너가 나오는지 확인.
Expected: 중단 없이 ce 결과만으로 리포트 + 경고 배너.

- [ ] **Step 4: 발견 이슈 수정 + 재실행**

E2E에서 드러난 프롬프트/형식/스코프 문제를 SKILL.md에 반영하고 Step 1을 재실행해 통과 확인.

- [ ] **Step 5: 체크포인트 + (선택) 버전관리 안내**

`/cross-review`가 실사용 가능함을 확정. 사용자가 원하면 `~/.claude/skills/cross-review/`를
별도 git 저장소로 관리하거나 팀 공유(ONBOARDING/스킬 배포)하는 방법을 안내.

---

## Self-Review (작성자 체크)

**1. 스펙 커버리지:** DESIGN.md 각 절 → 태스크 매핑:
- 대칭 병합+합의 태깅 → Task 2(adjudicator)+Task 4(리포트). ✓
- 새 스킬 패키징 → Task 1(스캐폴드). ✓
- 격리 adjudicator(신선 컨텍스트) → Task 2. ✓
- REVIEW_FILTER ON → Task 3 Step 2B. ✓
- 로컬 전용 + 동일 스코프 강제 → Task 1(stash create 정합성). ✓
- fix off + PR 안내 → Task 4. ✓
- 에러 격리 → Task 4 Step 2 + Task 5 Step 3. ✓
- ocr 스코프 정합성(구현 시 확인 항목) → Task 1에서 `git stash create`로 **해소**. ✓
- 한국어 출력 → Global Constraints + Task 4. ✓

**2. 플레이스홀더 스캔:** TBD/TODO/"적절히 처리" 없음. 모든 bash·프롬프트·스키마 실물 기재. ✓

**3. 타입/명칭 일관성:** `BASE`/`WT`(Task 1)↔(Task 3 사용) 일치. 정규화 스키마 필드
(`engine/severity/severity_orig/file/start_line/end_line/claim/suggestion`)가 Task 2·3·4에서 동일. adjudicator 출력 키(`agreed/ce_only/ocr_only/counts`)가 Task 2·4에서 동일. ✓
