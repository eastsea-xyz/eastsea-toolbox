# 예제 3 — 고정가 NFT 마켓플레이스 (`FixedPriceMarket`)

판매자가 NFT를 마켓에 맡기고(list) 고정가를 붙인다. 구매자가 정확한 가격을
내면 NFT를 즉시 받고, **대금은 즉시 송금되지 않고 크레딧으로 적립**된다 —
판매자와 로열티 수신자가 각자 인출하는 pull payments. 감사 결과 F-01(예치
재진입)의 교과서 대응이 이 컨트랙트의 주제다.

**계약:** `contracts/src/market/FixedPriceMarket.sol` (MIT)
**테스트:** `contracts/test/market/FixedPriceMarket.t.sol` (18개 — 재진입 PoC 2종·솔번시 fuzz 포함)
**통합:** 예제 2의 `OnchainNFT`(EIP-2981)를 로열티 소스로 사용

## 왜 이 모양인가

- **pull payments.** 구매 시 판매자에게 아무것도 push하지 않는다. 크레딧
  슬롯만 옮기고 끝낸다 — 판매자가 악성 컨트랙트이거나, 가스를 다 써버리는
  receive를 가져도 구매가 실패하지 않는다.
- **정산 확정이 NFT 전달보다 먼저.** `buy`는 listing 삭제 → 크레딧 적립 →
  NFT 전달 순서. 구매자 ERC-721 콜백이 재진입을 시도해도 정산은 이미
  끝나 있다. 거기에 `nonReentrant`까지 — 두 겹.
- **로열티는 선택적 존중.** NFT가 EIP-2981을 지원하면 `royaltyInfo`로
  분할, 미지원이면 전액 판매자. 코드가 없는 주소(F-03 계열)는 지원
  않는 것으로 간주. 악의적 과다 로열티(>100%)는 판매가로 클램프.
- **탈출은 항상 열림.** brake가 신규 list/buy를 막아도 cancel(에스크로
  반환)과 withdraw는 항상 열려 있다.

## 배포

```bash
cd contracts
forge create src/market/FixedPriceMarket.sol:FixedPriceMarket \
  --constructor-args 0xGUARDIAN \
  --rpc-url $EASTSEA_RPC --private-key $KEY
```

| 사용법 | 호출 |
|---|---|
| 판매 등록 | NFT에서 `approve(마켓, tokenId)` 또는 `setApprovalForAll(마켓, true)` → 마켓 `list(nft, tokenId, price)` |
| 구매 | `buy{value: price}(listingId)` — 정확한 금액만 |
| 철회 | `cancel(listingId)` (판매자) |
| 정산 | `withdraw()` (판매자·로열티 수신자 각자) |

## EastSea 상태 비용 (측정: `test_meter_*`, 상세 GAS.md)

| 연산 | gas | 새 슬롯 | 상태 units |
|---|---:|---:|---:|
| 배포 | 889,008 | 0 | **4,379** (코드 4,079B) |
| list (승인 예열 후) | 123,801 | 4 | **414** |
| buy (로열티 분할 포함) | 84,040 | 2 | **213** |
| withdraw | 37,911 | 0 | **5** |

- **리스팅 1건 = 4슬롯** (Listing struct: seller/token/tokenId/price 각각).
  무료 재등록 같은 건 없다 — 리스팅은 만들거나 지우거나 둘 중 하나.
- **buy의 2슬롯은 크레딧 첫 적립.** 같은 판매자·로열티 수신자의 이후
  판매는 슬롯 없이 기존 크레딧에 합산된다 (추가 13 units).
- **withdraw는 사실상 공짜** (5 units, 클리어만).

## 커스터마이징 경고

- **판매가의 수수료(마켓 수수료)를 넣고 싶으면** 크레딧 분할 지점
  (`_split` 결과 적립)만 고치면 된다 — pull 구조가 그대로 재진입을
  막아준다. 단 불변식 `Σ credits == balance`이 유지되는지 fuzz를 다시
  돌려라.
- **경매·네덜란드 경매로 확장할 때** 가격이 시간 함수가 되면
  `WrongPrice` 검사가 청구 금액 계산과 어긋날 수 있다. 청구는
  정산 시점의 체인 상태 기준 한 곳에서만 계산하라.
- 목록 페이지는 `Listed`/`Sold`/`Cancelled` 이벤트 인덱스로 만든다 —
  순회 뷰를 컨트랙트에 넣지 마라 (F-04).

## 프론트엔드

`apps/market/index.html` — 리스팅 목록(이벤트 인덱스) · list/buy/cancel/withdraw.

## 관련 문서

- [SECURITY.md](./SECURITY.md) — F-01 대응 상세, 재진입 PoC, 솔번시 불변식
- [GAS.md](./GAS.md) — 측정 원본 데이터
- [manifest.json](./manifest.json) — 앱 레지스트리 게시용 템플릿

## Personal test instance: testnet and mainnet

<!-- i18n: personal_test.title personal_test.testnet personal_test.mainnet personal_test.accounts personal_test.local personal_test.fees personal_test.caps personal_test.identity -->

On **testnet**, use test coins. A shared demo is allowed. Publish with your
own wallet using `--network testnet --apps market` and the testnet registry,
names service and owned name described in the [publisher guide](../../README.md#try-the-toolbox-on-the-eastsea-testnet-with-your-own-account).
Ordinary constructors retain the existing testnet behavior; `--personal-test`
also works on testnet for rehearsing the private flow.

On **mainnet**, deploy and use **your own private copy only**. Neither Pipln
nor the founder operates a financial service for other people. After setting
`YOUR_ACCOUNT`, `YOUR_NODE_RPC` and the actual `MAINNET_CHAIN_ID` from your
wallet/node, first inspect the offline plan:

```bash
python3 scripts/publish.py --network mainnet --personal-test --dry-run \
  --apps market --from "$YOUR_ACCOUNT" --chain-id "$MAINNET_CHAIN_ID"

# Run from the repository root when you choose to deploy your own instance.
# Your EIP-1193 wallet approves each transaction; no key is passed to Python.
python3 scripts/publish.py --network mainnet --personal-test \
  --apps market --from "$YOUR_ACCOUNT" --chain-id "$MAINNET_CHAIN_ID" \
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
