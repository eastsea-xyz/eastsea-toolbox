# 예제 1 — 고정 공급 ERC-20 (`FixedSupplyToken`)

한 번 발행되면 영원히 추가 발행이 불가능한 표준 ERC-20 토큰. 커뮤니티 포인트,
게임 재화, 소규모 프로젝트 코인의 기본형. EIP-2612 permit을 포함해 가스 승인
없이 서명만으로 승인할 수 있다.

**계약:** `contracts/src/token/FixedSupplyToken.sol` (MIT)
**테스트:** `contracts/test/token/FixedSupplyToken.t.sol` (11개)

## 왜 이 모양인가

- **출시 후 mint 없음.** `mint` 계열 진입점이 ABI에 존재하지 않는다
  (테스트 `test_noMintEntryPointAfterLaunch`가 이를 검증). 인플레이션
  리스크를 계약 구조로 제거한다. 발행을 늘리고 싶으면 새 컨트랙트를
  배포하는 것 외에는 없다.
- **permit 포함.** approve 트랜잭션을 생략하고 서명 하나로 승인할 수
  있다. 지갑 사용자에게 tx 1건(≈ 새 슬롯 1개)을 아끼게 해 준다.
- **18 decimals 고정.** 이체 정밀도 문제를 만들지 않는 표준값.

## 배포

```bash
cd contracts
forge create src/token/FixedSupplyToken.sol:FixedSupplyToken \
  --constructor-args "Island Coin" "ISLE" 1000000000000000000000000 0xYOUR_ADDRESS \
  --rpc-url $EASTSEA_RPC --private-key $KEY
```

생성자: `(name, symbol, supply, recipient)` — `supply`는 18 decimals 원시
값. 수령인 주소를 다시 확인하라. **한 번 배치되면 되돌릴 방법이 없다.**

## EastSea 특성-note

| 항목 | 값 (측정: `test_meter_*`, 상세는 GAS.md) |
|---|---|
| 배포 | gas 886,650 · 코드 3,839 B (≈3,839 units) · 신규 슬롯 4 · **총 4,345 units** |
| 첫 이체 (신규 보유자) | gas 27,016 · 신규 슬롯 1 · **106 units** |
| 재이체 (기존 보유자) | gas 4,318 · 신규 슬롯 0 · **6 units** |
| 첫 approve | gas 23,693 · 신규 슬롯 1 · **106 units** |

- 첫 이체가 수신자 슬롯을 만든다(100 units). 즉 **에어드랍 수신자 수만큼
  상태 비용이 발신자에게 누적된다** — 대량 분배는 예제 13(Merkle)로.
- 전체 공급이 한 주소에서 시작하므로 분배는 이체만으로 — 초기 홀더의
  분배 tx가 초기 상태 비용의 대부분을 결정한다.

## 커스터마이징 가이드

- **mint 가능 토큰이 필요하면:** 이 파일을 복제한 뒤 `_mint`를 호출하는
  소유자 함수를 추가하지 말 것. 대신 명시적 발행 정책(예: 연간 상한,
  멀티시그 게이트)을 문서화하고, 예제 8(멀티시그) 또는 예제 11(거버넌스)과
  결합하라.
- **fee-on-transfer / rebasing 토큰으로 만들지 마라.** 이 toolbox의 모든
  예제(마켓, 스테이킹, 에스크로)는 표준 ERC-20을 가정한다. 비표준 토큰을
  만들면 이 코인을 받는 모든 제3자 컨트랙트가 F-02/F-03 계열 결함에
  노출된다.

## 프론트엔드

`apps/token/index.html` — 잔액 조회 · 이체 · permit 서명 전송 (EIP-1193).

## 관련 문서

- [SECURITY.md](./SECURITY.md) — 위협 모델과 감사 결과(F-01..F-08) 매핑
- [GAS.md](./GAS.md) — 측정 원본 데이터
- [manifest.json](./manifest.json) — 앱 레지스트리 게시용 템플릿

## Personal test instance: testnet and mainnet

<!-- i18n: personal_test.title personal_test.testnet personal_test.mainnet personal_test.accounts personal_test.local personal_test.fees personal_test.caps personal_test.identity -->

On **testnet**, use test coins. A shared demo is allowed. Publish with your
own wallet using `--network testnet --apps token` and the testnet registry,
names service and owned name described in the [publisher guide](../../README.md#try-the-toolbox-on-the-eastsea-testnet-with-your-own-account).
Ordinary constructors retain the existing testnet behavior; `--personal-test`
also works on testnet for rehearsing the private flow.

On **mainnet**, deploy and use **your own private copy only**. Neither Pipln
nor the founder operates a financial service for other people. After setting
`YOUR_ACCOUNT`, `YOUR_NODE_RPC` and the actual `MAINNET_CHAIN_ID` from your
wallet/node, first inspect the offline plan:

```bash
python3 scripts/publish.py --network mainnet --personal-test --dry-run \
  --apps token --from "$YOUR_ACCOUNT" --chain-id "$MAINNET_CHAIN_ID"

# Run from the repository root when you choose to deploy your own instance.
# Your EIP-1193 wallet approves each transaction; no key is passed to Python.
python3 scripts/publish.py --network mainnet --personal-test \
  --apps token --from "$YOUR_ACCOUNT" --chain-id "$MAINNET_CHAIN_ID" \
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
