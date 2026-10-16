# 예제 7 — 토큰 타임락 · 선형 베스팅

> ⚠️ **법적 고지 — 공개 배포 전 법률 검토 필수.** 토큰 잠금·베스팅은
> 토큰 발행(token-issuance) 제한 카테고리와 인접한다. 특히 창업자·투자자
> 보유분 스케줄은 일부 관할에서 증권 관련 약정으로 분류될 수 있다.
> 이 예제는 코드 견본이며 법률 자문이 아니다.

두 가지 잠금 패턴을 한 폴더에 담는다 — 같은 수학(클리프 + 선형 해제),
다른 신뢰 구조:

| | `TokenTimeLock` (배치형) | `LinearVesting` (자립형) |
|---|---|---|
| 누가 예치하나 | 누구나 (`lockFor`) | 배포자가 생성 시 1회 (생성자 pull) |
| 잠금 건수 | 수혜자당 1 | 그랜트당 컨트랙트 1 |
| 운영자 키 | 없음 | 없음 |
| 비상 제동 | 있음 (`SimpleBrake`) | 없음 (막을 진입이 없다) |
| 사용자 상태 | 잠금 1건 = 2슬롯 | `claimed` 1슬롯 |
| 전형 용도 | 팀 토큰 일괄 잠금 | 투자자 어카운트 1건 |

**복사해서 배포하려면:** `contracts/src/lock/` 두 파일과 의존성
(`src/common/SafeToken.sol`, `src/system/SimpleBrake.sol`)을 가져가고
아래 [배포](#배포) 절차를 따른다.

## 해제 수학 (두 컨트랙트 공통)

```
elapsed <= cliff          → 0            (클리프 전, 경계 포함)
cliff < elapsed < duration→ amount × (elapsed - cliff) / (duration - cliff)
elapsed >= duration       → amount       (종료 후 전량)
```

- 클리프 경계(`elapsed == cliff`)는 **0**이다 — 첫 위안화는 클리프
  1초 뒤부터. 스케줄 검증 시 이 경계를 테스트한다
  (`test_release_followsSchedule`).
- 나눗셈은 버림 — `releasable`의 합은 `amount` 이하, 종료 시점
  `release`/`claim`이 정확히 잔여 전량을 지급한다 (fuzz 검증).

## 배치형: `TokenTimeLock`

누구나 토큰을 예치하고 수혜자·클리프·기간을 지정한다. 운영자 키가
없다 — 예치자 본인이 자금을 넣고 파라미터를 정한다 (F-06 회피:
프로토콜이 통제하는 단일 등록자가 아님).

- **수혜자당 활성 잠금 1개** (`AlreadyLocked`). 병합은 cliff/duration이
  섞이는 회계를 만들므로 금지 — 다음 그랜트는 인출 완료 후 가능.
- `release()`는 **수혜자 본인만** — 잔여 지급은 권한이 없다.
- `released`를 잔액이 아닌 슬롯에 유지한다: 배치 컨트랙트의 잔액은
  여러 수혜자가 공유해 누가 얼마나 뺐는지 잔액만으로 알 수 없다.

## 자립형: `LinearVesting`

배포 시 그랜트 전액을 예치하고 그대로 방치하는 1회성 베스팅.
컨트랙트가 곧 그랜트다.

- `claim()`은 **누구나** 호출 가능 (가스 대낭) — 수령인은 언제나
  beneficiary다. 모바일 지갑이 오프라인 상태여도 제3자가 대신 청구할
  수 있다.
- revoke 없음 — 그랜트는 비가역이고 되돌릴 주체도 없다.
- **잔액 유도의 함정 (실제로 밟았다)**: 초기 설계는 `claimed` 없이
  `claimed = total - balance`를 잔액에서 유도했다. 그러나 제3자가
  토큰을 기부해 `balance > total`이 되는 순간 지급누적이 0으로
  포화되어 **total 초과 지급**이 가능해진다
  (`test_vesting_toleratesDonation` PoC). 정확성을 위해 상태 1슬롯
  (`claimed`)을 택했다 — 유료 상태 철학은 "슬롯 0개"가 아니라
  "정확한 최소"다.

## 함수표

### `TokenTimeLock` (guardian, token)

| 함수 | 호출자 | brake | 효과 |
|---|---|---|---|
| `lockFor(beneficiary, amount, cliffSec, durationSec)` | 누구나 | 진입 차단 | 토큰을 끌어와 잠금 생성 |
| `release()` | 수혜자 본인 | **무관 (탈출)** | 해제분 인출 |
| `vested(b)` / `releasable(b)` | 뷰 | — | 상수 시간 |

### `LinearVesting` (token, beneficiary, amount, cliffSec, durationSec)

| 함수 | 호출자 | 효과 |
|---|---|---|
| `claim()` | 누구나 (가스 대낭) | 해제분을 beneficiary에게 지급 |
| `vested()` / `claimable()` | 뷰 | 상수 시간 |

## 배포

```bash
# 배치형 — guardian은 비상 제동 권한 (하드웨어 지갑 권장)
forge create src/lock/TokenTimeLock.sol:TokenTimeLock \
  --constructor-args $GUARDIAN $TOKEN_ADDR --rpc-url $RPC --private-key $DEPLOYER

# 자립형 — 배포 트랜잭션이 곧 그랜트 예치다 (approve가 먼저 필요)
cast send $TOKEN_ADDR "approve(address,uint256)" $PREDICTED_VESTING $(cast max-int) \
  --rpc-url $RPC --private-key $SPONSOR
forge create src/lock/LinearVesting.sol:LinearVesting \
  --constructor-args $TOKEN_ADDR $BENEFICIARY $AMOUNT $CLIFF $DURATION \
  --rpc-url $RPC --private-key $SPONSOR
```

자립형의 `approve` 대상은 CREATE 주소로 예측한다:
`cast compute-address $SPONSOR --nonce $(cast nonce $SPONSOR)`.

상태 비용 요약 (측정 환경·전체 수치는 [GAS.md](GAS.md)):

| 항목 | units |
|---|---:|
| TokenTimeLock 배포 | 3,992u |
| LinearVesting 배포 (+전액 예치) | 2,217u |
| lockFor (수혜자당 1회) | 214u |
| release (반복, 로그만) | **11u** |
| vesting claim (첫) | 111u |

## 커스터마이징 경고

- **cliff > duration 금지**는 생성자/`lockFor`에서 강제한다. 완화하려면
  `_vested`의 경계 처리를 함께 재검증해야 한다.
- 배치형의 "수혜자당 1잠금"을 복수 잠금으로 바꾸려면 잠금 ID 체계와
  `release(id)` 승격이 필요하다 — 잔액 공유 회계가 깨지는 지점이다.
- 자립형에 revoke를 추가하면 "되돌릴 주체"가 생긴다 — 그 순간 운영자
  키·brake·권한 설계 전체를 다시 해야 한다 (예제 8 멀티시그 참고).

## 파일

| 파일 | 내용 |
|---|---|
| `contracts/src/lock/TokenTimeLock.sol` | 배치형 타임락 |
| `contracts/src/lock/LinearVesting.sol` | 자립형 베스팅 |
| `contracts/test/lock/Locks.t.sol` | 14 tests (기능·fuzz·brake·PoC·meter) |
| [SECURITY.md](SECURITY.md) | F-01..F-08 매핑·불변식·고유 위험 |
| [GAS.md](GAS.md) | 상태 units 계량 |

## Personal test instance: testnet and mainnet

<!-- i18n: personal_test.title personal_test.testnet personal_test.mainnet personal_test.accounts personal_test.local personal_test.fees personal_test.caps personal_test.identity -->

On **testnet**, use test coins. A shared demo is allowed. Publish with your
own wallet using `--network testnet --apps lock` and the testnet registry,
names service and owned name described in the [publisher guide](../../README.md#try-the-toolbox-on-the-eastsea-testnet-with-your-own-account).
Ordinary constructors retain the existing testnet behavior; `--personal-test`
also works on testnet for rehearsing the private flow.

On **mainnet**, deploy and use **your own private copy only**. Neither Pipln
nor the founder operates a financial service for other people. After setting
`YOUR_ACCOUNT`, `YOUR_NODE_RPC` and the actual `MAINNET_CHAIN_ID` from your
wallet/node, first inspect the offline plan:

```bash
python3 scripts/publish.py --network mainnet --personal-test --dry-run \
  --apps lock --from "$YOUR_ACCOUNT" --chain-id "$MAINNET_CHAIN_ID"

# Run from the repository root when you choose to deploy your own instance.
# Your EIP-1193 wallet approves each transaction; no key is passed to Python.
python3 scripts/publish.py --network mainnet --personal-test \
  --apps lock --from "$YOUR_ACCOUNT" --chain-id "$MAINNET_CHAIN_ID" \
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
