# 예제 9 가스·상태 비용 — 마일스톤 에스크로

측정 환경: forge 1.6.0-nightly (5e88010), solc 0.8.24, optimizer 200 runs,
evm paris. 원본: `forge test --match-path 'test/escrow/*' -vv`.

## 측정치 (2026-10-06)

### 배포

| 연산 | gasUsed | 코드 B | 상태 units |
|---|---:|---:|---:|
| MilestoneEscrow 배포 | 881,601 | 4,042 | **4,342** |

### 수명 주기 (딜 10 ETH / 마일스톤 3개)

| 연산 | gasUsed | 새 슬롯 | 로그 B | 상태 units |
|---|---:|---:|---:|---:|
| createDeal (10 ETH 예치) | 101,545 | 4 | 256 | **408** |
| approveMilestone (4 ETH) | 28,425 | 1 | 192 | **106** |
| sellerWithdraw (4 ETH) | 14,034 | 0 | 160 | **5** |
| buyerRefund (6 ETH) | 13,789 | 0 | 160 | **5** |

새 슬롯의 정체:
- createDeal 4 = `Deal` 구조체(buyer/seller 주소 2 + 금액 uint128×3 +
  count uint64 팩) 4슬롯 + `nextDealId` 재기록(0→1은 계정 first-write
  로 집계).
- approve 1 = `milestoneApproved[keccak(dealId, index)]` 첫 기록.
  `approvedTotal`은 기존 슬롯 재기록이라 슬롯 수 불변.
- withdraw/refund 0 = 구조체 필드 재기록뿐 — **탈출은 로그 값의
  비용만 낸다**.

## 프로그램 시나리오 — 월 100건 프리랜스 정산

| 항목 | 건당 | 월 100건 |
|---|---:|---:|
| createDeal | 408u | 40,800 |
| approve ×3 | 106u ×3 | 31,800 |
| withdraw + refund | 5u + 5u | 1,000 |
| **월 합계** | | **≈ 73,600** |

마일스톤 10개짜리 대형 딜로 바꿔도: createDeal 408u 동일 + 승인
10 × 106u = 1,468u. 금액 배열을 저장하는 전형 구현이라면 여기에
배열 10슬롯(1,000u+)이 createDeal에 더해진다 — 승인 시점 지정
설계가 거래당 ~1,000u를 아낀다.

## 설계 시사점

- **createDeal 408u가 프로그램의 지배 항**이고, 이 중 ~300u는 Deal
  구조체 자체다. 더 줄이려면 buyer/seller를 uint160으로 묶는
  팩킹이 가능하지만 가독성 손실 대비 절약이 100u뿐 — 하지 않았다.
- **withdraw 5u / refund 5u** — 분쟁 상황에서 "탈출 비용"이 0에
  수렴한다는 것은 사용자 보호의 실질이다. brake가 걸려도, 승인자가
  방치해도, 인출은 언제나 로그 값의 비용으로 열려 있다.
- 승인 슬롯(`milestoneApproved`)은 인덱스당 1회뿐이라 거래당
  마일스톤 수에 선형으로 붙는 유일한 상태다 — 개수를 늘리기 전에
  "이 거래에 마일스톤 20개가 진짜 필요한가"를 먼저 묻는 게 유료
  상태 설계다.
