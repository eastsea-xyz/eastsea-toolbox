# 예제 4 보안 노트 — AMM (`AmmFactory` / `AmmPair` / `AmmRouter`)

## 자금 보관

**페어가 풀 자산을 보관한다** (ERC-20 두 종). 라우터는 무상태
이다 — 자산이 머무는 곳은 페어뿐이다.

## F-01..F-08 매핑

| 항목 | 이 예제와의 관계 |
|---|---|
| **F-01** 예치 재진입 | 모든 진입점(mint/burn/swap/skim/sync, 라우터 함수 전부)이 `nonReentrant`. 스왑은 out을 먼저 보내고 k 검증이 남아 있어 콜백 재진입의 이득이 없다. ERC-20에는 수신 콜백이 없어 표면 자체가 작다 (ERC-777형 토큰은 페어 생성 시 알 수 없으니 nonReentrant가 실질 방어선). |
| **F-02** fee-on-transfer | **주제.** 유입량은 전부 `balance - reserve`로 측정: mint의 LP, swap의 amountIn, k 검증 전부. FoT 토큰이 도착량만큼만 정산된다 — 좌초 없음. 라우터는 FoT 전용 `swapSupportingFeeOnTransfer`를 제공 (홉마다 실제 도착 관찰). |
| **F-03** 무코드 토큰 | 팩토리 `createPair`가 `token.code.length == 0` 거부 — 좀비 페어 방지. 라우터의 토큰 이동은 SafeToken(코드 검사 + strict bool). |
| **F-04** 무한 view | `getAmountsOut`은 호출자가 준 path[] 배열(≤4)만 순회 — 가스가 배열 길이에 바운드된다. 페어 목록 순회 뷰 없음 (이벤트 인덱스 사용). |
| **F-05** EIP-7702 | 페어가 EOA에 위임된 코드를 상대할 일 없음 — 토큰·수신자는 콜백 없는 ERC-20 경로만. |
| **F-06** 단일 registrar 키 | 무관. brake 가디언은 진입 차단만 가능 (아래). |
| **F-07** 오픈 로그 ≠ 승인 | `PairCreated`는 누구나 emit을 읽지만 페어 배포와 무관. LP 잔액이 유일한 권리 증명. |
| **F-08** randomness | 무관. |

## k 불변식 (이 예제의 핵심 약속)

```
스왑 후: balance0Adjusted × balance1Adjusted ≥ reserve0 × reserve1 × 1000²
  (유입쪽에서 3/1000 수수료 차감한 조정 밸런스)
```

- 라우터가 out을 계산하지만 **페어가 최종 강제**한다 — 악성 라우터,
  직접 호출, 어떤 경로로도 k를 깎을 수 없다.
- `test_fuzz_swapPreservesK` (256 runs CI / 5000 runs 로컬): 무작위
  유입량 스왑 후 매번 `r0' × r1' ≥ r0 × r1` 검증.
- `test_swap_revertExcessiveOutput`: 공정가+1% 요구 → revert.

## brake 설계 (팩토리 연동)

| brake | createPair | mint(예치) | swap | burn(회수) |
|---|---|---|---|---|
| 0 정상 | 허용 | 허용 | 허용 | 허용 |
| 1 신규 진입 정지 | **차단** | **차단** | **차단** | **허용** |

스왑을 진입으로 분류한 이유: 유동성 풀에서 자산을 꺼가는 방향(탈출)은
burn뿐이고, 스왑은 풀 비율을 흔드는 진입 행위다. brake 중에도 LP는
전액 회수할 수 있다 — 갇힌 자금이 없다.

## 이 예제 고유 위험과 완화

| 위험 | 완화 |
|---|---|
| **TWAP 단기 조작** | 적산치만 제공. 소비자가 최소 관측 주기를 강제해야 한다 (README 경고). |
| **sync()로 k 감소** | sync는 토큰이 잔액을 스스로 바꾼 뒤의 비상구다. 악용 시 k가 줄어들 수 있으나 자금은 감소 방향으로만 — 남발 금지 문서화. 필요 없으면 제거 권장. |
| **첫 예치 비율 공격** (미세 유동성으로 가격 왜곡) | `MINIMUM_LIQUIDITY` 1000을 dead 주소에 영구 잠금 + 첫 LP ≤ 1000 거부. |
| **라우터 경유 FoT 이중 과징** | 사용자→라우터→페어 경로에서 수수료 2회 (실측: 1000 송금 → 990 라우터 도착 → 980.1 페어 도착). 페어 자체는 도착량 기준이라 좌초 없음. 대규모 FoT 예치는 직접 페어 호출 권장. |
| **리저브 uint112 오버플로** | `_update`에서 초과 시 `ReserveOverflow` revert. 단일 페어에 5.19e33 토큰 이상은 불가. |
| **경로 스왑의 중간 홉** | 중간 홉 수령인은 다음 페어 주소 — 라우터에 토큰이 머무는 구간이 없다. `test_swap_twoHops`가 라우터 잔액 0을 검증. |
| **마감시한(deadline)** | 모든 라우터 함수가 `Expired` 강제. 멤풀 지연으로 의도치 않은 실행되는 것 방지. |

## 페어 배포 주소와 CREATE

이 예제는 일반 `create`를 쓴다 (주소 = 배포 논스). 라우터는 항상
`factory.getPair`로 조회하므로 결정론 주소가 필요하지 않다.
프리컴파일 가스를 아끼려 CREATE2를 추가하고 싶으면 솔트 충돌과
프론트런(주소 예측 선점입금)을 재검토하라.

## 퍼짱으로도 못 밝히는 것

- 악성 토큰이 `transfer`에서 bool만 돌려주고 안 옮기는 경우 —
  SafeToken.pushExact만 잡는다. 페어 내부 `_safeTransfer`는 strict
  bool까지만 검사 (잔액 관찰 안 함) — 잔액 불일치는 sync로 회복.
- 밸리데이터의 블록 타임스탬프 조작 (TWAP 오염) — 관측 주기로 완화.
- 가디언 키 운영 (docs/safety-checklist.md).
