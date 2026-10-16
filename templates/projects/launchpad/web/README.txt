# 예제 5 — 본딩 커브 런치패드 (`BondingLaunchpad`)

> ## ⚠️ 법적 고지 — 공개 배포 전 법률 검토 필수
>
> **Do not deploy publicly until legal review.** 토큰 발행(token issuance)은
> EastSea 앱 레지스트리의 **제한 카테고리**다. 이 예제는 기술 템플릿일
> 뿐이며, 실제 공개 서비스로 운영하려면 관할권의 증권·상품 관련 법률
> 검토를 먼저 마쳐야 한다 (docs/legal-notes.md 참조).
>
> 이 예제는 **수익률·가격 보장을 약속하지 않는다.** 커브 가격은 수학적
> 스프레드를 반영할 뿐 미래 가격을 예측하지 않고, 추천 보상·코인 리베이트
> 구조를 포함하지 않는다.

ERC-20 quote로 신규 토큰을 상수곱 가상 리저브 커브에서 매매하고, 모금
목표에 도달하면 예제 4의 AMM 페어로 유동성을 이전하는("졸업") 런치패드.
이 예제의 주제는 **안티스나이핑과 졸업 흐름**이다.

**계약:** `contracts/src/launchpad/BondingLaunchpad.sol` (단일 컨트랙트 —
커브 토큰은 예제 1의 `FixedSupplyToken`을 생성자에서 내부 배포)

**테스트:** 27개 (`contracts/test/launchpad/BondingLaunchpad.t.sol`) —
왕복 비차익 fuzz, 가상 k 비감소 fuzz, 스나이프 세금 감쇠, 졸업·선점
공격 2종, brake 매트릭스, FoT quote 실측 포함.

## 커브 수학

```
vq = 커브 보유 quote + quoteFloor      vt = 커브 보유 토큰 + tokenFloor
매수 out = vt * netIn / (vq + netIn)   매도 out = vq * in / (vt + in)
```

- 리저브는 **실제 잔액 기반** — 매도로 돌아온 토큰은 자동으로 재판매
  물량이 된다. 별도 회계 상태가 없어 커브 자체는 무상태다.
- `feeBps`(매수·매도 공통)와 스나이프 세금은 treasury로 나가므로
  **유효 리저브 곱 vq×vt는 매매로 줄지 않는다** — fuzz로 매 거래 검증
  (`test_fuzz_virtualKNeverDecreases`).
- 즉시 왕복(매수→전량 매도)은 항상 손해다 — fee 2회 + 스프레드
  (`test_fuzz_roundTripNeverProfits`).

## 안티스나이핑 — 두 겹

| 방어 | 동작 | 상태 비용 |
|---|---|---|
| 감쇠 세금 | launch 후 `snipeWindow` 초 동안 매수액에서 `snipeTaxBps`가 **선형 감쇠**하며 treasury로 (t=0 최대, t≥window 0) | 없음 (block.timestamp 계산) |
| 개인 한도 | 졸업 전 보유 상한 `perBuyerCap` — 커브 토큰 잔액 조회로 검사 | 없음 (기존 잔액 슬롯 재사용) |

실측(fee 1% + snipe 20%, window 3600s): t=0 매수 100 → treasury 21
(fee 1 + 세금 20) · t=1800 → 11 (1 + 10) · t=3600 → 1 (세금 소멸).

## 졸업 흐름

1. 커브 보유 quote ≥ `graduationTarget`이면 다음 매수부터
   `TargetReached` — **누구나** `graduate()` 호출 가능.
2. (커브 토큰, quote) 페어 확보 — 없으면 생성. **이미 있으면 LP 공급이
   MINIMUM_LIQUIDITY(1000) 이하일 때만 재사용**하고, 초과 예치가 있으면
   `PairPoisoned` (선점 유동성 절도 방지).
3. 커브 자산 전액 + 남은 토큰을 페어로 이전 → LP를 `0x..dEaD`에 **영구
   잠금** (회수·판매 경로 없음).
4. 이후 커브 매매는 `Closed` — 거래는 AMM에서.

- 졸업 프론트런은 무해하다: 호출자가 아무것도 받지 않는 구조.
- 목표 도달 후에도 **매도는 계속 열려 있다** — 매도로 raised가 목표
  밑으로 내려가면 매수가 다시 열린다 (커브는 계속 유효).

## brake

| brake | buy(진입) | sell(탈출) | graduate |
|---|---|---|---|
| 0 정상 | 허용 | 허용 | 허용 |
| 1 신규 진입 정지 | **차단** | **허용** | **차단** (페어 생성 = 진입) |

brake 중 자금이 갇히지 않는다 — 커브 quote는 매도로 언제든 인출 가능.

## 배포

```bash
cd contracts
forge create src/launchpad/BondingLaunchpad.sol:BondingLaunchpad \
  --constructor-args "0xGUARDIAN" "0xQUOTE" "0xAMM_FACTORY" \
  '["Curve Coin","CRV",1000000000000000000000000,100000000000000000000,100000000000000000000,1000000000000000000000,100,2000,3600,0,"0xTREASURY"]' \
  --rpc-url $EASTSEA_RPC --private-key $KEY
```

Config 배열 순서: `[name, symbol, tokenSupply, quoteFloor, tokenFloor,
graduationTarget, feeBps, snipeTaxBps, snipeWindow, perBuyerCap, treasury]`.

## EastSea 상태 비용 (측정: `test_meter_*`, 상세 GAS.md)

| 연산 | gas | 새 슬롯 | 상태 units |
|---|---:|---:|---:|
| 런치패드 배포 (커브 토큰 배포 제외) | 2,528,972 | 0 | **8,123** (코드 7,917B) |
| 커브 토큰 배포 (예제 1 동일 컨트랙트) | 886,650 | 4 | **4,345** |
| buy | 95,765 | 0 | **26** |
| sell | 25,257 | 0 | **25** |
| graduate (런치패드 슬롯만) | 1,916,505 | 1 | **149** (+ 페어 배포 8,196u) |

- **매매는 커브 자체가 무상태라 25~26u** (로그만). AMM 스왑(20~32u)과
  같은 비용대 — 고빈도 트래픽에 적합.
- 고정 초기 비용 ≈ 8,123 + 4,345 + (졸업 시) 8,196 ≈ **20,664u**.
  토큰 1개를 띄우는 전체 수명 비용이 여기서 결정된다.

## 커스터마이징 경고

- **LP dead 잠금은 되돌릴 수 없다.** 운영 수익 모델로 LP 일부를
  treasury/vesting 하려면 graduate()를 고치되 — 그 순간 "졸업 프론트런
  무해" 성질이 깨지므로 타이밍 공격을 재검토하라.
- **floors가 도달 가능성을 결정한다.** `quoteFloor × tokenFloor`가 커브
  곱 k0의 하한을 만든다 — target이 k0/tokenFloor - quoteFloor보다 크면
  수학적으로 도달 불가능하다. 배포 전 산술 확인 필수.
- 스나이핑 파라미터(snipeTaxBps + snipeWindow)는 **탈출 세금이 아니다.**
  매도에 세금이 없는 이유: 탈출 세금은 반대 방향 스냅(놓치고 팔기)을
  유도한다. 매수 진입에만 부과한다.
- `perBuyerCap`은 다중 주소로 우회된다 — 완화책이지 방어선이 아니다
  (SECURITY.md).

## 프론트엔드

`apps/launchpad/index.html` — 커브 가격 표시 · 매수/매도 · 졸업 상태.

## 관련 문서

- [SECURITY.md](./SECURITY.md) — 선점 공격 2종, F 매핑, 고유 위험
- [GAS.md](./GAS.md) — 측정 원본 데이터
- [manifest.json](./manifest.json) — 앱 레지스트리 게시용 템플릿 (제한 카테고리)

## Personal test instance: testnet and mainnet

<!-- i18n: personal_test.title personal_test.testnet personal_test.mainnet personal_test.accounts personal_test.local personal_test.fees personal_test.caps personal_test.identity -->

On **testnet**, use test coins. A shared demo is allowed. Publish with your
own wallet using `--network testnet --apps launchpad` and the testnet registry,
names service and owned name described in the [publisher guide](../../README.md#try-the-toolbox-on-the-eastsea-testnet-with-your-own-account).
Ordinary constructors retain the existing testnet behavior; `--personal-test`
also works on testnet for rehearsing the private flow.

On **mainnet**, deploy and use **your own private copy only**. Neither Pipln
nor the founder operates a financial service for other people. After setting
`YOUR_ACCOUNT`, `YOUR_NODE_RPC` and the actual `MAINNET_CHAIN_ID` from your
wallet/node, first inspect the offline plan:

```bash
python3 scripts/publish.py --network mainnet --personal-test --dry-run \
  --apps launchpad --from "$YOUR_ACCOUNT" --chain-id "$MAINNET_CHAIN_ID"

# Run from the repository root when you choose to deploy your own instance.
# Your EIP-1193 wallet approves each transaction; no key is passed to Python.
python3 scripts/publish.py --network mainnet --personal-test \
  --apps launchpad --from "$YOUR_ACCOUNT" --chain-id "$MAINNET_CHAIN_ID" \
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
