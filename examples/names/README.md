# 예제 15 — Reef Drop · 이름 자격 드롭 (이름 서비스 연동)

> [!WARNING]
> **공개 배포 전 법률 검토 필수.** 무상 지급형 캠페인은 선정 기준에
> 따라 마케팅·세무·증권 규제 대상이 될 수 있다. 수익·가격 약속,
> 코인 리워드 추천 구조는 포함하지 않는다 (docs/legal-notes.md).

system 컨트랙트 `EastSeaNames`(.aeth)를 소비하는 앱이 **자격 증명을
시스템에 통째로 위임**하는 방법을 보여준다. 배포자는 아무 명단도
온체인에 올리지 않는다. primary name을 가진 계정만 `claim()` 한 번으로
고정액을 받는다.

```
이름 보유 계정:  claim() ──▶ reverseOf(msg.sender) != "" ──▶ DROP 지급
이름 없는 계정:  claim() ──▶ reverseOf == "" ──▶ NoPrimaryName
마감 후:         sweep() ──▶ 잔여 전액 → distributor (누구나 호출)
```

## 왜 이 구조인가 — 자격 증명의 3가지 공급원

| | 화이트리스트 매핑 | 머클 루트 (예제 13) | primary name (이 예제) |
|---|---|---|---|
| 명단 상태 | **배포자가 전원 슬롯 선불** | 없음 (루트 32B) | 없음 — 시스템이 이미 보유 |
| 자격 발행 주체 | 배포자의 서명 관리 | 배포자가 트리를 만드는 순간 | **참가자가 시스템에 스스로 등록** |
| 청구 비용 | 저렴 (조회 1회) | 증명 캘리데이터 + 검증 | 시스템 뷰 호출 1회 |
| 명단 변경 | 키 필요 (위험) | 배포 시 확정 | **마감 전까지 계속 "열림**" |
| 가명 계정 대응 | 배포자가 걸러냄 | 배포자가 걸러냄 | 걸러내지 않는다 (아래 참고) |

핵심 차이: 머클의 자격은 배포자가 **발행**하지만, 이름의 자격은
참가자가 이미 시스템에 **보유**하고 있다. 앱은 그 사실을 확인만
한다 — 중복 저장 0슬롯.

## 설계 결정

### 1. 자격 판정은 `reverseOf` 한 줄

`names.reverseOf(msg.sender) != ""`이 자격의 전부다. 시스템의
`reverseOf`는 **정직성 조건**까지 검사한다 — forward 레코드가 살아
있고 그 주소를 되돌아가는 경우만 이름을 돌려준다. 따라서:

- 이름 **만료**(365일 + 30일 유예 후) → `""` → 자격 소멸
- 이름의 `addr`을 **다른 주소로 이동** → 시스템이 reverse를 능동
  삭제 → `""` → 자격 소멸
- **이전받은** 이름 → 새 소유자가 `addr`+`reverse`를 다시 세우면
  자격 획득 ("지금 그 이름을 대표하는 계정"이 곧 자격자)

앱은 이 세 케이스를 자체 코드로 처리하지 않는다. 테스트
`test_claim_nameExpiryRevokesEligibility`,
`test_claim_addrMovedKillsReverse`, `test_claim_transferredName`가
각각 증명한다.

### 2. 문자열은 상태가 아니라 로그에

자격 판정에 필요한 건 "이름이 있는가"뿐이다. 앱은 이름 문자열도
node(bytes32)도 저장하지 않는다 — 영구 상태는 청구자당 **비트 1개**
(`claimed`)와 스칼라 1개뿐. 이름은 `Claimed(user, name)` 이벤트의
페이로드로만 남는다: 로그는 스캔 가능하고 상태 비용(1B=1u)이
붙지 않는다. "문자열을 스토리지에 두는 순간 1자당 1u씩 영구
과금된다"는 유료 상태 체인의 기본을 회피한 것이다.

### 3. 조회 시점 판정 (캐시 금지)

자격은 `claim` 트랜잭션이 실행되는 순간의 시스템 상태로 판정한다.
등록 시점에 해석해 두면(캐시) 이름이 만료·이동한 뒤에도 자격이
남는다 — 스푸핑 표면이다. 매번 `reverseOf`를 부르는 external call
비용(~2,600 gas)이 정확성의 값이다.

### 4. 이름은 신원 증명이지 Sybil 방어가 아니다

primary name은 계정당 1개지만 **계정을 여러 개** 만들면 각각
이름을 가질 수 있다 (이름 1개 = 소각 0.1 AETH). 이 게이트의 의미는
"익명 계정이 아니라 시스템에 등록된 계정"까지다. 1인 1회가 규제·사업
요건이면 이 패턴만으로는 부족하다 — 자격 기준에 추가 증명(최소
등록 기령, 예치 등)이 필요하고 그 시점에 설계를 다시 봐야 한다.

## 라이프사이클

| 단계 | 호출 | 누가 | 상태 |
|---|---|---|---|
| 배포 | `new NameGatedDrop(names, distributor, drop, 30 days)` | 배포자 | 2,321u |
| 풀 충전 | `receive()` (일반 송금) | 누구나 | 0u |
| 청구 | `claim()` | 이름 보유 계정 | 첫 207u / 이후 107u |
| 회수 | `sweep()` (마감 후) | 누구나 | 5u |

1회 청구(`claimed` 비트), 마감은 immutable, 잔여는 반드시
distributor에게 — 잘못된 배포로 자금이 갇히는 경로가 없다.

## 이름 등록은 어떻게 하나 (시스템 절차)

앱 밖의 선결 조건 — 참가자는 미리 primary name을 보유해야 한다.
시스템(`EastSeaNames`)의 등록은 commit-reveal이다:

```bash
# 1) 커밋 — keccak256(name, owner, salt, relayer) 와 0.01 AETH 보증금(소각)
cast send $NAMES 'commit(bytes32)' $(cast keccak $(cast abi-encode \
  'f(string,address,bytes32,address)' alice 0xALICE 0xSALT 0x0000000000000000000000000000000000000000)) \
  --value 0.01ether

# 2) 60초 대기 후 등록 — 잔여 0.09 AETH 소각 (5자 이상 요율 0.1)
cast send $NAMES 'register(string,address,bytes32,address)' \
  alice 0xALICE 0xSALT 0x0000000000000000000000000000000000000000 \
  --value 0.09ether

# 3) 주소·역방향 연결 — 여기까지 끝내야 reverseOf(alice) == "alice"
cast send $NAMES 'setAddr(string,address)' alice 0xALICE
cast send $NAMES 'setReverse(string)' alice

# 청구
cast send $DROP 'claim()'
```

등록료는 길이별 고정(3자 2 / 4자 0.5 / 5자+ 0.1 AETH)이고 **전액
소각**된다 — 앱과 배포자는 아무것도 받지 않는다.

## 커스터마이징 경고

- **자격 기준 바꾸기**: "이름이 있다" 대신 "특정 이름의 소유자다"
  (`ownerOf(nodeFor(name)) == msg.sender`)로 좁히는 것은 안전한
  변경이다. 반대로 이름 길이·문자열 내용으로 등급을 나누면
  유효성 규칙(`isValidName`)과 얽히므로 테스트를 다시 설계해야 한다.
- **드롭 금액**: immutable 고정액이다. 등급제 금액은 배포자 키를
  요구하는 구조로 변질되기 쉽다 (F-06).
- **마감 연장 금지**: deadline 연장 키는 "끝났다고 믿은 사람의
  잔여를 다시 열어주는" 권한이다. 새 드롭을 새로 배포하라.

## 함께 보기

- `contracts/src/names/NameGatedDrop.sol` — 구현 (설계 근거 주석)
- `contracts/test/names/NameGatedDrop.t.sol` — 실제 시스템 컨트랙트를
  배포하는 통합 테스트 (mock 없음)
- `examples/names/SECURITY.md` · `examples/names/GAS.md`
- 예제 13(`examples/airdrop/`) — 발행형 자격(머클)과의 비교
