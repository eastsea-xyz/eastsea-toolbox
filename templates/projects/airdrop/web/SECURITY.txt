# 예제 13 보안 노트 — 머클 에어드랍

범위: `contracts/src/airdrop/MerkleAirdrop.sol`. 감사 발견 클래스
F-01..F-08 회피 매핑과 이 예제 고유의 위험.

## F 클래스 매핑

| 클래스 | 해당 | 이 예제의 회피 |
|---|---|---|
| F-01 예치·인출 재진입 | 있음 | claim/sweep `nonReentrant` + CEI — claimed 비트·totalClaimed 갱신을 native 전송보다 먼저 |
| F-02 수수료-온-전송 | 해당 없음 | native만 취급 — FoT 영역 밖 |
| F-03 무코드 토큰 | 해당 없음 | 토큰 없음. `receive()`는 풀 충전을 위해 **허용** — 후원은 totalClaimed와 무관 |
| F-04 비례 뷰 | 부분 | 미청구 집계 뷰가 아예 없다 — `balance`는 상한(후원 섞임), 정확한 집계는 오프체인 인덱스(이벤트 스캔)의 몫 |
| F-05 EIP-7702 | 있음 | 7702 위임 EOA 청구도 동일 — 권한은 리프의 주소 성분과 `msg.sender` 일치 |
| F-06 단일 등록자 | 없음 | 루트·마감·distributor 전부 immutable. distributor는 sweep 수령만 — 루트·청구·마감에 키 없음 |
| F-07 오픈 로그 ≠ 승인 | 있음 | `Claimed` 이벤트 ≠ 청구 — 진실은 `claimed[user]` 매핑. 집계는 이벤트에서 해도 지급 판정은 매핑에서 |
| F-08 무작위성 | 없음 | 배정은 오프체인 명단(루트)이 이미 결정 — 체인은 무작위성을 만들지 않는다 |

## 불변식

테스트가 강제하는 성질 (`contracts/test/airdrop/MerkleAirdrop.t.sol`):

- **I1 자금 보존**: 임의의 명단 부분집합 청구 후 sweep까지 마치면
  `지급 합 + distributor 수령 == 초기 풀` — **정확한 등식**
  (`test_fuzz_conservation`).
- **I2 리프 결합**: 증명은 (주소, 금액) 쌍에만 유효 — 다른 금액,
  남의 증명 제출은 `InvalidProof` (`test_claim_rejectsWrongLeaf`).
- **I3 1회 청구**: claimed 비트가 두 번째 청구를 차단
  (`test_claim_reverts`).
- **I4 마감 경계**: `deadline` 시각까지 sweep 불가(`<=`), `deadline+1`부터
  claim 불가 — 경계값 테스트로 고정 (`test_sweep_revertsBeforeDeadline`).

## CEI 흐름

```
claim:
  1. claimed[msg.sender] = true            ← 비트 먼저
  2. totalClaimed += amount
  3. emit Claimed
  4. native 지급 전송                       ← 마지막

sweep:
  1. (스토리지 쓰기 없음 — 잔액 전액 전송)
  2. native 회수 전송
```

청구자의 지급 수신이 실패하면(수신 불가 코드) 트랜잭션 전체가
revert되고 claimed 비트도 롤백된다 — 나중에 다시 시도할 수 있다.
`InsufficientPool` 검사도 전송 전이므로 부분 실패가 없다.

## 고유 위험

| 위험 | 왜 남는가 | 완화 |
|---|---|---|
| 루트 오타 | 루트는 배포 시 고정, 재검증 불가 | 배포 전 증명 1건을 테스트넷에서 통과시킨다. 틀리면 마감 후 sweep → 전액 회수 → 재배포 (그래서 sweep이 존재한다) |
| 마감 알림 누락 | 마감은 체인 조건 — 체인이 알려주지 않는다 | 프론트·공지로 마감 D-day 안내. 청구는 이벤트 스캔으로 리마인드 가능 |
| 명단 유출 여부 | 루트는 익명이지만 증명 제출 시 주소·금액이 calldata에 공개 | 명단 비공개가 요구사항이면 클레임 프록시(별도 주소 경유)를 사용자가 선택하게 하라 — 컨트랙트 밖의 선택지 |
| 후원 receive 왜곡 | 누구나 풀에 native를 넣을 수 있어 balance > 명단 합 가능 | totalClaimed 스칼라는 영향 없음. sweep이 잔여 전액을 회수하므로 후원금도 마감 후 distributor에게 간다 — 의도된 동작 |
| deadline uint48 | 2106년 이후 시각은 표현 불가 | 30일~1년급 캠페인에 무의미. 초장기 무기한 풀은 이 모델이 아니다 |

## brake가 없는 이유

SimpleBrake는 **신규 진입**(자금·권리의 유입 경로)을 막는
제동이다. 이 컨트랙트의 진입은 배포 시점 — 루트·마감·수령인이
immutable로 박혔다 — 에 끝났다. 남은 함수는 claim(탈출: 자격의
현금화)과 sweep(탈출: 잔여 회수)뿐이다. 탈출을 막는 brake는
자금을 잠그는 것이므로, 이 설계에서 brake는 존재 자체가 잘못이다.
"어떤 컨트랙트는 brake가 필요 없다"도 하나의 안전 설계다.
