# 예제 12 보안 노트 — 올오어낫싱 크라우드펀드

범위: `contracts/src/crowdfund/AllOrNothingCrowdfund.sol`. 감사 발견
클래스 F-01..F-08 회피 매핑과 이 예제 고유의 위험.

## F 클래스 매핑

| 클래스 | 해당 | 이 예제의 회피 |
|---|---|---|
| F-01 예치·인출 재진입 | 있음 | contribute/refund/withdraw 전부 `nonReentrant` + CEI — 기여 슬롯·인출 플래그 갱신을 native 전송보다 먼저 |
| F-02 수수료-온-전송 | 해당 없음 | native만 취급 — FoT 영역 밖 |
| F-03 무코드 토큰 | 해당 없음 | 토큰 없음. `receive()`가 revert해 직접 송금 차단 |
| F-04 비례 뷰 | 없음 | 달성 판정이 `raised >= goal` 스칼라 비교 — 상수 시간. 기여자 순회·합계 재계산 뷰 없음 |
| F-05 EIP-7702 | 있음 | 기여자가 7702 위임 EOA여도 환불 call은 동일 — 권한 비교는 `msg.sender` 주소 기반 |
| F-06 단일 등록자 | 없음 | goal·deadline·beneficiary 전부 immutable. guardian은 brake(진입 차단)만 — 자금·마감·수혜자에 접근 불가 |
| F-07 오픈 로그 ≠ 승인 | 있음 | `Contributed` 이벤트 ≠ 기여 — 진실은 `contributions[user]` 매핑이다 |
| F-08 무작위성 | 없음 | 사용하지 않음 |

## 불변식

테스트가 강제하는 성질 (`contracts/test/crowdfund/AllOrNothingCrowdfund.t.sol`):

- **I1 전액 인도**: 성공 시 `withdraw`는 `raised` 전액을 정확히 1회
  beneficiary에게 보낸다 — 초과분 포함 (`test_withdraw_onSuccess`,
  `test_overfundingAccepted`).
- **I2 전액 환불**: 실패 시 각 기여자는 정확히 자기 납입액을
  1회 받는다. fuzz는 **정확한 등식** `환불 합 == 기여 합`과
  `컨트랙트 잔액 == 0`을 검증한다 (`test_fuzz_conservation`).
- **I3 원장-스lot 일치**: 환불된 주소의 `contributions`는 0 — 슬롯
  소거로 재환불이 구조적으로 불가 (`test_refund_onFailureClearsSlots`).
- **I4 진입 닫힘**: 달성 후 기여는 `AlreadyFunded`로 거부 — 목표
  초과 모금은 마지막 한 방으로만 일어난다 (동일 fuzz의 단독 달성 갈래).

## CEI 흐름

```
contribute:
  1. raised/contributions 기록 + 이벤트        ← 스토리지 먼저
  2. (외부 호출 없음 — msg.value는 이미 수령)

refund:
  1. delete contributions[msg.sender]          ← 슬롯 소거 먼저
  2. native 환불 전송                          ← 마지막

withdraw:
  1. withdrawn = true                          ← 플래그 먼저
  2. native 인도 전송                          ← 마지막
```

`contribute`는 외부 호출 자체가 없어 재진입 표면이 아니다.
`refund`/`withdraw`는 nonReentrant + CEI 이중 방어다. 단, 전송
실패 시 **전체 트랜잭션이 revert된다**(상태 갱신도 롤백) — 즉
수신이 불가능한 주소(코드가 revert하는 컨트랙트)의 기여는 환불
트랜잭션이 영원히 실패한다. 이는 의도된 정책이다: 프록시·타임아웃
폴백을 붙이면 회계가 복잡해진다. 기여자는 환불 가능한 주소로
기여할 책임이 있다 (README 배포 절 참조).

## 고유 위험

| 위험 | 왜 남는가 | 완화 |
|---|---|---|
| beneficiary가 native를 못 받는 주소 | 배포 시 고정 + 코드 점검 불가 | 배포 전 소액 송금 테스트. 컨트랙트 지갑이면 receive 필수 |
| 조기 인도 — 마감 전 출금 | 달성 즉시 withdraw 개방(설계 결정) | 수혜자가 마감 후 인도만 받으려면 프론트/키퍼가 스스로 기다린다 — 규칙은 그대로 두는 편이 안전하다 |
| 셀프 클레임 방치 | 환불은 기여자의 행동 필요 | 마감 알림은 오프체인(프론트). 마감 후라도 언제든 환불 가능 — 시급하지 않다 |
| block.timestamp 조작 | 검증자가 ±수초 왜곡 가능 | 30일급 마감에서 무의미. 1분급 마감에는 이 모델을 쓰지 마라 |
| 초과 기여 오해 | 초과분은 후원(비례 환불 아님) | 프론트에서 "목표 초과분은 수혜자에게 간다" 명시 — 테스트가 동작을 고정 |

## brake 매트릭스

| 함수 | brake 하 | 이유 |
|---|---|---|
| `contribute` | 차단 | 신규 자금 유입 — 제동의 대상 |
| `refund` | 개방 | 탈출(기여자 인출) — 막으면 자금이 잠긴다 |
| `withdraw` | 개방 | 탈출(수혜자 인도) — 이미 달성된 약속의 이행 |

guardian이 brake를 걸어도 실패 캠페인의 환불과 성공 캠페인의 인도는
항상 열려 있다 (`test_brake_blocksEntryNotExit`).
