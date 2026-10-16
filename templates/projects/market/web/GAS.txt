# 예제 3 가스·상태 비용 — `FixedPriceMarket`

측정 환경: forge 1.6.0-nightly (5e88010), solc 0.8.24, optimizer 200 runs,
evm paris. 원본: `forge test --match-path 'test/market/*' -vv`.

## 측정치 (2026-10-06)

| 연산 | gasUsed¹ | 새 슬롯 | 로그 B | 상태 units |
|---|---:|---:|---:|---:|
| 배포 (guardian) | 889,008 | 0 | — | **4,379** (코드 4,079B) |
| list (approve 예열 후) | 123,801 | 4 | 448 | **414** |
| buy (5% 로열티 분할 포함) | 84,040 | 2 | 416 | **213** |
| buy — 판매자·수신자 기존 크레딧² | (미측정) | 0 | 416 | **13** |
| cancel | (미측정) | −4 | 192 | **≈6** (Listing 4슬롯 반납) |
| withdraw | 37,911 | 0 | 160 | **5** |

¹ gasleft 근사 — intrinsic/영수증 제외. 체인 부과분(envelope 128B +
  calldata)은 별도 (예제 1 GAS.md).
² buy의 새 슬롯 2 = `credits[seller]` + `credits[royaltyReceiver]` 첫 적립.
  같은 주소의 이후 정산은 기존 슬롯 합산.

## 슬롯 내역

- **list 4슬롯** = Listing struct (`seller`, `token`, `tokenId`, `price`
  각각 — address 2개는 pack 불가 40B). 리스팅 생성은 비싸고, 소진/취소 시
  전부 반납된다.
- **cancel은 상태 관점 이득** — Listing 4슬롯을 클리어한다 (cleared slot은
  새 슬롯으로 안 친다). 활성 리스팅 수만 슬롯을 점유한다.
- **withdraw 0슬롯** — credits 클리어만 (cleared slot).

## 시나리오 근사: 마켓의 총 상태 비용

| 시나리오 | 근사 units |
|---|---:|
| 배포 | 4,379 |
| + 리스팅 100건 활성 | 100 × 414 = 41,400 |
| + 그중 60건 판매 (구매자 30명, 로열티 수신자 1) | 60 × 13~213 ≈ 5,000 |
| + 인출 완료 | ±0 (클리어) |

활성 리스팅이 마켓 상태 비용의 대부분이다 — 리스팅당 4슬롯은 struct
정규화의 대가. (pack 최적화 여지: tokenId를 uint96으로 줄이면 seller+token
합쳐… 여전히 40B로 불가. 3슬롯이 한계다 — 커스터마이징 시도 감수.)

## 설계 시사점

- **pull payments는 상태 비용에서도 이긴다.** 즉시 push였다면 판매자
  EOA 신규 계정(100u)을 만들 수 있지만, 크레딧 방식은 1슬롯(100u)로
  같은 효과 + 재진입 안전.
- **같은 판매자의 반복 판매는 13 units** — 마진 있는 중고 거래 모델에
  적합. 첫 판매만 213 units를 지불한다.
- cancel이 슬롯을 4개 반납한다는 점은 짧은 판매(경매 전 시험판매 등)에도
  상태적으로 무해하다는 뜻이다.

## 재측정

```bash
cd contracts
forge test --match-path 'test/market/*' -vv 2>&1 | grep -E 'deploy |list |buy |withdraw '
FOUNDRY_FUZZ_RUNS=5000 forge test --match-path 'test/market/*'  # 심층 (solvency fuzz)
```
