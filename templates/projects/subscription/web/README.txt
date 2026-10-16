# 예제 10 — 선불 시간 구독

> ⚠️ **법적 고지 — 공개 배포 전 법률 검토 필수.** 선불 충전 후 기간
> 동안 컨트랙트가 고객 자금을 보유한다. 관할에 따라 선불충전금은
> 전자화폐·지급업 규제의 대상이 될 수 있다 (예제 9와 같은
> CUSTODY ADJACENT 영역). 이 예제는 코드 견본이며 법률 자문이 아니다.

초당 요율로 시간을 사는 기간권(pass) 모델. 자동이체도, 크레딧 잔액도
없다 — 상태는 사용자별 만료 시각 하나뿐이다.

| | 기간권 (이 예제) | 크레딧 잔액형 |
|---|---|---|
| 상태 | 만료 시각 1슬롯 | 사용량 카운터 + 단가 이력 |
| 소비 정산 | 시간이 흐르면 저절로 | 사용 시마다 차감 필요 |
| 환불 | 남은 초 × 요율 — 산수 하나 | 잔액 그대로 (단가 변경 시 복잡) |
| 만료 확인 | `expiry > now` 비교 한 번 | 체크아웃마다 잔액 검사 |
| 운영자 키 | **없음** (요율·수취인 immutable) | 단가 변경 키 필요 |

**핵심 설계 — 환불 준비금 스칼라.** 소비된 수익을 회수하려면 "지금
모두가 취소하면 얼마를 돌려줘야 하나"(부채)를 알아야 하는데, 이는
사용자 전체 순회(F-04 위반) 없이는 계산할 수 없어 보인다. 이 예제는
글로벌 스칼라 하나로 해결한다:

```
refundReserve = Σ 활성 구독의 납입 원금 (cancel/settle 때만 감소)
수익 인도 가능액 = balance - refundReserve        ← O(1)
```

- `subscribe`: reserve += 산 초 × 요율
- `cancel`: reserve -= 그 사용자의 납입 누적(전액) — 소비분은 이때 수익화
- `settleExpired`(누구나): 만료 방치 구독의 납입분을 수익으로 확정

시간이 흘러 실제 부채는 줄어도 reserve 값은 그대로다 — 항상
**상한(보수적)**이며, `balance ≥ refundReserve` 불변식이 환불을 언제나
전액 뒷받침한다. 정산 이벤트가 없으면 수익도 잠긴다는 교훈을
permissionless settle로 푼다.

## 대칭 산수 — dust가 양쪽에서 맞는다

```
subscribe: seconds = msg.value / rate        (버림)
cancel:    refund  = remainingSec × rate
```

곱셈·나눗셈이 대칭이라 <1초치 dust는 기간에 못 들어가지만 거부 없이
수익에 흡수된다 — 정확 배수 지불을 강제하는 것보다 UX 오류가 적다.
fuzz는 `지불 총액 == 환불 + 컨트랙트 잔액`이 **정확한 등식**으로
성립함을 검증한다 (dust 유실 0).

## 함수표

### `SubscriptionManager` (guardian, payee, ratePerSecond)

| 함수 | 호출자 | brake | 효과 |
|---|---|---|---|
| `subscribe()` (payable) | 누구나 | 진입 차단 | value/rate초 만료 시각 연장. 이전 기간 만료면 먼저 정산 |
| `cancel()` | 구독자 본인 | **무관 (탈출)** | 남은 초 × 요율 환불, 구독 종결 |
| `settleExpired(user)` | **누구나 (키퍼)** | **무관 (탈출)**** | 만료 구독 납입분을 수익 확정 |
| `claimRevenue()` | **누구나** | **무관 (탈출)** | balance − reserve를 payee에게 인도 |
| `isSubscribed(u)` / `claimableRevenue()` | 뷰 | — | 상수 시간 |

`payee`는 지급 목적지일 뿐 키가 아니다 — 수익 인도는 누구나
트리거할 수 있어 payee 지갑이 온체인 행동을 할 필요가 없다.

## 배포

```bash
# 요율: 월 3 EAST / 30일 = 3e18 / 2_592_000초
RATE=1157407407407   # wei/s — 1일 ≈ 0.1 EAST

forge create src/subscription/SubscriptionManager.sol:SubscriptionManager \
  --constructor-args $GUARDIAN $PAYEE $RATE \
  --rpc-url $RPC --private-key $DEPLOYER
```

- `guardian`: 비상 제동(신규 구독 차단만) — 하드웨어 지갑 권장
- `payee`: 수익 수취 주소 — 배포 후 변경 불가
- **요율 변경은 재배포로만 가능** (by design). 새 요율 컨트랙트를 옆에
  배포하고 프론트를 갈아끼운다 — 기존 구독자의 잔여 기간은 그대로
  보호된다.

상태 비용 요약 (측정 환경·전체 수치는 [GAS.md](GAS.md)):

| 항목 | units |
|---|---:|
| 배포 | 3,603u |
| 첫 구독 (사용자 슬롯 + 준비금 최초 기록) | 207u |
| 갱신 (슬롯 재기록 없음) | **7u** |
| cancel / claimRevenue | 6u / 5u |

## 커스터마이징 경고

- **환불 정책 완화**(예: 만료 24시간 전 취소 불가)는 reserve 산수에
  그대로 반영해야 한다 — refund와 reserve 감소액이 어긋나는 순간
  `balance ≥ reserve` 불변식이 깨진다.
- **여러 요율 플랜**(월간/연간)은 지불 시점 value로 이미 표현된다 —
  플랜 enum을 상태에 추가하지 마라. 슬롯만 늘고 산수는 같다.
- 자동 갱신(keep-alive 키퍼가 대신 subscribe)은 가능하지만 진입
  함수라 brake가 걸린다 — 결제 실패 정책은 오프체인 영역이다.

## 파일

| 파일 | 내용 |
|---|---|
| `contracts/src/subscription/SubscriptionManager.sol` | 기간권 구독 관리자 |
| `contracts/test/subscription/SubscriptionManager.t.sol` | 13 tests (기능·정산·fuzz·brake·meter) |
| [SECURITY.md](SECURITY.md) | F-01..F-08 매핑·불변식·고유 위험 |
| [GAS.md](GAS.md) | 상태 units 계량 |

## Personal test instance: testnet and mainnet

<!-- i18n: personal_test.title personal_test.testnet personal_test.mainnet personal_test.accounts personal_test.local personal_test.fees personal_test.caps personal_test.identity -->

On **testnet**, use test coins. A shared demo is allowed. Publish with your
own wallet using `--network testnet --apps subscription` and the testnet registry,
names service and owned name described in the [publisher guide](../../README.md#try-the-toolbox-on-the-eastsea-testnet-with-your-own-account).
Ordinary constructors retain the existing testnet behavior; `--personal-test`
also works on testnet for rehearsing the private flow.

On **mainnet**, deploy and use **your own private copy only**. Neither Pipln
nor the founder operates a financial service for other people. After setting
`YOUR_ACCOUNT`, `YOUR_NODE_RPC` and the actual `MAINNET_CHAIN_ID` from your
wallet/node, first inspect the offline plan:

```bash
python3 scripts/publish.py --network mainnet --personal-test --dry-run \
  --apps subscription --from "$YOUR_ACCOUNT" --chain-id "$MAINNET_CHAIN_ID"

# Run from the repository root when you choose to deploy your own instance.
# Your EIP-1193 wallet approves each transaction; no key is passed to Python.
python3 scripts/publish.py --network mainnet --personal-test \
  --apps subscription --from "$YOUR_ACCOUNT" --chain-id "$MAINNET_CHAIN_ID" \
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
