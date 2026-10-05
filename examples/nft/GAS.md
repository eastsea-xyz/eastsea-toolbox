# 예제 2 가스·상태 비용 — 온체인 NFT + 에디션

측정 환경: forge 1.6.0-nightly (5e88010), solc 0.8.24, optimizer 200 runs,
evm paris. 원본: `forge test --match-path 'test/nft/*' -vv` 의 `test_meter_*`.

## OnchainNFT (ERC-721, 온체인 JSON+SVG)

| 연산 | gasUsed¹ | 새 슬롯 | 로그 B | 상태 units |
|---|---:|---:|---:|---:|
| 배포 (name/symbol/maxSupply/royalty/guardian) | 2,427,950 | 4 | 224 | **12,053** |
| mint — 신규 보유자 첫 토큰 | 73,113 | 3 | 384 | **312** |
| mint — 신규 토큰, 기존 보유자² | (미측정) | 2 | 384 | **≈212** |
| transferFrom — 수신자 첫 보유 | 25,490 | 1 | 192 | **106** |
| burn | (미측정) | −1 | 192 | **≈6** (cleared slot 반납) |

¹ gasleft 근사 — intrinsic/영수증 제외. 체인 부과분( envelope 128B +
  calldata)은 별도, 예제 1 GAS.md 참조.
² 슬롯 내역 — mint: `_owners[id]` + `_traits[id]` + `_balances[to]`(첫 보유).
  기존 보유자는 balances 슬롯이 이미 있어 2.
  로그: Transfer 192 + Minted 192 = 384B.

**핵심 관찰:**
- 특성 4개 pack 덕에 mint가 슬롯 2~3개에 머문다. 특성당 매핑이었다면
  mint마다 +300 units씩 추가됐을 것이다.
- burn은 `_traits` 슬롯을 **반납**한다 (cleared slot은 새 슬롯으로 안 친다).
  소각 가능한 NFT는 컬렉션 수명 후반의 상태 정리에 유리하다.
- 배포 코드 11,553B = 11,553 units — 온체인 조립 로직의 고정비. 뷰 호출
  상태 비용은 0이므로, 컬렉션이 커질수록 슬롯 절약이 이를 상쇄한다.

## Editions1155 (ERC-1155, 유한 에디션 판매)

| 연산 | gasUsed¹ | 새 슬롯 | 로그 B | 상태 units |
|---|---:|---:|---:|---:|
| 배포 (guardian) | 2,089,555 | 0 | — | **10,372** |
| createEdition (name/cap/wallet/price/fee) | 74,610 | 3 | 384 | **312** |
| mint 1장 — 해당 구매자·에디션 첫 조합 | 41,459 | 1 | 448 | **114** |
| mint 1장 — 같은 구매자 추가 구매² | (미측정) | 0 | 448 | **14** |
| withdraw — 에디션 첫 인출 | 59,278 | 1 | 192 | **106** |

¹ gasleft 근사.
² 슬롯 내역 — createEdition: Edition struct 2슬롯(pack) + `_names` 1.
  mint: `_balances[owner][id]` 1슬롯 (같은 조합 재구매는 기존 슬롯 수정).
  withdraw: `_withdrawn[id]` 1슬롯.

**핵심 관찰:**
- **같은 구매자의 추가 구매는 슬롯 0** —ERC-1155 balances가 (owner, id)
  쌍 매핑이기 때문. 에디션 1개를 한 사람이 10장 사면 상태 비용은 첫
  장의 114 units가 전부다.
- 인출 가능액을 `price×minted−withdrawn`으로 계산해 credited 매핑을
  없앴다 — mint는 슬롯를 만들지 않고, 정산 상태는 인출 시에만 1슬롯.
- 지갑당 상한 검사가 `balanceOf` 조회로 끝난다 — 별도 카운터 슬롯 없음.

## 대량 발행 시나리오 비교 (설계 시사점)

5,000장 발행 기준 근사:

| 방식 | 슬롯 | 상태 units |
|---|---:|---:|
| ERC-721 (특성 pack) | 2/장 | ≈1,060,000 |
| ERC-1155 단일 에디션, 5,000명이 1장씩 | 1/구매자 | ≈570,000 |
| ERC-1155 단일 에디션, 500명이 10장씩 | 1/구매자 | ≈107,000 |

컬렉션 규모가 크거나 1인 다량 보유가 예상되면 1155 에디션이 유리하다.
1/1 고유 아트·특성 조합이 판매 포인트면 721을 쓰되 pack을 유지하라.

## 재측정

```bash
cd contracts
forge test --match-path 'test/nft/*' -vv 2>&1 | grep -E 'deploy |mint-|transfer-|createEdition |withdraw '
FOUNDRY_FUZZ_RUNS=5000 forge test --match-path 'test/nft/*'  # 심층 (solvency fuzz)
```
