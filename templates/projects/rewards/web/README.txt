# 예제 6 — 스테이킹 보상 분배기 (RewardDistributor)

> ⚠️ **법적 고지 — Do not deploy publicly until legal review.**
> 스테이킹 보상은 관할에 따라 증권성 판단 대상이 될 수 있는 제한
> 카테고리다. 공개 배포 전 법률 검토를 마쳐라 (docs/legal-notes.md).
>
> **이 예제는 수익률을 약속하지 않는다.** 방출 총량은 후원자가 실제로
> 예치한 토큰에 정확히 선형 비례할 뿐이며, 가격·환율·수익을 보장하는
> 어떤 문구도 포함하지 않는다. 추천 보상·코인 리베이트 구조도 없다.

ERC-20을 스테이크하면 보상 토큰을 시간 비례로 분배한다. 후원자가
`fundRewards(amount, duration)`으로 풀을 채우면 duration 동안 선형
방출되고, 스테이커는 지분 비율대라 받는다. Synthetix StakingRewards
형식에서 **전액 인출 시 보상 소실 함정**을 제거한 버전이다.

## 분배 수학

```
rewardPerTokenStored += elapsed * rate * 1e18 / totalStaked
earned(user) = userOwed[user]
             + userStaked[user] * (rewardPerToken - userRewardPaid[user]) / 1e18
```

- `checkpoint` 시점마다 진행분을 `userOwed`로 이월한다 — **전액 unstake
  후에도 귀속 보상이 살아 있다** (Synthetix 원본의 유명한 함정 제거).
- 뷰(`earned`, `rewardPerToken`)는 상수 시간이다 (F-04).

## 잔액 기반 회계 — 방출 소실 없음

전통 구현은 "남은 방출 = rate × 남은 시간"을 시간으로 계산한다.
스테이커가 아무도 없던 구간의 방출 예정분이 조용히 소실된다.

여기는 `totalDebt`(귀속 미지급 총액) 하나로 잔액에서 직접 계산한다:

```
remaining = rewardToken.balanceOf(this) - totalDebt
```

- 스테이커 부재 구간: `_updateGlobal`이 방출을 반영하지 않고 지나간다.
  그 예정분은 잔액에 그대로 남는다.
- 다음 `fundRewards`가 remaining에 그 분을 **회수해 새 기간에 재편성**한다.
  (test_fund_recoversSkippedEmission — 100_000 중 96_000이 부재 구간에
  남았다가 다음 fund의 remaining에 전액 편입되는 것을 검증.)

## 함수

| 함수 | 접근 | brake | 설명 |
|---|---|---|---|
| `fundRewards(amount, durationSec)` | 누구나 | **진입 — 차단** | 보상 풀 충전. 기존 미방출분과 병합해 재방출 |
| `stake(amount)` | 누구나 | **진입 — 차단** | 스테이크 예치 (pull, 도착량 기준) |
| `unstake(amount)` | 누구나 | 허용 | 스테이크 회수 — 귀속 보상은 유지 |
| `claim()` | 누구나 | 허용 | `userOwed` 전액 수령 |
| `earned(user)` | view | — | 이월분 + 진행분 |
| `rewardPerToken()` | view | — | 누적 보상/토큰 |

brake 분류 근거: 신규 예치(fund·stake)만 진입이다.unstake·claim은
탈출이므로 brake와 무관하게 항상 열려 있다 — 자금이 갇히지 않는다.

## 배포

```bash
forge create src/rewards/RewardDistributor.sol:RewardDistributor \
  --constructor-args <guardian> <stakingToken> <rewardToken> \
  --rpc-url ... --private-key ...
```

- `guardian` — brake 권한 (비상시 진입 차단만 한다. 자금 이동 권한 없음)
- `stakingToken` — 스테이크 받을 ERC-20 (예: 예제 4 AMM의 LP 토큰)
- `rewardToken` — 지급할 보상 ERC-20 (예: 예제 1 FixedSupplyToken)

시작: `fundRewards(1_000_000e18, 30 days)` → rate = 약 0.386e18/s.

## 상태 비용 (GAS.md 요약)

| 연산 | gasUsed | 새 슬롯 | 상태 units |
|---|---:|---:|---:|
| 배포 | 983,578 | — | **4,848** |
| fundRewards | 95,456 | 3 | **313** |
| stake (첫) | 75,272 | 2 | **211** |
| claim | 91,122 | 4 | **411** |
| unstake | 10,265 | 0 | **11** |

사용자 1명의 첫 상호작용(stake)이 2슬롯(200u) + 로그(11u). 이후
stake/claim은 기존 슬롯 갱신이라 로그 비용만 남는다 — 유료 상태
모델에서 스테이킹은 "슬롯은 사용자당 1회, 이후 로그만" 구조가 된다.

## 커스터마이징 경고

- **보상 토큰과 스테이크 토큰의 분리**가 의도된 설계다. 같은 토큰으로
  두면 fund·claim 순환에서 셀수 결함은 없지만 회계 추적이 어려워진다.
- **duration을 짧게** 잡으면 급방출된다 — 남의 토큰 없이는 자기 예치분의
  방출 시간표만 바꿀 수 있다 (remaining 병합이라 기존 예치는 보존).
-FoT 보상 토큰을 쓰면 claim 지급이 `push` 경로라 도착량이 적어도
  revert하지 않는다 — `pushExact`로 바꾸려면 지급 실패 시 잔액이 다음
  fund의 remaining에 남는다는 점을 검토하라.
- `userOwed` 이월 없이 Synthetix 원식으로 되돌리면 전액 unstake가
  미청구 보상을 소실시킨다 — 절대 되돌리지 마라.

## 테스트

```bash
cd contracts
forge test --match-path 'test/rewards/*' -vv          # 20 tests
FOUNDRY_FUZZ_RUNS=5000 forge test --match-path 'test/rewards/*' \
  --match-test test_fuzz                              # 풀 상호당보 불변식 심층
```

불변식 fuzz (`test_fuzz_poolAlwaysSolvent`): 무작위
stake/unstake/claim/warp 시퀀스 후 (1) 토큰 보존 `Σ지급 + 잔여 == fund`,
(2) I1 `잔여 >= totalDebt` — 결코 부족 지급하지 않는다, (3) 전원
claim 후 `totalDebt <= 1_000 wei` (정수 버림 dust 상한), (4) 스테이크
전량 인출 가능.

## Personal test instance: testnet and mainnet

<!-- i18n: personal_test.title personal_test.testnet personal_test.mainnet personal_test.accounts personal_test.local personal_test.fees personal_test.caps personal_test.identity -->

On **testnet**, use test coins. A shared demo is allowed. Publish with your
own wallet using `--network testnet --apps rewards` and the testnet registry,
names service and owned name described in the [publisher guide](../../README.md#try-the-toolbox-on-the-eastsea-testnet-with-your-own-account).
Ordinary constructors retain the existing testnet behavior; `--personal-test`
also works on testnet for rehearsing the private flow.

On **mainnet**, deploy and use **your own private copy only**. Neither Pipln
nor the founder operates a financial service for other people. After setting
`YOUR_ACCOUNT`, `YOUR_NODE_RPC` and the actual `MAINNET_CHAIN_ID` from your
wallet/node, first inspect the offline plan:

```bash
python3 scripts/publish.py --network mainnet --personal-test --dry-run \
  --apps rewards --from "$YOUR_ACCOUNT" --chain-id "$MAINNET_CHAIN_ID"

# Run from the repository root when you choose to deploy your own instance.
# Your EIP-1193 wallet approves each transaction; no key is passed to Python.
python3 scripts/publish.py --network mainnet --personal-test \
  --apps rewards --from "$YOUR_ACCOUNT" --chain-id "$MAINNET_CHAIN_ID" \
  --rpc "$YOUR_NODE_RPC" --bundle-mode local
```

The atomic personal deployer sets `instanceMode()` to `personal-test` before
use. Only your deploying wallet is initially allowlisted. Add another account
**only if it is yours** with `setPersonalTestAccount(address,bool)` through
your wallet; counterparties/beneficiaries must be your own allowed accounts.
A native cap and an aggregate admitted token cap apply to each instance.
Defaults are `10000000000000000` native base units and `5000000000000000000`
18-decimal **own test-token** units; adjust with `--personal-native-cap` and
`--personal-token-cap`. These are quantities, **not a dollar-equivalence claim**.
No protocol fee or new administrative withdrawal exists in personal mode;
network fees still apply.

Use the generated local bundle against its fixed addresses. Serve it on
loopback or let the wallet browser load its local assets; do not upload it,
register it as a public app, or run a shared mainnet frontend. The frontend
checks mode, owner, caps, authority and your account before writes. See
[the policy and wallet interface](../../docs/personal-mainnet-testing.md)
for asset-cap limitations, account removal/exit behavior and local loading.
English copy has stable [translation keys](../../docs/i18n/personal-test.en.json);
this branch has not integrated the five-language pack.
