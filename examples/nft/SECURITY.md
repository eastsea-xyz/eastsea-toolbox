# 예제 2 보안 노트 — 온체인 NFT + 에디션

## 자금 보관 여부

| 컨트랙트 | 자금 보관 | 방어 |
|---|---|---|
| `OnchainNFT` | **없음** (payable 없음) | 상태 선행 + 콜백 마지막 |
| `Editions1155` | **있음** (판매대금 적립) | nonReentrant + 정확한 가격 강제 + 솔번시 불변식 + brake |

## F-01..F-08 매핑

| 항목 | 이 예제와의 관계 |
|---|---|
| **F-01** 예치 재진입 | `Editions1155.mint`는 payable이고 `_mint`가 수신자 콜백(`onERC1155Received`)을 뺀다. `nonReentrant` + effects(minted++) 선행으로 방어. **PoC 포함**: 악성 수신자가 콜백에서 재 mint를 시도 → low-level call이 실패함을 `test_reentrancy_mintBlocked`가 검증 (1차 mint는 성공). `withdraw`도 동일 가드. `OnchainNFT.mint`는 payable이 아니지만 effects를 먼저 확정하는 같은 순서를 유지한다. |
| **F-02** fee-on-transfer | 무관 — native(AETH)만 받는다. 토큰을 받지 않는다. |
| **F-03** 무코드 토큰 | 무관 (native 결제). |
| **F-04** 무한 view | 전체 에디션/보유자 순회 뷰가 없다. `editionOf(id)`·`uri(id)`·`traitsOf(id)`는 개별 조회만. 프론트는 이벤트 인덱스로 목록을 만든다. |
| **F-05** EIP-7702 | 무관. |
| **F-06** 단일 registrar 키 | 무관. |
| **F-07** 오픈 로그 ≠ 승인 | `EditionCreated`·`Minted`·`Withdrawn`은 누구나 읽을 수 있지만 승인이 아니다. 크리에이터 권한은 상태(`_editions[id].creator`)만이 결정한다. |
| **F-08** randomness | 무관 — 무작위성 없음. 특성은 크리에이터가 명시적으로 지정 (도박성 없음). |

## 이 예제 고유 위험과 완화

| 위험 | 완화 |
|---|---|
| **판매대금 유동성**: 크리에이터 인출 전 누군가 컨트랙트에 직접 송금 (실수/selfdestruct) | withdrawable은 `price×minted−withdrawn` 기반 — 우연 입금은 그 누구의 인출 가능액에도 포함되지 않는다. 회수 경로는 없다 (의도: 인센티브 없는 직접 송금은 원천 차단). |
| **브레이크 가디언 남용** | 가디언은 mint/create만 막을 수 있다. 출금을 막거나 자금을 가져갈 수 있는 경로가 아예 없다. state는 단조 증가만 가능(되돌림 불가) — 남용해도 사업은 멈출 뿐 잃지 않는다. |
| **과다 납부** | `msg.value != price` → 전액 revert. 환불 로직 부재는 의도 (재진입·오류 표면 제거). 지갑이 정확한 값을 보내는 것은 UI 책임. |
| ** ERC-721 safeMint 콜백 거부** | 악성 수신자 컨트랙트가 `onERC721Received`를 revert하면 mint 자체가 실패 — 크리에이터는 EOA나 정상 지갑으로 발행하면 된다 (크리에이터 전용 진입점이라 공격 표면이 아님). |
| **로열티 우회** | EIP-2981은 신고 표준이다 — 시장이 존중해야 한다. 온체인 강제가 아니라는 점을 README/판매 페이지에 명시할 것. 예제 3(마켓플레이스)은 로열티를 강제 계산한다. |
| **특성 pack 오버플로** | `TRAIT_MAX=8` 미만 검사가 생성 시 뒤따른다. 비트 폭을 늘리는 커스터마이징 시 상위 필드(mintedAt) 침범 주의. |

## 솔번시 불변식

`test_fuzz_solvency` (에디션 4개 × 구매자 4명 × 40 스텝 무작위 구매/인출):

```
Σₑ withdrawable(e) == address(this).balance
```

모든 스텝 후 성립. CI 1000 runs / 로컬 5000 runs. 이 불변식이 깨지면
크레딧 계산(price×minted)과 실제 잔액이 어긋난 것 — 인출 경쟁이나
재진입 누수를 의미한다.

## 퍼짱으로도 못 밝히는 것

- SVG/JSON 조립의 미적 품질 (유효성은 `_contains` 검증으로 커버)
- 브레이크 가디언 키 관리 — 운영 문서 (docs/safety-checklist.md) 참조
- 지갑·마켓의 data URI 렌더링 호환성 — 실제 지갑에서 화면 확인 필요
