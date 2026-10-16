# 예제 3 보안 노트 — `FixedPriceMarket`

## 자금 보관

**NFT와 판매대금을 둘 다 보관한다.** 이 컨트랙트는 감사 결과 F-01이 지목한
바로 그 유형(예치 재진입)을 정면으로 다루는 예제다.

## F-01..F-08 매핑

| 항목 | 이 예제와의 관계 |
|---|---|
| **F-01** 예치 재진입 | **주제.** 방어는 3겹: (1) 대금은 절대 push하지 않는다 — pull payments. (2) `buy`는 listing 삭제(정산 확정)를 NFT 전달보다 먼저. (3) `buy`/`cancel`/`withdraw` 전부 `nonReentrant`. **PoC 2종이 둘 다 검증**: 구매자 `onERC721Received`에서 `buy` 재시도 → 실패 / withdraw 수신 `receive()`에서 `withdraw` 재시도 → 실패. |
| **F-02** fee-on-transfer | 무관 — native(AETH) 결제만 받는다. |
| **F-03** 무코드 토큰 | 로열티 조회 직전에 `l.token.code.length > 0` 검사 — 코드 없는 주소에 `supportsInterface`를 호출하지 않는다. 지원하지 않으면 전액 판매자. |
| **F-04** 무한 view | 리스팅 순회 뷰 없음. `listingOf(id)` 개별 조회만 — 목록은 이벤트 인덱스로. |
| **F-05** EIP-7702 | 무관. |
| **F-06** 단일 registrar 키 | 무관. |
| **F-07** 오픈 로그 ≠ 승인 | `Listed`는 누구나 emit을 읽을 수 있지만 승인이 아니다. 실제 권한은 에스크로된 NFT 소유권뿐. |
| **F-08** randomness | 무관. |

## 구현 중 잡은 실제 버그 (기록)

초안 `buy`가 `delete _listings[listingId]` 뒤에 storage 포인터 `l`을 다시
읽었다 — delete로 스토리지가 0화된 뒤 `l.token`은 `address(0)`이 되고,
`safeTransferFrom`이 "call to non-contract address 0x0"으로 죽었다.
**effects-먼저 패턴을 쓸 때는 delete 전에 지역 복사를 마쳐야 한다.**
테스트(`test_buy_royaltySplit`)가 이를 즉시 잡았다 — 이것이 "자금 보관
컨트랙트엔 통합 테스트가 필수"인 이유.

## 이 예제 고유 위험과 완화

| 위험 | 완화 |
|---|---|
| **악성 판매자 receive** | 판매자에게 push가 없으므로 표면 자체가 없다. 판매자는 withdraw 시점에 자기 콜백을 만난다. |
| **악성 구매자 ERC-721 콜백** | 콜백에서 재진입 buy 시도 → listing이 이미 삭제돼 `UnknownListing` + `nonReentrant`. 콜백이 revert하면 구매 자체가 실패 — EOA 지갑 사용자는 영향 없음. |
| **로열티 수신자가 악성 컨트랙트** | 로열티도 크레딧 적립(push 아님). 수신자의 withdraw 실패는 그 수신자만의 문제. |
| **마켓이 NFT를 영구 잠금** | `cancel`은 brake·가디언과 무관하게 항상 열려 있다. 마켓이 브레이크 상태여도 판매자는 NFT를 회수할 수 있다. |
| **과다 로열티 클레임 (악성 2981)** | `royalty > price`면 price로 클램프. 판매자 몫이 음수가 되는 일은 없다. |
| **가격 프론트런** | 고정가라 표면이 없다. 시간 기반 가격으로 확장 시 재검토 필요. |
| **우연 입금** | `buy`는 정확한 금액만 받고, 그 외 경로로 들어온 native는 그 누구의 크레딧에도 포함되지 않는다 — 인출 경쟁 원천 차단. |

## 솔번시 불변식

`test_fuzz_solvency` (리스팅 6 × 구매자 2 × 30 스텝 무작위 buy/cancel/withdraw):

```
sum(credits) == address(this).balance   (매 스텝 검증)
```

이것이 깨지는 경로: 크레딧 누락(정산 로직 오류), 이중 인출, 미정산 잔액.
CI 1000 runs / 로컬 5000 runs.

## 퍼짱으로도 못 밝히는 것

- 로열티 `royaltyInfo`의 비-뷰 부작용 (IERC2981 위반 컨트랙트) — 정의상
  view지만, 악성 컨트랙트가 state를 바꾸면 체인에서 관측해야 한다.
- 지갑 UI의 잘못된 listingId 전달 — 프론트 검증.
- 가디언 키 운영 (docs/safety-checklist.md).
