# `/cross-review` 설계 문서

- **작성일:** 2026-07-02
- **상태:** 설계 승인 대기 (구현 전)
- **배경:** 사용자는 현재 `/ce-code-review`를 상시 사용 중. MR 보내기 전 로컬에서
  `ce-code-review`와 `open-code-review-local` **두 독립 리뷰 엔진을 교차 검증**해
  신뢰도 높은 단일 리뷰 결과를 얻고 싶어 함. 재사용 가능한 형태로 정리 요청.

---

## 1. 목적 & 한 줄 요약

로컬 변경(주로 MR 직전)을 **서로 다른 룰셋을 가진 두 리뷰 엔진으로 각각 독립 검토**한 뒤,
결과를 **병합하고 "어느 엔진이 잡았는지" 태깅**하여, **두 엔진이 함께 지적한 항목을 고신뢰로
승격**한 단일 리포트를 산출한다.

- `ce-code-review` → 페르소나 리뷰어 + 프로젝트 `AGENTS.md`/`CLAUDE.md` 표준 기반 리뷰
- `open-code-review-local` → alibaba `ocr` v1.13.8 파이프라인 + 룰 체크리스트 기반 리뷰 (외부 taxonomy).
  `core` 명령 그룹이 들어간 포크 빌드(v1.13.8+core)가 결정론 단계를, Claude 구독이 판단을 맡는다.
- 두 엔진은 **블라인드 스팟이 다르다**. 교차의 가치는 여기서 나온다:
  - **둘 다 지적** = 고신뢰(must-fix)
  - **한쪽만 지적** = 상대 엔진의 사각지대일 수 있는 신호

이 스킬은 **오케스트레이터 + 병합기**일 뿐, 리뷰 판단을 직접 하지 않는다.

## 2. 핵심 개념: 왜 "교차"인가

`ce-code-review`는 이미 **cross-model**(다른 모델 패밀리를 peer CLI로 돌리는 적대적 패스)을
내장한다. 따라서 이 스킬이 더하는 것은 "다른 모델"이 아니라 **"다른 룰셋/검토 철학"의 교차**다.

리뷰 독립성(= 합의가 의미를 갖는 전제)은 **leaf 서브에이전트 레벨에서 보장**된다:

- `ce-code-review`의 페르소나 리뷰어들은 원본 diff를 각자 격리 컨텍스트에서 독립 검토한다.
- `open-code-review-local`의 파일별 리뷰어들도 diff + rule만 받는 격리 컨텍스트다.
- 따라서 이 스킬을 **방금 코딩한 작업 세션에서 이어 실행해도** 두 엔진의 실제 리뷰는
  작업 세션 컨텍스트에 오염되지 않는다.

## 3. 아키텍처 / 데이터 흐름

```
/cross-review [base:<ref>] [fix]
        │
   [1. 스코프 산정] 현재 브랜치 vs base 자동감지(또는 base:) → BASE(SHA) 확정
        │            (로컬 워킹트리 전용)
        │
   ┌────┴──────────────────────────────────────────┐
   │ [2A] 엔진 A: ce-code-review mode:agent depth:full base:BASE │ → JSON findings
   │      (Skill 도구로 호출, read-only)             │
   │ [2B] 엔진 B: open-code-review-local (동일 BASE) │ → 코멘트 목록
   │      REVIEW_FILTER ON(거짓양성 필터)            │   + priority 분류
   └────┬──────────────────────────────────────────┘  (순차 실행)
        │
   [3. 정규화] 두 결과를 공통 finding 스키마로 변환 (심각도 축 통일)
        │
   [4. adjudicator 서브에이전트]  ★신선 컨텍스트★
        │   입력: 정규화된 ce/ocr findings JSON "데이터"만 (작업 히스토리·코드 컨텍스트 없음)
        │   작업: 합의 판정 → 병합 → 재랭킹  (필요 시 해당 라인만 fresh Read로 대조)
        │   출력: {agreed[], ce_only[], ocr_only[], counts}  (미추적 파일 ocr 지적은 입력 전에 분리)
        │
   [5. 리포트] 병합 표 + 요약(합의 N / ce-단독 N / ocr-단독 N / ce 범위 밖 N) + 단독 항목 사각지대 노트
```

**설계 원칙:** 엔진은 메인에서 순차 실행(자기 서브에이전트를 다시 띄우므로 **중첩 스폰 회피**).
오직 오염에 민감한 **병합/합의 판정만** 격리 adjudicator 서브에이전트로 분리한다.

## 4. 컴포넌트별 명세

### 4.1 스코프 산정
- 로컬 워킹트리 전용. 현재 체크아웃을 리뷰 대상으로 본다.
- base 자동 감지(=`ce-code-review`와 동일 로직) 또는 `base:<ref>` 인자.
- `BASE=$(git merge-base HEAD <base-ref>)` 로 확정한 **단일 SHA**를 두 엔진에 동일 주입한다.
  (같은 diff를 봐야 병합이 의미 있음 — 필수 불변식.)
- 워킹트리는 **임시 인덱스**(`GIT_INDEX_FILE` + `read-tree HEAD` → `add -A` → `write-tree` →
  `commit-tree`)로 스냅샷 커밋 `WT`를 만들어 ocr에 `--from BASE --to WT`로 준다. 실제 인덱스와
  워킹트리는 바뀌지 않는다. `git stash create`는 미추적 파일을 빼서 쓰지 않는다.
- 스냅샷에 들어간 미추적 파일 목록(`git ls-files --others --exclude-standard`)을 `UNTRACKED`로
  함께 기록한다. ce는 `base:` 모드에서 미추적 파일을 보지 않으므로, 이 경로의 ocr 지적은
  합의 판정에서 빼고 "ce 범위 밖" 구역으로 보낸다(4.5, 4.6).

### 4.2 엔진 A — `ce-code-review` (mode:agent depth:full)
- Skill 도구로 `ce-code-review`를 `mode:agent depth:full base:<BASE>`로 호출.
- `mode:agent`는 **read-only**(트리 미변경) + **JSON 단일 객체** 반환 → 파싱.
- `mode:agent`는 quick-review short-circuit**만** 우회한다. 깊이 게이트(lite / focused / full)는
  그대로 타며, lite가 선택되면 호출한 컨텍스트(메인 대화)에서 단독 리뷰한다(ce
  `references/modes-and-output.md`). 그러면 작업 세션 맥락에 오염되지 않은 독립 리뷰라는
  전제가 깨지므로 **`depth:full`로 full spine을 강제**한다. (초기 설계의 "mode:agent가 full을
  강제한다"는 서술은 ce 3.33.0 기준으로 틀렸다.)

### 4.3 엔진 B — `open-code-review-local` (REVIEW_FILTER ON)
- `ocr core diff|group|render`를 모두 **`--from BASE --to WT`**로 실행.
- 스킬 v0.3.0의 v1.13.8 파이프라인: `ocr core group`으로 리뷰 그룹 결정 → 그룹마다 Plan(조건부)
  → Main 라운드(최대 `max_review_rounds`, 확정 코멘트 전달) → relocate. 프롬프트는
  `ocr core render`가 placeholder를 모두 채워 준다.
- **REVIEW_FILTER 켬(고정)**: 라운드마다 격리 diff-only 서브에이전트로 거짓양성 필터 패스 실행 →
  ocr 쪽 findings가 고정밀로 정리됨. (→ "ocr 단독 = 사각지대" 신호 신뢰도 상승)
- 코멘트는 엔진 `code_comment` 스키마대로 `severity`(critical~low)와 `category`를 갖는다.
  `ocr core emit`(CI poster용)은 로컬 리포트엔 불필요 → 코멘트 목록을 직접 정규화에 사용.

### 4.4 정규화
두 엔진 결과를 공통 스키마로:
```
{ engine: "ce" | "ocr",
  severity: "P0"|"P1"|"P2"|"P3",   // 통일 축
  severity_orig: "<원본 라벨>",     // ce: P0-P3 그대로 / ocr: critical|high|medium|low
  category: "<ocr category | null>",
  file, start_line, end_line,
  claim: "<이슈 서술>",             // ce: title+description / ocr: comment content
  suggestion: "<제안 or null>",
  untracked: <bool> }              // file ∈ UNTRACKED
```
- **심각도 정규화(ocr→통일축):** `critical→P0`, `high→P1`, `medium→P2`, `low→P3`.
  (v0.3.0부터 ocr이 low도 내보내므로 버리지 않는다.)

### 4.5 adjudicator 서브에이전트 (병합 / 합의 판정) — 핵심
- **신선한 격리 컨텍스트.** 입력은 정규화된 두 findings 리스트(데이터)뿐. 작업 세션 히스토리·
  코드 광역 컨텍스트를 절대 상속하지 않는다.
- **미추적 파일 분리:** `untracked: true`인 ocr 항목은 adjudicator에 넣지 않고 `ocr_out_of_ce_scope`로
  바로 보낸다. ce가 볼 수 없었던 파일이라, 넣으면 전부 "ocr 단독(ce 사각지대)"으로 잘못 분류된다.
- **합의 판정(두 엔진이 "같은 이슈"로 인정):**
  1. 같은 파일, AND
  2. 라인 범위 겹침 또는 **≤3줄 이내**(두 엔진의 line-pinning 방식 차이 흡수).
     ocr이 relocation 실패로 `line 0,0`을 주면 **라인 무시**, 파일 + 클레임 동일성으로만 매칭.
  3. 두 클레임이 **같은 문제를 가리킴**(서브에이전트의 의미 판단). 애매하면 해당 file:line만
     fresh Read로 대조 — 단 광역 컨텍스트나 작업 의도 추정은 금지.
- **병합 규칙:**
  - 합의(둘 다) → `agreed[]`. 심각도 다르면 **더 높은(보수적) 쪽** 채택.
  - ce 단독 → `ce_only[]` (ce 심각도 유지).
  - ocr 단독 → `ocr_only[]` (ocr 심각도 유지).
- **출력 스키마:**
```
{ "agreed":   [{severity, file, start_line, end_line, issue, suggestion,
                ce_ref, ocr_ref}],
  "ce_only":  [{severity, file, start_line, end_line, issue, suggestion}],
  "ocr_only": [{severity, file, start_line, end_line, issue, suggestion}],
  "counts":   {"agreed": N, "ce_only": N, "ocr_only": N} }
```

### 4.6 리포트 렌더링 (한국어)
```
## Cross-Review Results  (base: <ref>, N files)

**엔진:** ce-code-review ✓ (depth:full) / open-code-review-local ✓ (v1.13.8+core, REVIEW_FILTER on)
**합의 A · ce-단독 B · ocr-단독 C · ce 범위 밖 D**

### ★ 합의 (고신뢰 — 두 엔진 모두 지적)
| 심각도 | 위치 | 이슈 | 제안 |
| P0 | auth.js:42 | SQL injection | 파라미터 바인딩 |

### ce 단독 (ocr 사각지대?)
| 심각도 | 위치 | 이슈 | 제안 |

### ocr 단독 (ce 사각지대? — 필터 통과분이라 신뢰도 있음)
| 심각도 | 분류 | 위치 | 이슈 | 제안 |

### ocr 단독 — ce 범위 밖 (미추적 파일)
| 심각도 | 분류 | 위치 | 이슈 | 제안 |
> 미추적 파일은 ce-code-review가 검토하지 않는다. 양쪽 교차가 필요하면 `git add` 후 재실행.
```
- 정렬: 합의 → ce단독 → ocr단독 → ce 범위 밖, 각 그룹 내 심각도 내림차순.
- 미추적 파일이 없으면 마지막 구역과 요약줄의 `ce 범위 밖`은 생략.
- 기본 **리포트 전용(read-only)**. 파일 저장은 요청 시(스크래치패드 또는 지정 경로).

## 5. 인자 & 기본값

| 인자 | 효과 | 기본 |
|---|---|---|
| (없음) | 현재 브랜치 vs 자동 base, 두 엔진 실행, 리포트만 | ✓ |
| `base:<ref>` | diff base 명시(ce/ocr 양쪽에 동일 SHA 주입) | 자동 감지 |
| `fix` | 리포트 후, 수정 범위를 **사용자와 상의해 결정**한 뒤 적용 | 리포트만 |

- REVIEW_FILTER는 **항상 ON**(인자 아님, 고정).
- `fix`는 자동 적용이 아니라, 리포트를 본 뒤 "어디까지 고칠지" 검토 게이트를 거친다.

## 6. 에러 격리 & 엣지케이스

- **한 엔진 전체 실패 시 중단 금지.** 나머지 엔진 결과를
  `⚠ <엔진> 실패(사유): 다른 엔진 결과만 표시` 배너와 함께 리포트.
- **PR/브랜치 리뷰:** 로컬 워킹트리 전용이므로, PR을 교차 검증하려면 **먼저
  `glab mr checkout <id>`로 MR 브랜치를 체크아웃한 뒤 `/cross-review` 실행**하도록 안내한다.
  (사용자 현행 워크플로가 이미 이 방식이라 자연스러움.)
- **ocr 스코프 정합성(해결):** `ce-code-review`는 `merge-base..워킹트리`(커밋 + 스테이징 +
  미스테이징, 미추적 제외)를 본다. ocr에는 임시 인덱스 스냅샷 `WT`를 `--from BASE --to WT`로
  준다(4.1). 스냅샷은 미추적 파일까지 담으므로, 그 경로의 ocr 지적은 "ce 범위 밖"으로 분리한다.
- **ce가 죽고 ocr만 살아도** 미추적 파일 구역 분리는 유지한다.
- **매칭 실패 유형:** ocr `line 0,0`은 4.5의 파일+클레임 매칭으로 흡수. ce/ocr 심각도 축
  불일치는 4.4 매핑으로 흡수.

## 7. 파일 배치

```
cross-review/                       # 저장소 루트 (v1·v2·ocr 포크를 함께 관리)
├── skills/cross-review/SKILL.md    # 오케스트레이션 절차(위 1~6을 실행 가능한 지시로) + adjudicator 프롬프트/스키마
├── skills/open-code-review-local/  # 엔진 B 스킬 (v0.3.0, ocr core 사용)
├── ocr/                            # ocr 포크 패치 + build.sh
└── docs/DESIGN-v1.md               # 이 문서
```
`install.sh`가 `skills/cross-review`를 `~/.claude/skills/cross-review`로 링크한다.
- `ce-code-review`/`open-code-review-local`을 **재구현하지 않고 Skill 도구로 호출만** 하는
  얇은 조합 레이어.

## 8. 비목표 (Out of Scope / YAGNI)

- MR/PR에 댓글 자동 게시 (별도 논의 주제였음 — 이 스킬은 로컬 리포트 전용).
- 순차 반박 사이클(핑퐁) — 대칭 병합으로 충분, 이번 범위 아님.
- 원격 PR 직접 리뷰(체크아웃 없이) — 로컬 전용으로 못박음.
- ocr `emit`/CI poster 연동.

## 9. 성공 기준

1. `/cross-review` 한 번으로 두 엔진이 동일 diff를 독립 검토하고, 병합 리포트가 나온다.
2. 합의 항목이 `★ 고신뢰`로 최상단에 오고, 단독 항목이 엔진 태그와 함께 구분된다.
3. 병합/합의 판정이 신선 컨텍스트(격리 서브에이전트)에서 이뤄져, 작업 세션에서 이어
   돌려도 판정이 오염되지 않는다.
4. 한 엔진이 실패해도 다른 엔진 결과로 리포트가 나온다.
5. 리포트가 한국어로 출력된다.
