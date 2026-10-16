# 예제 7 보안 노트 — 토큰 타임락 · 선형 베스팅

범위: `contracts/src/lock/TokenTimeLock.sol`,
`contracts/src/lock/LinearVesting.sol`. 감사 발견 클래스 F-01..F-08에
대한 회피 매핑과 이 예제 고유의 위험.

## F 클래스 매핑

| 클래스 | 해당 | 이 예제의 회피 |
|---|---|---|
| F-01 예치·인출 재진입 | 있음 | 두 컨트랙트 모두 `nonReentrant` 전면 적용 + CEI. 스토리지 갱신(`locks.released`/`claimed`)을 push보다 먼저 |
| F-02 수수료-온-전송 | 있음 | 유입은 전부 `SafeToken.pullExact` — 정확한 금액 도착이 잠금의 근거. FoT 토큰을 쓰면 `pullExact`가 실패해 잘못된 잠금이 만들어지지 않는다 |
| F-03 무코드 토큰 | 있음 | 생성자에서 `token.code.length == 0` 거부 |
| F-04 비례 뷰 | 없음 | `vested`/`releasable`/`claimable` 전부 상수 시간 — 스캔 없음 |
| F-05 EIP-7702 위임 | 없음 | 컨트랙트는 EOA 위임을 가정하지 않는다. 수혜자가 7702로 위임한 경우에도 `release`/`claim`의 수령 주소 검증은 불변 |
| F-06 단일 등록자 | 없음 | `lockFor`는 permissionless — 프로토콜 통제 등록자가 아니다 |
| F-07 오픈 로그 ≠ 승인 | 있음 | `Locked` 이벤트는 누구나 발화 가능(예치 자체가 permissionless). 잠금의 근거는 이벤트가 아니라 컨트랙트 상태다 |
| F-08 무작위성 | 없음 | 사용하지 않음 — 스케줄은 결정론적 |

## 불변식

테스트가 강제하는 성질 (`contracts/test/lock/Locks.t.sol`):

- **I1 상한**: 임의 시점 release/claim의 누적 지급 ≤ 그 시점 vested
  (`test_fuzz_releaseNeverOverpays`, `test_fuzz_vestingNeverOverpays`).
- **I2 완주**: 종료 후 release/claim은 정확히 `amount` 전량 지급,
  컨트랙트 잔액 0 (동일 fuzz의 종결 단계).
- **I3 무이중**: 해제분이 없는 release는 `NothingToRelease`로 revert —
  0 지급 조용한 성공이 아니다 (감사 추적 가능).
- **I4 격리**: 배치형에서 수혜자 간 섞임 없음
  (`test_release_isolatedPerBeneficiary`).

## CEI 흐름

```
TokenTimeLock.release():
  1. l.released 갱신 (스토리지 먼저)
  2. SafeToken.push(token, msg.sender, due)   ← 마지막 외부 호출
  3. emit Released

LinearVesting.claim():
  1. claimed += paid (스토리지 먼저)
  2. SafeToken.push(token, beneficiary, paid) ← 마지막 외부 호출
  3. emit Claimed
```

`SafeToken.push`는 low-level call이라 악성 수신 컨트랙트의 revert를
삼키고 `TokenTransferFailed`로 표면화한다 — 재진입 시도가 있어도
가드가 차단하고 스토리지는 이미 정합 상태다.

## brake 매트릭스 (배치형만)

| 함수 | 분류 | 근거 |
|---|---|---|
| `lockFor` | **진입** | 신규 자금 유입 — 제동 대상 |
| `release` | **탈출** | 수혜자 인출 — 제동과 무관하게 항상 개방 |

자립형에 brake가 없는 이유: 진입(예치)이 생성자 1회뿐이라 제동이
막을 수 있는 것이 없다. 존재하지 않는 권한은 남용될 수 없다.

## 이 예제 고유의 위험

| 위험 | 완화 |
|---|---|
| 잘못된 파라미터의 영구화 (cliff/duration은 수정 불가) | `cliff > duration` 거부, 배포 스크립트에 파라미터 재확인 단계. 휴먼 에러가 컨트랙트 에러보다 큰 위험 |
| 잔고 증가 기부 (자립형) | `claimed` 상태 슬롯으로 지급누적이 기부에 오염되지 않는다 — 기부분은 잔여로 남는다 (`test_vesting_toleratesDonation`) |
| 수혜자 실수 주소 | `beneficiary == 0` 거부. 그 외 오타는 불가역 — 소액 테스트 잠금 먼저 |
| 클리프 경계 오프-바이-원 | 경계(`elapsed == cliff`)가 0임을 명시적 테스트 — 스케줄 계산을 "직관"으로 옮기지 말 것 |
| uint128 상한 | `amount > 2^128-1` 거부 (`AmountTooLarge`) — 18디짓 토큰 3.4e20개(3.4억 조) 상한. 초대형 그랜트는 배치형도 마찬가지 |
| 타임스탬프 조작 | 1초 블록 체인에서 검증자 타임스탬프 흔들림은 ±수초 — vesting 스케줄은 시간 단위 이상에서만 의미. 초 단위 정밀 비즈니스 로직에 쓰지 않는다 |

## 잔액 유도 회계 — 문서화된 실패 사례

자립형 초안은 유료 상태를 1슬롯 줄이려 `claimed = total - balance`로
지급누적을 잔액에서 유도했다. 제3자 기부로 `balance > total`이 되면
유도값이 0으로 포화되고, 이미 지급한 만큼을 **재지급**해 total 초과
지급이 가능해진다. `test_vesting_toleratesDonation`이 이 초과 지급을
실제로 재현(1_333e18 > 1_000e18)해 `claimed` 상태 도입을 강제했다.

교훈: **잔액은 진실이지만, 잔액이 세는 것과 회계가 세는 것이 다를 수
있다.** 외부에서 증가시킬 수 있는 잔액에서 제어 상태를 유도하지
말 것 — 이 원칙은 GAS.md의 슬롯 절약 논의와 충돌할 때 항상 이긴다.
