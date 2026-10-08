# 예제 8 — 단순 멀티시그

> ⚠️ **법적 고지 — 공개 배포 전 법률 검토 필수.** 멀티시그가 관리하는
> 자산·운영 범위에 따라 수탁·사업자 등록 요건이 생길 수 있다.
> 이 예제는 코드 견본이며 법률 자문이 아니다.

K-of-N 멀티시그. EOA·ERC-1271 계약 소유자의 **오프체인 서명** 또는
**소유자 직접 승인**을 모아, 임계치가 채워지면 누구나 실행한다 (relayer 패턴).

**2026-10-08 변경 이유:** 이전 `ecrecover` 전용 검증으로는 P-256
Secure Enclave 키를 사용하는 EastSea 계정이 공동 서명할 수 없었다.
이제 OpenZeppelin `SignatureChecker`로 EOA는 ECDSA, 코드가 있는 계정은
ERC-1271 `isValidSignature(bytes32,bytes)`로 검증한다. 오프체인 서명이
불가능한 지갑도 자기 계정에서 `approve`를 호출해 참여할 수 있다.

**복사해서 배포하려면:** `contracts/src/multisig/SimpleMultisig.sol`
와 저장소에 이미 고정된 OpenZeppelin 라이브러리가 필요하다.
[배포](#배포) 절차를 따른다. byte-for-byte clone은 변경하지 않는다.

## 왜 오프체인 서명인가

온체인 컨펌 모델(Gnosis Multisig 계열)은 트랜잭션마다 컨펌 비트맵을
체인에 기록한다. EastSea의 유료 상태에서 이는 컨펌 1건당 슬롯 1개씩
비용을 낸다는 뜻이다. 이 예제는 서명을 지갑끼리 주고받는 메시지로
두고, 기본 경로에서는 **실행 완료 해시 1슬롯**만 남긴다.
직접 승인은 추가로 소유자·digest별 `approvals[hash][owner]` 1슬롯과
이벤트를 기록한다. 두 경로를 한 실행에서 섞을 수 있다.

| | 온체인 컨펌 (Gnosis식) | 이 예제 (오프체인 서명) |
|---|---|---|
| 제출 트랜잭션 | 제안 + 컨펌 각각 | 실행 1회 |
| 체인 상태 | tx마다 컨펌 비트맵 | `executed[hash]` 1슬롯 |
| 컨펌 수집 비용 | 컨펌당 gas | 0 (서명은 무료) |
| 진행 상황 열람 | 체인 조회 | 오프체인 공유 필요 |

## 서명 검증 규칙

- `executeWithSigners`의 주소·서명 배열은 길이가 같아야 한다.
  주소는 **오름차순·고유·0이 아닌 소유자**이며 같은 인덱스의 서명과 짝이다.
  같은 소유자는 서명·직접 승인을 중복 제출해도 두 번 셀 수 없다.
- 비어 있지 않은 서명은 `SignatureChecker.isValidSignatureNow`로 검증한다.
  EOA는 low-s ECDSA, 계약은 ERC-1271 성공 magic value를 요구한다.
  false·revert·잘못된 길이·짧은 반환은 거부된다.
- 빈 서명 `0x`는 해당 digest에 대한 소유자의 직접 승인이 필요하다.
  `approve`는 `msg.sender`가 소유자여야 하며 계약 계정도 자기 계정의
  트랜잭션으로 호출한다.
- **비소유자·무효 서명이 섞이면 전체가 revert**한다. 임계치를 넘는
  나머지 항목도 모두 검증하며 잘못된 항목을 조용히 스킵하지 않는다.
- 해시에 **현재 chainId·컨트랙트 주소·nonce·deadline**과 to/value/data가
  묶인다. 같은 digest의 재실행·다른 체인·다른 multisig 재생이 차단된다.
  nonce는 순차 카운터가 아닌 작업 식별자이며 전체 digest가 한 번 실행된다.
- `block.timestamp > deadline`이면 승인·실행이 모두 거부된다.
  deadline을 생략한 편의 함수는 `type(uint256).max`를 사용한다.

## EIP-712와 EastSea 계정

```text
domain: name="EastSeaSimpleMultisig", version="2",
        chainId=현재 체인 ID, verifyingContract=멀티시그 주소
Transaction(address to,uint256 value,bytes data,uint256 nonce,uint256 deadline)
```

`getTransactionHash`는 이 EIP-712 인코딩의 keccak256 digest다.
구조체 해시에는 `keccak256(data)`가 들어간다. **기존 `personal_sign`
형식을 대체했으므로 이전에 수집한 서명은 다시 받아야 한다.** 기존 함수
호출 형태는 유지한다. EOA는 typed data를 서명하고 digest에
`personal_sign` 프리픽스를 다시 붙이지 않는다.

EastSea v2 계정은 앱 digest를 계정의 EIP-712
`Contents(bytes32 contents)` 구조체로 감싼다. 계정 도메인은
`EastSeaAccount`, version `2`, 현재 chainId와 계정 주소다. Secure Enclave는
그 인코딩의 SHA-256 digest를 P-256으로 서명한다. 서명 바이트는
`r || s || x || y` (128바이트)이며 멀티시그는 이를 계정의 ERC-1271에 위임한다.

## 함수표

| 함수 | 호출자 | 효과 |
|---|---|---|
| `execute(to, value, data, nonce, signatures)` | 누구나 | 기존 EOA 배열 API; EIP-712·최대 deadline |
| `executeWithSigners(to, value, data, nonce, signers, signatures)` | 누구나 | EOA·ERC-1271·직접 승인 혼합; 최대 deadline |
| `executeWithSigners(to, value, data, nonce, deadline, signers, signatures)` | 누구나 | 명시적인 deadline을 포함한 혼합 실행 |
| `approve(to, value, data, nonce[, deadline])` | 소유자 자신의 계정 | 직접 승인; 생략 시 최대 deadline |
| `getTransactionHash(to, value, data, nonce[, deadline])` | 뷰 | EIP-712 digest (상수 시간) |
| `isOwner(a)` / `threshold()` / `domainSeparator()` / `executed(h)` / `approvals(h, a)` | 뷰 | 설정·실행·승인 조회 |

실패한 대상 호출은 `ExecutionFailed`로 전체 revert — 조용한 실패가
없다 (실행자가 결과를 반드시 보게 된다). 실행 기록은 롤백되고 이전 직접
승인은 보존된다. 계약의 오프체인 서명 유효성은 실행 시점에 다시 검증한다.

## 배포

```bash
# 소유자 주소는 오름차순으로 정렬해 전달한다 (컨트랙트 강제)
forge create src/multisig/SimpleMultisig.sol:SimpleMultisig \
  --constructor-args "[0xAAA...,0xBBB...,0xCCC...,0xDDD...,0xEEE...]" 3 \
  --rpc-url $RPC --private-key $DEPLOYER
```

서명 수집 흐름:

1. 제안자가 to/value/data/nonce/deadline과 EIP-712 도메인을 공유한다.
2. 소유자는 typed data를 서명하거나, 같은 인자로 자기 계정에서 `approve`를
   호출한다. EastSea 계정은 ERC-1271 서명 흐름 또는 계정 `execute(Call[])`를 쓴다.
3. relayer는 소유자 주소와 서명을 같은 순서로 정렬한다. 직접 승인한 소유자의
   서명은 `0x`로 두고 `executeWithSigners`를 제출한다.

[onchain journey 목록](../../proof/onchain/README.md)의 multisig 시나리오는
직접 승인과 실행을 실제 계정 트랜잭션으로 수행하는 harness 입력이다.

상태 비용 요약 (측정 환경·전체 수치는 [GAS.md](GAS.md)):

| 항목 | units |
|---|---:|
| 배포 (소유자 5, threshold 3; 2026-10-08 측정) | 6,544u |
| execute (EOA 서명 3개, 송금; 승인 tx 제외) | **108u** |

## 커스터마이징 경고

- **소유자 목록은 정적이다.** 교체·추가 기능을 넣는 순간 그 기능
  자체가 최대 공격면이 된다(소유자 교체 tx를 가로채는 시나리오).
  필요하면 멀티시그가 새 multisig를 배포해 자산을 이전하라 —
  변경 로직이 없으면 변경 공격도 없다.
- 임계치 1은 다중 소유자 보호를 제공하지 않는다. 2-of-3 이상을 권장.
- 직접 승인에는 철회 API가 없다. 시간 제한이 필요하면 명시적인 deadline을
  쓴다. 계정의 오프체인 서명 철회도 별도의 직접 승인을 철회하지 않는다.
  실행·만료 후에도 승인 슬롯은 남는다.
- `execute`의 `to`에 임의 주소가 가능하다 — 프론트엔드에서
  서명 대상 파라미터를 명확히 표시하지 않으면 사용자가 무엇에
  서명했는지 모르게 된다 (블라인드 서명 문제, docs/safety-checklist.md).

## 파일

| 파일 | 내용 |
|---|---|
| `contracts/src/multisig/SimpleMultisig.sol` | 멀티시그 (기존 OpenZeppelin 사용) |
| `contracts/test/multisig/SimpleMultisig.t.sol` | 18 tests (검증·재생·fuzz·meter) |
| `contracts/test/multisig/MultisigFunding.t.sol` | native 입금 회귀 2 tests |
| `contracts/test/multisig/SimpleMultisig1271.t.sol` | P-256 ERC-1271·EOA·직접 승인·만료 회귀 28 tests |
| `contracts/test/utils/EastSeaAccountMock.sol` | EastSea v2 계정 인터페이스·실제 P-256 검증 mock |
| [SECURITY.md](SECURITY.md) | F-01..F-08 매핑·서명 검증 상세 |
| [GAS.md](GAS.md) | 상태 units 계량·온체인 컨펌 대비 |
