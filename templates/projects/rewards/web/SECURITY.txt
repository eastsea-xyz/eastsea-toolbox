# 예제 6 보안 노트 — RewardDistributor

## 감사 결과 매핑 (F-01 … F-08)

| 항목 | 대응 | 비고 |
|---|---|---|
| **F-01** 예치 재진입 | 모든 상태 변경 진입점(`fundRewards`/`stake`/`unstake`/`claim`)에 `nonReentrant` + CEI(checkpoint·부채 감소 → push) | `test_reentrancy_stakeBlocked` — 악성 토큰이 transferFrom 중 `stake` 재호출. guard의 revert는 SafeToken의 low-level call을 거쳐 `TokenTransferFailed`로 표면화되지만 stake 전체가 실패하고 `totalStaked == 0`이 방어 증명이다 |
| **F-02** FoT 토큰 | 스테이크 유입은 `pull`의 도착량 기준 — 과징 토큰도 실제 도착만 크레딧(좌초 없음) | `test_stake_fotCreditedByDelivery` |
| **F-03** 무코드·불성실 토큰 | 생성자에서 `code.length` 검사(배포 실패), 이동은 전부 SafeToken(strict bool + 도착량 확인) | `test_setup_revertInvalidToken` |
| **F-04** 무한 view | `earned`/`rewardPerToken` 모두 상수 시간 — 사용자 순회 없음 | |
| **F-05** EIP-7702 | 컨트랙트가 EOA에 위임된 실행을 가정하지 않는다. 모든 토큰 이동은 SafeToken의 code-length 검사를 통과한 컨트랙트 경로만 사용 | |
| **F-06** 단일 registrar | 중앙 registrar 없음 — fund는 누구나, 스테이크/claim은 본인 지분만. guardian은 brake(진입 차단) 권한만 갖고 자금·rate에 아무 권한이 없다 | |
| **F-07** 오픈 로그 오용 | 이벤트는 상태 전이 알림일 뿐 승인이 아니다. 앱은 `earned` 뷰로 정산 근거를 읽는다 | |
| **F-08** randomness | 무작위성 없음 — 방출은 block.timestamp 선형뿐 | |

## 핵심 불변식

1. **I1 — 지급 가능성**: 임의 시점 `rewardToken.balanceOf(distributor) >= totalDebt`. 풀은 결코 부족 지급하지 않는다 (fuzz로 무작위 시점 검증).
2. **토큰 보존**: `Σ지급 + 잔여 == Σfund`. 컨트랙트 밖으로 나가는 reward 토큰은 claim뿐이다.
3. **전 귀속 지급**: 방출 종료 후 전원 claim하면 `totalDebt`는 정수 버림 dust(wei 단위)만 남는다.

## F-01 상세 — 왜 CEI인가

```
claim():   _updateGlobal() → _checkpoint() → owed 소거·totalDebt 감소 → push
           (스토리지 확정 후 외부 호출 — 재진입이 owed=0 상태를 본다)
unstake(): checkpoint(이월 확정) → staked 감소 → push
```

재진입 표면은 2개다. (a) 스테이크 토큰의 transferFrom 훅 — ERC-20은
콜백이 없어 목업으로만 시험 가능(위 PoC). (b) 보상 토큰의 transfer 훅 —
claim은 이미 owed를 0으로 만든 뒤 push하므로 재진입 claim은 0을
받는다. 둘 다 nonReentrant로 이중 방어된다.

## brake 매트릭스

| 연산 | 분류 | brake 중 |
|---|---|---|
| fundRewards | 진입(신규 예치) | 차단 |
| stake | 진입(신규 예치) | 차단 |
| unstake | 탈출 | **허용** |
| claim | 탈출 | **허용** |

fund를 진입으로 분류한 이유: 신규 예치 유치가 공격 표면을 늘린다.
이미 진행 중인 방출(기존 예치의 귀속)은 totalDebt에 확정돼 있어
brake와 무관하게 claim된다 — brake로 인한 자금 동결 없음.

## 고유 위험

| 위험 | 분석 |
|---|---|
| **정밀 dust** | `rpt = accrued*1e18/totalStaked`의 버림으로 매 귀속마다 사용자당 <1 wei가 `totalDebt`에 남는다. 이 dust는 다음 fund의 remaining에서 제외되므로 영구 좌초된다 — 규모는 wei 단위(무시 가능)이나 설계상 알고 있어야 한다 |
| **스킵 구간의 방출 지연** | 스테이커 전원 인출 시 방출이 정지하고 잔여가 다음 fund까지 대기한다. 소실은 아니지만 후원자가 fund를 안 하면 회수 경로가 없다 — 후원 의무 명시 필요 |
| **짧은 duration fund** | 누구나 fund할 수 있으므로 remaining을 극단적으로 짧은 기간에 몰아방출할 수 있다. 단 남의 토큰은 못 쓴다(자기 예치분의 시간표만 변경). 스테이커에게는 이득(빠른 방출)이며 훔치는 구조가 아니다 |
| **rate 희석 공격 불가** | remaining 병합 구조상 fund는 기존 예치분을 보존한다 — 낮은 rate로 덮어쓰는 공격이 성립하지 않는다 |
| **guardian 악용** | guardian이 brake를 걸면 신규 fund/stake만 막힌다. 기존 방출·claim은 계속된다 — 서비스 종료 시나리오에서도 사용자 자금은 갇히지 않는다 |
| **timestamp 의존** | 방출은 block.timestamp 기반이다. 1s 블록 체인에서 채굴자(밸리데이터) 조작 여지는 ±1s이며 방출 총량은 변하지 않는다 |
| **FoT 스테이크 토큰** | pull의 도착량 기준이라 좌초는 없다. 단 사용자 간 지분이 요청 금액 기준과 달라진다는 점을 UI에 표시해야 한다 |

## 테스트 ↔ 위험 커버

| 테스트 | 방어 대상 |
|---|---|
| `test_fuzz_poolAlwaysSolvent` (5000 runs) | I1, 보존, 전 귀속 지급, 전량 인출 |
| `test_fund_recoversSkippedEmission` | 스킵 구간 방출 회수 (소실 없음) |
| `test_fund_mergesRemaining` | remaining 병합 (rate 희석 불가) |
| `test_reentrancy_stakeBlocked` | F-01 |
| `test_stake_fotCreditedByDelivery` | F-02 |
| `test_unstake_returnsTokensAndKeepsEarned` | Synthetix 함정 제거 |
| `test_brake_blocksEntryNotExit` | 탈출 보장 |
