# 예제 9 보안 노트 — 마일스톤 에스크로

범위: `contracts/src/escrow/MilestoneEscrow.sol`. 감사 발견 클래스
F-01..F-08 회피 매핑과 이 예제 고유의 위험.

## F 클래스 매핑

| 클래스 | 해당 | 이 예제의 회피 |
|---|---|---|
| F-01 예치·인출 재진입 | 있음 | 상태변경 함수 전부 `nonReentrant` + CEI — `withdrawnTotal`/`deposited` 갱신을 native 전송보다 먼저. 전송 실패 시에도 회계 정합 |
| F-02 수수료-온-전송 | 해당 없음 | native만 취급 — FoT 영역 밖 |
| F-03 무코드 토큰 | 해당 없음 | 토큰 없음. `receive()`가 revert해 직접 송금·무코드 착오 차단 |
| F-04 비례 뷰 | 없음 | `dealInfo` 상수 시간 |
| F-05 EIP-7702 | 있음 | 판매자·구매자가 7702 위임 EOA여도 `_pay`의 call은 동일하게 동작 — 권한 비교는 `msg.sender` 주소 기반이라 무관 |
| F-06 단일 등록자 | 없음 | 중재자 없음 — 권한은 당사자 둘뿐 |
| F-07 오픈 로그 ≠ 승인 | 있음 | `MilestoneApproved` 이벤트는 누구나 열람 가능하지만 인출권의 근거는 `approvedTotal` 상태다 |
| F-08 무작위성 | 없음 | 사용하지 않음 |

## 불변식

테스트가 강제하는 성질 (`contracts/test/escrow/MilestoneEscrow.t.sol`):

- **I1 잔액 정합**: 컨트랙트 잔액 == 인출가능 + 환불가능 — 임의의
  승인/인출/환불 시퀀스 후에도 항상 성립
  (`test_fuzz_escrowAlwaysSolvent`).
- **I2 보존**: 판매자 인출 + 구매자 환불 + 컨트랙트 잔액 == 예치
  총액 (동일 fuzz의 종결 검증).
- **I3 승인 상한**: 승인 누적은 예치를 못 넘는다
  (`test_approve_sumCannotExceedDeposit`) — 마지막 승인이 남은
  예치보다 크면 그 시점에 revert.
- **I4 승인 불가역**: 같은 인덱스 재승인 거부
  (`MilestoneAlreadyApproved`).

## CEI 흐름

```
sellerWithdraw(dealId):
  1. d.withdrawnTotal = d.approvedTotal   ← 스토리지 먼저
  2. _pay(d.seller, due)                  ← native 전송 마지막
  3. emit SellerWithdrawn

buyerRefund(dealId):
  1. d.deposited = d.approvedTotal        ← 환불분 소거 먼저
  2. _pay(d.buyer, refundable)
  3. emit BuyerRefunded
```

전송 실패(`NativeTransferFailed`) 시 트랜잭션이 통째로 revert되므로
회계는 되돌아간다 — 삼키는 수신자(BlackHole 테스트)가 있어도
인출권은 보존되고 재시도할 수 있다.

## brake 매트릭스

| 함수 | 분류 | 근거 |
|---|---|---|
| `createDeal` | **진입** | 신규 자금 유입 — 제동 대상 |
| `approveMilestone` | 중립 | 자금 이동 없음 (권한 이전만). brake 하에서도 허용 — 승인 지연이 인출을 막으면 안 된다 |
| `sellerWithdraw` / `buyerRefund` | **탈출** | 당사자 인출 — 항상 개방 |

## 이 예제 고유의 위험

| 위험 | 완화 |
|---|---|
| 구매자 승인 후 판매자 인출 전 사망/장기 방치 | 승인분은 판매자 EOA 소유 — 상속·복구 절차는 지갑 영역. 컨트랙트은 개입하지 않는다 (by design) |
| 구매자가 마지막 마일스톤을 승인하지 않고 환불 | 오프체인 계약 문제 — 체인은 규칙만 집행. "인도 증거"가 필요하면 승인 UX에 증거 해시를 함께 표시 |
| 판매자가 승인분 인출을 미루고 구매자 압박 | 인출은 판매자 권리일 뿐 의무가 아님 — 구매자 환불 가능액에는 영향 없음 |
| native 전송 실패의 가스 소모 (삼키는 수신자) | revert 사유 반환 + 회계 보존 (테스트). 실서비스에서는 수신 주소 검증 UX |
| uint128 예치 상한 | 1초 블록 가스 한도 내 에스크로 금액은 사실상 제한 없음 (약 3.4e29 wei) |
| 에스크로 운영자(배포자)가 자금에 접근 가능한가 | **불가** — guardian은 brake(진입 차단)만 가능. 인출·환불은 당사자 서명 없이 불가 |

## 분쟁 시나리오 정리

| 상황 | 체인의 결과 |
|---|---|
| 판매자 미인도, 구매자 환불 요구 | 미승인 전액 구매자 회수 (언제든) |
| 부분 인도 후 관계 결렬 | 승인분은 판매자, 잔여는 구매자 — 각자 이탈 |
| 판매자가 승인분 인출 거부 | 구매자 손실 없음 (자기 몫은 이미 회수 가능) |
| 구매자가 승인 후 지급 거부 | 불가 — 승인 즉시 인출권 확정 (취소 없음이 신뢰의 근거) |

이 표가 "승인 취소 없음" 설계의 이유다 — 취소 가능한 승인은 모든
행에서 경쟁 상태가 된다.
