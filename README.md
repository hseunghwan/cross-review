# cross-review

`ce-code-review`와 `open-code-review-local` **두 개의 독립 코드리뷰 엔진**을 동일한 로컬
diff로 각각 돌리고, 결과를 병합해 **"두 엔진이 함께 지적한 항목(고신뢰)"** 과
**"한쪽만 지적한 항목(상대 엔진의 사각지대)"** 으로 태깅한 단일 리포트를 내는 Claude Code 스킬.

MR 보내기 전 로컬 워킹트리를 교차 검증하는 용도.

## 왜 교차 검증인가

두 엔진은 서로 다른 룰셋/검토 철학을 가진다.

- **ce-code-review** — 13개 페르소나 + 프로젝트 표준(`AGENTS.md`/`CLAUDE.md`) 기반
- **open-code-review-local** — alibaba `ocr` 룰 체크리스트 기반

블라인드 스팟이 다르기 때문에, 둘 다 잡으면 신뢰도가 높고 한쪽만 잡으면 상대 엔진이
놓친 지점을 드러낸다. 병합·합의 판정은 **신선한 격리 서브에이전트**가 수행해, 방금 코딩한
작업 세션에서 이어 돌려도 판정이 오염되지 않는다.

## 사전 요구사항

- **Claude Code** (구독 로그인). 이 스킬은 Claude Code 자체를 리뷰 두뇌로 쓴다.
- **`ocr` CLI** — `ocr core` 명령 그룹이 필요(`ocr core -h`로 확인). open-code-review-local 엔진용.
- **`ce-code-review` 스킬** — compound-engineering 플러그인. 없으면 ocr 단독으로 동작(리포트에 명시).
- 로컬 git 저장소(워킹트리 기준으로 리뷰).

## 설치

이 저장소를 Claude Code 스킬 디렉터리로 두면 된다.

```bash
# 클론
git clone https://github.com/hseunghwan/cross-review.git ~/.claude/skills/cross-review

# 또는 다른 곳에 클론 후 심볼릭 링크
git clone https://github.com/hseunghwan/cross-review.git ~/src/cross-review
ln -s ~/src/cross-review ~/.claude/skills/cross-review
```

`/cross-review`가 스킬 목록에 나타나면 설치 완료.

## 사용법

로컬에서 작업한 뒤, MR을 보내기 전에:

```
/cross-review              # 현재 브랜치 vs 자동 감지 base
/cross-review base:dev     # diff base 명시
/cross-review fix          # 리포트 후, 수정 범위를 상의해 적용
```

로컬 워킹트리 전용이다. PR을 교차 검증하려면 먼저 `glab mr checkout <id>`(또는
`gh pr checkout`)로 체크아웃한 뒤 실행한다.

## 동작 개요

```
Step 1  스코프 산정   현재 브랜치 vs base 확정. git stash create로 워킹트리를 비파괴
                     스냅샷해, 두 엔진이 완전히 같은 diff를 보게 한다.
Step 2A 엔진 A        ce-code-review mode:agent (read-only) → JSON findings
Step 2B 엔진 B        open-code-review-local (REVIEW_FILTER on) → 분류된 코멘트
Step 3  정규화        두 결과를 공통 스키마로 변환(심각도 축 통일)
Step 4  adjudicator   신선 격리 서브에이전트가 병합·합의 판정(합의=보수적 심각도)
Step 5  리포트        ★합의 / ce 단독 / ocr 단독 3섹션의 한국어 리포트
```

한 엔진이 실패해도 중단하지 않고 나머지 엔진 결과로 리포트한다.

## 문서

- [`SKILL.md`](SKILL.md) — 실행 스킬(오케스트레이션 절차)
- [`DESIGN.md`](DESIGN.md) — 설계 문서(아키텍처·컴포넌트·결정 근거)
- [`PLAN.md`](PLAN.md) — 구현 계획(태스크 분해)
