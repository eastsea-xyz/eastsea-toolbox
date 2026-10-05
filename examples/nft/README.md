# 예제 2 — 온체인 NFT (ERC-721) + 유한 에디션 (ERC-1155)

두 컨트랙트가 한 쌍을 이룬다:

- **`OnchainNFT` (ERC-721)** — 메타데이터가 전부 체인 안에 있다. 특성 4개를
  스토리지 슬롯 하나에 pack하고, `tokenURI`가 JSON+SVG를 실시간 조립해
  data URI로 돌려준다. 외부 IPFS·HTTP 게이트웨이 의존 없음 — 이미지가
  죽으면 NFT도 죽는 일이 구조적으로 없다. 발행은 크리에이터 전용.
- **`Editions1155` (ERC-1155)** — 크리에이터가 에디션(한도·단가·지갑당
  상한·로열티 bps)을 만들고 누구나 정확한 가격을 내고 산다. **판매대금을
  보관하는 쪽은 이쪽이다** — brake, nonReentrant, 솔번시 불변식이 붙는다.

**계약:** `contracts/src/nft/OnchainNFT.sol`, `contracts/src/nft/Editions1155.sol` (MIT)
**테스트:** `contracts/test/nft/*.t.sol` (34개 — 18 + 16, 재진입 PoC·솔번시 fuzz 포함)

## 왜 이 모양인가

- **특성 4개 = 슬롯 1개.** 색·형태·패턴·후광을 각각 매핑에 파면 tokenId마다
  +300 units다. 한 단어(uint256)에 pack해 mint 1건을 슬롯 2개로 유지한다.
- **뷰는 공짜.** JSON/SVG 조립은 전부 `view` — 상태 비용 0. 온체인 메타데이터의
  실제 비용은 mint 시점에만 발생한다.
- **정확한 가격만 받는다.** 과다 납부 환불 경로를 만들지 않는다 — 환불은
  재진입·오류 표면이다. 지갑 UI가 정확한 값을 보내면 그걸로 끝난다.
- **에디션 struct 2슬롯 패킹.** creator(20B)+fee(2B)+maxPerWallet(4B)+cap(6B)가
  슬롯 1, minted(8B)+price(16B)가 슬롯 2. 인출 가능액은 `price×minted−withdrawn`로
  계산 — credited 매핑 자체가 없다.
- **brake는 진입만 막는다.** mint/createEdition이 정지되도 withdraw는 항상
  열린다 (IEastSeaBrake §8.2 계약).

## 배포

```bash
cd contracts
# 721: (name, symbol, maxSupply, royaltyFeeNumerator, brakeGuardian)
forge create src/nft/OnchainNFT.sol:OnchainNFT \
  --constructor-args "Island Folk" "IFLK" 100 500 0xGUARDIAN \
  --rpc-url $EASTSEA_RPC --private-key $KEY

# 1155: (brakeGuardian)
forge create src/nft/Editions1155.sol:Editions1155 \
  --constructor-args 0xGUARDIAN \
  --rpc-url $EASTSEA_RPC --private-key $KEY
```

에디션 생성: `createEdition("Harbor Print", cap=5, maxPerWallet=2, price=0.01e18, feeBps=250)`.

로열티 상한 10% (FEE_CAP_BPS=1000), 이름 64B, cap 최대 2^48.

## EastSea 상태 비용 (측정: `test_meter_*`, 상세 GAS.md)

| 연산 | gas | 새 슬롯 | 상태 units |
|---|---:|---:|---:|
| OnchainNFT 배포 | 2,427,950 | 4 | **12,053** (코드 11,553B) |
| 721 mint (신규 보유자) | 73,113 | 3 | **312** |
| 721 transfer (2차) | 25,490 | 1 | **106** |
| Editions1155 배포 | 2,089,555 | — | **10,372** (코드 10,072B) |
| 에디션 생성 | 74,610 | 3 | **312** |
| 1155 mint 1장 (첫 구매자) | 41,459 | 1 | **114** |
| 크리에이터 인출 | 59,278 | 1 | **106** |

- **ERC-721은 1장 = 소유권 슬롯 + 특성 슬롯.** ERC-1155는 (소유자, 토큰) 쌍이
  슬롯 1개 — 같은 에디션을 여러 장 사도 첫 구매만 슬롯를 만든다. 대량
  발행이면 1155가 압도적으로 저렴하다 (5,000장 에디션: 721은 ≈1,000,000u,
  1155는 구매자 수만큼만).
- 코드가 컸다는 점(≈10-12k units)은 온체인 조립 로직의 대가 — 한 번 배포하면
  끝이고, 뷰 호출에는 청구되지 않는다.

## 721 vs 1155 선택 가이드

| | ERC-721 `OnchainNFT` | ERC-1155 `Editions1155` |
|---|---|---|
| 한 장의 고유성 | 1/1 (토큰마다 고유 특성) | 에디션 내 동질 (1/N) |
| mint 상태 비용 | 슬롯 2/장 (traits+owner) | 슬롯 ~1/구매자 |
| 판매 수익 | 없음 (크리에이터 발행) | 컨트랙트 적립 → 인출 |
| 재진입 표면 | safeMint 콜백 | payable mint + 콜백 (nonReentrant) |

## 커스터마이징 경고

- **특성 개수를 늘릴 때** pack 비트 폭(현재 64/256비트)을 먼저 확인하라.
  슬롯을 넘치면 조용히 2슬롯이 된다 — GAS.md 수치가 무효화된다.
- **가격을 0이 아닌 값으로 바꿀 때** `mint`의 `msg.value != price` 검사와
  솔번시 불변식(`Σ withdrawable == balance`)이 세트다. 하나만 고치지 마라.
- 오프체인 이미지(IPFS 등)로 바꾸고 싶다면 `jsonOf`/`svgOf`만 교체하면
  된다 — 저장 구조(traits pack)는 그대로 유효하다.

## 프론트엔드

`apps/nft/index.html` — 갤러리 뷰(온체인 SVG 렌더) · mint · 에디션 구매 · 인출.

## 관련 문서

- [SECURITY.md](./SECURITY.md) — F-01 재진입 PoC, 솔번시 불변식, brake 동작
- [GAS.md](./GAS.md) — 측정 원본 데이터
- [manifest.json](./manifest.json) — 앱 레지스트리 게시용 템플릿
