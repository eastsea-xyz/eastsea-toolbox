# 예제 10 보안 노트 — 선불 시간 구독

범위: `contracts/src/subscription/SubscriptionManager.sol`. 감사 발견
클래스 F-01..F-08 회피 매핑과 이 예제 고유의 위험.

## F 클래스 매핑

| 클래스 | 해당 | 이 예제의 회피 |
|---|---|---|
| F-01 예치·인출 재진입 | 있음 | subscribe/cancel/claim `nonReentrant` + CEI — 만료 시각·준비금 갱신을 native 전송보다 먼저. settle은 외부 호출 자체가 없음 |
| F-02 수수료-온-전송 | 해당 없음 | native만 취급 — FoT 영역 밖 |
| F-03 무코드 토큰 | 해당 없음 | 토큰 없음. `receive()`가 revert해 직접 송금 차단 |
| F-04 비례 뷰 | 없음 | 부채 계산이 난제인 지점 — 글로벌 `refundReserve` 스칼라로 O(1) 상계. 사용자 순회 없음 |
| F-05 EIP-7702 | 있음 | 구독자가 7702 위임 EOA여도 환불 call은 동일 — 권한 비교는 `msg.sender` 주소 기반 |
| F-06 단일 등록자 | 없음 | 요율·수취인 immutable. guardian은 brake(진입 차단)만 — 자금·기간·요율에 접근 불가 |
| F-07 오픈 로그 ≠ 승인 | 있음 | `Subscribed` 이벤트 ≠ 유효 구독 — 진실은 `subscribers[user].expiry`다 |
| F-08 무작위성 | 없음 | 사용하지 않음 |

## 불변식

테스트가 강제하는 성질 (`contracts/test/subscription/SubscriptionManager.t.sol`):

- **I1 준비금 상한**: `refundReserve ≤ balance` — 임의의
  구독/취소/시간 경과 후에도 성립. 환불 가능액은 항상 잔액으로
  뒷받침된다 (`test_fuzz_paymentConservation`).
- **I2 자금 보존**: 환불 수령 + 컨트랙트 잔액 == 지불 총액 — **정확한
  등식**. dust(<1초치)도 컨트랙트에 남아 유실이 0이다 (동일 fuzz).
- **I3 환불 산수**: refund == 남은 초 × rate — 대칭 곱셈
  (`test_cancel_refundsProRata`).
- **I4 정산 1회**: 납입분은 cancel 또는 settle 중 정확히 한 경로로만
  해제된다 (`test_settleExpiredUnlocksLapsedRevenue` 재호출 거부).

## 준비금 스칼라가 무엇을 사는가

"모두가 지금 취소하면?" 부채를 사용자 순회 없이 아는 방법:

```
지금:  reserve += 산 초 × rate            (subscribe)
풀기:  reserve -= 그 사용자 납입 누적      (cancel — 소비분은 수익화)
풀기:  reserve -= 만료 구독 납입분         (settle — permissionless)
인도:  balance - reserve → payee           (claim, 누구나)
```

시간 경과는 reserve를 줄이지 않는다 — 실제 부채만 줄어든다. 따라서
reserve는 항상 **상한**이고 인도액은 과소 청구 쪽으로만 틀린다.
과소 청구는 키퍼의 `settleExpired` 호출로 풀린다 — 과다 청구(환불
부족)는 구조적으로 불가능하다.

## CEI 흐름

```
subscribe:
  1. 만료된 이전 기간 정산(_settle)           ← 스토리지 먼저
  2. expiry/contributed/reserve 기록
  3. (외부 호출 없음 — msg.value는 이미 수령)

cancel:
  1. expiry = now, contributed = 0,
     reserve -= contributed                  ← 스토리지 먼저
  2. refund native 전송                      ← 마지막
  3. emit Cancelled

claimRevenue:
  1. amount = balance - reserve 계산
  2. payee 전송 (재진입 시 amount=0으로 자연 소진)
```

전송 실패 시 트랜잭션 전체가 revert되어 회계도 되돌아간다 — 삼키는
수신자(`receive()` revert 지갑)를 낸 구독자는 지갑을 고칠 때까지
구독이 유지되며 자금은 잠기지 않는다(만료 후 settle로 수익 처리).

## brake 매트릭스

| 함수 | 분류 | 근거 |
|---|---|---|
| `subscribe` | **진입** | 신규 자금 유입 — 제동 대상 |
| `cancel` | **탈출** | 고객 환불 — 항상 개방 |
| `settleExpired` / `claimRevenue` | **탈출** | 수익 확정·인도 — 운영 지연이 자금을 잠그면 안 된다 |

brake가 장기화되면 신규 매출은 멈추지만 기존 구독은 시간이 지나며
자연 소비되고, 환불·수익 인도는 끝까지 열려 있다.

## 이 예제 고유의 위험

| 위험 | 완화 |
|---|---|
| 요율 실수(예: 10배 낮게 배포) | immutable이라 되돌릴 수 없다 — 배포 전 `claimableRevenue`·환불 시뮬레이션 필수. 잘못 배포하면 청구액 0 상태로 방치하거나 환불 안내 후 폐쇄 |
| 환불 시 수신 실패(삼키는 수신자) | revert로 전체 롤백 — 자금 손실 없음. 구독은 유지되어 소비·정산 경로로 회수 |
| 구독자가 만료 방치 → 수익 미인도 | permissionless `settleExpired` — 키퍼·수취인 누구나 정산 가능. 방치분은 balance에 안전하게 남는다 |
| 키퍼가 settle을 악용? | 불가 — settle은 reserve를 줄일 뿐 인도 대상은 payee로 고정. 사용자 몫을 건드리지 않는다 |
| uint88 contributed 한도 | 납입 누적 ~3.09e26 wei(약 3억 ETH) — 초과 시 revert만 나고 자금 손실 없음. 사실상 도달 불가 |
| uint64 만료 시각 | 서기 2554년 — 사실상 무제한 |
| payee 개인키 분실 | payee는 수신 전용 — claim은 **누구나** 호출 가능하므로 payee가 행동 못 해도 수익 인도는 가능. 단 수취 주소 변경은 불가(immutable) |
