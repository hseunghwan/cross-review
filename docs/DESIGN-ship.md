# `/cross-review-ship` 설계 문서

- **작성일:** 2026-11-26
- **상태:** 구현 완료, E2E(스킬 전체 실행) 미검증. 엔진 C 호출 계약은 Claude Code 2.1.332
  바이너리의 내장 스킬 정의를 읽어 확인했다.
- **배경:** `/ship`은 PR을 연 뒤 같은 세션에서 리뷰하고 고친다. 이 리뷰 단계를 v2의 두 엔진과
  나란히 세 번째 독립 엔진으로 쓰려는 것이 `cross-review-ship`이다.

---

## 1. 엔진 C의 정체: `/ship`의 리뷰 = 내장 `code-review`

- `/ship`(내부 이름 `ship-local`)에는 별도 리뷰 프롬프트가 없다. 내장 `code-review` 스킬이
  `ship:review` 별칭을 가지며, ship의 리뷰 단계가 이 스킬을 쓴다.
- `/ship`은 커밋·push·PR 생성·최대 7일 감시까지 하고, 스킬 설명에 "Claude가 직접 부르지 말 것"이
  명시돼 있다. 로컬 사전 검증 도구로는 맞지 않으므로 이 스킬은 `code-review`만 Skill 도구로 부른다.

## 2. 호출 계약 (2.1.332 기준)

| 항목 | 내용 |
|---|---|
| 인자 | `[low\|medium\|high\|xhigh\|max] [--fix] [--comment] [<pr#>\|<branch>\|<path>] [--max-findings <n>\|all]` |
| 범위 타깃 | `^[@\w][@\w./~^-]*\.\.\.?[@\w][@\w./~^-]*$` 에 맞으면 그 범위로 `git diff`. 전체 SHA `BASE...WT` 허용 |
| 타깃 생략 시 | `@{upstream}...HEAD` + 워킹트리를 스스로 탐색 → 다른 엔진과 범위가 어긋나므로 쓰지 않음 |
| 실행 컨텍스트 | `getContext` → CLI에서는 `fork`(격리 서브에이전트). ReportFindings 렌더링이 켜진 데스크톱/웹 등에서만 `inline` |
| fork 출력 계약 | `[{file, line, summary, failure_scenario, severity?}]` JSON 배열. 호출자에게는 `formatForegroundForkResult`가 ``N findings …: 1. 🔴 Important `file:line`: summary / Failure scenario: …`` 텍스트로 바꿔 돌려준다. 0건이면 `Code review found no issues.` |
| severity | 레시피에 따라 `important` / `pre_existing` / `nit` 또는 없음 |
| 레벨 생략 시 | 사용자가 마지막에 입력한 레벨 → 없으면 세션 effort |

- 레벨 레시피(예: high): finder 각도 8개(정확성 3 + 정리 3 + altitude 1 + 컨벤션 1) × 후보 6개 →
  1표 검증(recall 우선) → 상위 N개. 정확성 외 정리성 지적도 섞여 나온다.
- 버전이 바뀌면 출력 형식이 달라질 수 있다. 그래서 스킬은 JSON 배열과 포맷 텍스트를 둘 다 받고,
  둘 다 아니면 엔진 C 실패로 격리한다.

## 3. 결정과 근거

### 3.1 범위 통일: 스냅샷 범위 `BASE...WT`
- v2의 임시 인덱스 스냅샷 `WT`를 그대로 타깃으로 준다. 엔진 B(`--from BASE --to WT`)와 엔진 C가
  같은 diff(미추적 파일 포함)를 본다. ce만 미추적 파일을 보지 않는 비대칭은 v2와 같다.

### 3.2 독립성
- 엔진 C는 fork 컨텍스트라 메인 대화(작업 세션) 기록을 받지 않는다. ce의 `depth:full` 같은
  강제 옵션이 필요 없다.
- `--fix`/`--comment`는 넘기지 않는다. 수정은 이 스킬의 `fix` 단계에서 사용자와 상의해 적용한다.

### 3.3 실행 순서
- 엔진 B는 OS 프로세스라 백그라운드로 먼저 띄운다.
- A(ce)와 C(code-review)는 둘 다 Skill 도구로 불리고 각자 서브에이전트를 여럿 띄운다. 메인 대화가
  두 스킬을 동시에 진행할 수 없으므로 A → C 차례로 돌린다.

### 3.4 정규화
- `important→P1`, `pre_existing→P2`, `nit→P3`, 없음→`P2`. `important`는 P0/P1을 구분하지 않으므로
  P1로 두고, 합의 병합의 "더 높은 severity" 규칙으로 다른 엔진의 P0을 살린다.
- `summary`의 `Fix:` 뒤 문장을 `suggestion`으로 떼어 낸다. 없으면 null(리포트에서 이슈로부터 제안을 쓴다).

### 3.5 3자 병합: 2자 분류 → 클러스터링
- v2의 `agreed / ce_only / ocr_only` 분류는 엔진이 셋이면 조합이 7가지로 늘어 스키마가 커진다.
  이 스킬의 adjudicator는 같은 이슈를 클러스터로 묶고 각 클러스터에 `engines` 배열과 엔진별 `refs`를 단다.
  구역 분류(3엔진 / 2엔진 / 단독 / ce 범위 밖)는 오케스트레이터가 `engines` 길이와 `untracked`로 한다.
- 모델 출력은 누락·중복이 생길 수 있어, 오케스트레이터가 모든 입력 인덱스가 `refs`에 정확히
  한 번 나오는지 검사하고 보정한다.
- 미추적 파일 지적(ocr·ship)은 v2처럼 버리지 않고 adjudicator에 넣되, 미추적끼리만 묶게 한다.
  엔진 C가 생기면서 그 구역에서도 ocr+ship 합의가 의미 있기 때문이다.

### 3.6 에러 격리
- 살아 있는 엔진이 둘이면 adjudicator를 그대로 돌린다(죽은 엔진은 빈 리스트). 하나면 건너뛴다.

## 4. 비목표

- `/ship` 호출, PR 생성·감시, MR/PR 댓글 게시.
- `code-review ultra`(클라우드 리뷰). 로컬 스냅샷 범위를 그대로 넘길 수 없고 비용이 크다.

## 5. 남은 확인

- 스킬 전체 E2E(ce `depth:full` + 엔진 B 병렬 + 엔진 C + 3자 adjudicator)는 아직 돌려보지 않았다.
- 엔진 C에 범위 타깃을 줬을 때 실제로 `git diff BASE...WT`만 보는지, 출력 포맷이 위 계약과 같은지
  첫 실행에서 확인한다.
- Claude Code 업데이트로 `code-review` 인자·출력 계약이 바뀌는지 추적.
