# 예제 4 — 상수곱 AMM (`AmmFactory` / `AmmPair` / `AmmRouter`)

Uniswap V2 구조의 교과서적 구현을 EastSea 유료 상태에 맞게 다듬은 3계층
AMM. 누구나 페어를 만들고, 유동성을 공급하고, 경로 스왑을 할 수 있다.
이 예제의 주제는 **F-02(fee-on-transfer)와 k 불변식**이다.

**계약:**
- `contracts/src/amm/AmmFactory.sol` — 페어 레지스트리 + brake
- `contracts/src/amm/AmmPair.sol` — 리저브·스왑·LP·TWAP
- `contracts/src/amm/AmmRouter.sol` — 유동성 공급/회수 + 경로 스왑 (≤4홉)

**테스트:** 38개 — 페어 23 (`test/amm/Amm.t.sol`) + 라우터 15
(`test/amm/AmmRouter.t.sol`). k 비감소 fuzz, FoT 이중 과징 실측,
팩토리 연동 brake 포함.

## 왜 이 모양인가

- **모든 유입량은 잔액 차이로 측정한다 (F-02).** mint도 swap도 "얼마를
  보냈는가"가 아니라 "페어 잔액이 얼마나 늘었는가"로 정산한다. 수수료
  과징 토큰이 약속보다 적게 도착해도 실제 도착량만큼 LP/스왑이 되고,
  좌초(잔고에 갇힌 원금)가 없다.
- **k 비감소는 페어가 강제한다.** 라우터가 out을 계산하지만, 최종
  검증은 페어의 `balance0Adjusted * balance1Adjusted >= reserve0 *
  reserve1 * 1000²` (수수료 0.30% 보정). 악의적 라우터·직접 호출로도
  유동성을 뽑아갈 수 없다 — fuzz로 매 스왑 검증.
- **무코드 토큰 거부 (F-03).** 팩토리가 코드 없는 주소로 페어를 만들지
  않는다. 좀비 페어(상태 비용만 태우는)가 생기는 것을 원천 차단.
- **팩토리 연동 brake.** brake 1이면 모든 페어의 mint(예치)와
  swap(진입)이 차단된다. burn(회수)은 brake와 무관하게 항상 열려
  있다 — 유동성 공급자는 언제든 탈출할 수 있다.
- **TWAP 적산치.** 페어가 price{0,1}CumulativeLast를 유지한다. 오라클
  소비자는 두 시점 차이 ÷ 경과시간으로 조작 저항 평균가를 얻는다.

## 배포

```bash
cd contracts
forge create src/amm/AmmFactory.sol:AmmFactory \
  --constructor-args 0xGUARDIAN --rpc-url $EASTSEA_RPC --private-key $KEY
forge create src/amm/AmmRouter.sol:AmmRouter \
  --constructor-args 0xFACTORY --rpc-url $EASTSEA_RPC --private-key $KEY
```

| 사용법 | 호출 |
|---|---|
| 유동성 공급 (페어 자동 생성) | 토큰 2종 `approve(라우터)` → `addLiquidity(A, B, desiredA, desiredB, minA, minB, to, deadline)` |
| 유동성 회수 | LP `approve(라우터)` → `removeLiquidity(A, B, lp, minA, minB, to, deadline)` |
| 스왑 (일반) | `swapExactTokensForTokens(amountIn, amountOutMin, path[], to, deadline)` |
| 스왑 (FoT 토큰 포함 경로) | `swapSupportingFeeOnTransfer(...)` — 홉마다 실제 도착량 관찰 |

## EastSea 상태 비용 (측정: `test_meter_*`, 상세 GAS.md)

| 연산 | gas | 새 슬롯 | 상태 units |
|---|---:|---:|---:|
| 팩토리 배포 | 2,132,774 | 0 | **10,591** (코드 10,491B) |
| 페어 배포 (1개) | 1,654,866 | 0 | **8,196** (코드 7,796B) |
| 첫 예치 (라우터 경유, 페어 배포 포함) | 1,980,040 | — | ≈ **8,700** (8,196 + 페어 상태) |
| 추가 예치 mint | 120,290 | 4 | **423** |
| 페어 직접 swap | 40,529 | 0 | **20** |
| 라우터 swap (1홉) | 83,757 | 0 | **32** |
| 회수 burn | 25,001 | 0 | **30** |
| 라우터 회수 | 81,952 | 2 | **249** |

- **스왑은 상태적으로 거의 공짜** (20~32 units, 슬롯 없음). 리저브는
  기존 슬롯 갱신이고 로그만 남는다 — AMM의 고빈도 트래픽이 유료 상태
  모델과 궁합이 좋다는 뜻이다.
- **비용은 페어 수에 비례한다.** 페어 1개 = 코드 8,196u + 초기 리저브
  슬롯. 긴꼬리 토큰까지 미리 페어를 만들지 말 것.
- 첫 예치 423u의 슬롯 4개: 리저브 팩(1) + TWAP 적산(2) + LP 잔액(1).

## 커스터마이징 경고

- **수수료(0.30%)를 바꾸면** `FEE_NUMERATOR`/`FEE_DENOMINATOR`(페어)와
  라우터의 복제 상수, `_quote` 계산을 함께 바꿔야 한다. 어긋나면
  스왑이 전부 `ExcessiveOutput`으로 죽는다.
- **TWAP은 이 예제에서 적산만 제공한다.** 소비자 측에서 최소 관측
  주기(예: 30분)를 강제하지 않으면 단일 블록 조작에 노출된다.
- `sync()`는 k를 낮출 수 있는 비상구다 — 남발 금지 (SECURITY.md).
- FoT 토큰을 라우터로 예치하면 **수수료가 두 번 과징된다**
  (사용자→라우터→페어). 실측치는 SECURITY.md 참조.

## 프론트엔드

`apps/amm/index.html` — 페어 조회 · 유동성 공급/회수 · 스왑 견적.

## 관련 문서

- [SECURITY.md](./SECURITY.md) — F-02/F-03 대응, k 불변식, FoT 실측
- [GAS.md](./GAS.md) — 측정 원본 데이터
- [manifest.json](./manifest.json) — 앱 레지스트리 게시용 템플릿

## Personal test instance: testnet and mainnet

<!-- i18n: personal_test.title personal_test.testnet personal_test.mainnet personal_test.accounts personal_test.local personal_test.fees personal_test.caps personal_test.identity -->

On **testnet**, use test coins. A shared demo is allowed. Publish with your
own wallet using `--network testnet --apps amm` and the testnet registry,
names service and owned name described in the [publisher guide](../../README.md#try-the-toolbox-on-the-eastsea-testnet-with-your-own-account).
Ordinary constructors retain the existing testnet behavior; `--personal-test`
also works on testnet for rehearsing the private flow.

On **mainnet**, deploy and use **your own private copy only**. Neither Pipln
nor the founder operates a financial service for other people. After setting
`YOUR_ACCOUNT`, `YOUR_NODE_RPC` and the actual `MAINNET_CHAIN_ID` from your
wallet/node, first inspect the offline plan:

```bash
python3 scripts/publish.py --network mainnet --personal-test --dry-run \
  --apps amm --from "$YOUR_ACCOUNT" --chain-id "$MAINNET_CHAIN_ID"

# Run from the repository root when you choose to deploy your own instance.
# Your EIP-1193 wallet approves each transaction; no key is passed to Python.
python3 scripts/publish.py --network mainnet --personal-test \
  --apps amm --from "$YOUR_ACCOUNT" --chain-id "$MAINNET_CHAIN_ID" \
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
