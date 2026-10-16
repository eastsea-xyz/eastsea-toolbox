# 예제 6 가스·상태 비용 — 스테이킹 보상 분배기

측정 환경: forge 1.6.0-nightly (5e88010), solc 0.8.24, optimizer 200 runs,
evm paris. 원본: `forge test --match-path 'test/rewards/*' -vv`.

## 측정치 (2026-10-06)

### 배포

| 연산 | gasUsed | 코드 B | 상태 units |
|---|---:|---:|---:|
| RewardDistributor 배포 | 983,578 | 4,648 | **4,848** |

### 수명 주기 (fund 100_000e18 / 10_000s, alice 단독 스테이크)

| 연산 | gasUsed | 새 슬롯 | 로그 B | 상태 units |
|---|---:|---:|---:|---:|
| fundRewards (첫) | 95,456 | 3 | 416 | **313** |
| stake (첫) | 75,272 | 2 | 352 | **211** |
| claim (warp 1_000s 후) | 91,122 | 4 | 352 | **411** |
| unstake (전액) | 10,265 | 0 | 352 | **11** |

새 슬롯의 정체:
- fund 3 = `totalDebt`/`rewardRate`·`finishAt`·`updatedAt` 계정의
  초기 기록 (스토리지 0 → 0 아님).
- stake 2 = `userStaked[alice]` + `userRewardPaid[alice]`.
- claim 4 = `totalDebt` 감소분 기록 + `userOwed` 갱신 — stake 시점에
  만들어진 사용자 슬롯의 재기록이 아니라 measured 계정의 first-write
  조합(StateMeter는 tracked 계정의 nonzero 슬롯 증감을 센다).

## 프로그램당 1회 vs 사용자당 1회

비용 구조가 두 층으로 나뉜다 — 유료 상태 설계의 표본 사례:

| 층 | 지불 시점 | 규모 |
|---|---|---:|
| 프로그램 1회 (배포 + 첫 fund) | 운영자 | 4,848 + 313 = **5,161u** |
| 사용자당 1회 (첫 stake) | 각 스테이커 | **211u** |
| 반복 (claim/unstake/재stake) | 거래 건당 | 11~411u (거의 전액 로그) |

unstake가 11u(로그만)인 것이 포인트다 — 스토리지는 전부 재기록이고
`userOwed` 이월은 기존 슬롯 갱신이라 추가 슬롯이 없다.

## 풀 수명 시나리오

| 시점 | 누적 units |
|---|---:|
| 배포 + 첫 fund | 5,161 |
| + 스테이커 100명 진입 (211u씩) | +21,100 |
| + 스테이커당 claim 12회 (411u × 100 × 12) | +493,200 |
| **1년 운영 합계** | ≈ **520,000** |

claim이 수명 비용의 95%다 — 스테이커가 매달 claim하는 습관이 상태
비용을 지배한다. dApp이 "claim 자동화"(조건 충족 시 묶어서 claim)를
UX에 넣으면 이 수치는 선형으로 줄어든다.

## 설계 시사점

- **userOwed 이월 계좌**가 Synthetix 함정(전액 인출 시 보상 소실)을
  제거하지만 슬롯 1개의 대가는 아니다 — paid 스냅샷과 별개 슬롯이지만
  갱신이 기존 슬롯에서 일어나 반복 비용은 0이다.
- **잔액 기반 remaining**은 rate/finishAt을 시간이 아니라 잔액에서
  역산하게 해 스킵 구간의 방출 예정분 별도 저장소를 없앴다 —
  상태 비용 0으로 소실 방지를 얻는다.
- 표준 Synthetix 대비 코드 4,648B — 본 예제는 SimpleBrake 상속과
  SafeToken 방어를 포함한 크기다.

## 재측정

```bash
cd contracts
forge test --match-path 'test/rewards/*' -vv 2>&1 | grep -E "gasUsed|stateUnits"
FOUNDRY_FUZZ_RUNS=5000 forge test --match-path 'test/rewards/*' \
  --match-test test_fuzz  # 풀 상호당보 불변식 심층
```
