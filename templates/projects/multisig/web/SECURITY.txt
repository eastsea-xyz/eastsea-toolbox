# 예제 8 보안 노트 — 단순 멀티시그

범위: `contracts/src/multisig/SimpleMultisig.sol`. 감사 발견 클래스
F-01..F-08 회피 매핑과 이 예제 고유의 위험.

## F 클래스 매핑

| 클래스 | 해당 | 이 예제의 회피 |
|---|---|---|
| F-01 예치·인출 재진입 | 있음 | `executed[h] = true`를 ERC-1271 staticcall·대상 call보다 먼저 기록(CEI). 같은 digest의 재진입은 `AlreadyExecuted`로 거부. 실패 시 기록도 롤백 |
| F-02 수수료-온-전송 | 간접 | 멀티시그는 토큰 회계를 갖지 않는다. FoT 토큰 이체는 `data`의 임의 호출로 실행되며 결과는 타깃 토큰 규칙 그대로 — 멀티시그가 좌초분을 만들지 않는다 |
| F-03 무코드 토큰 | 해당 없음 | `to.call`은 무코드 주소에도 동작 (native 송금 = 정상) |
| F-04 비례 뷰 | 없음 | `getTransactionHash` 상수 시간 |
| F-05 EIP-7702 | 있음 | 대상 call은 일반 call. 코드가 있는 소유자는 EOA 복구만으로 통과하지 않고 ERC-1271 검증을 받는다 |
| F-06 단일 등록자 | 없음 | 소유자 집단 자체가 권한 — 프로토콜 등록자 없음 |
| F-07 오픈 로그 ≠ 승인 | 있음 | `Executed`는 누구나 relay 가능하지만 소유자 임계치가 필요. `Approved`는 소유자 호출만 가능하며 실제 근거는 `approvals[h][owner]` |
| F-08 무작위성 | 없음 | 사용하지 않음 |

## EIP-712와 재생 방지

서명 대상 해시에 포함되는 도메인:

```
domainSeparator = keccak256(abi.encode(
  keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
  keccak256("EastSeaSimpleMultisig"), keccak256("2"), currentChainId, address(this)))
structHash = keccak256(abi.encode(
  keccak256("Transaction(address to,uint256 value,bytes data,uint256 nonce,uint256 deadline)"),
  to, value, keccak256(data), nonce, deadline))
hash = keccak256(0x1901 ++ domainSeparator ++ structHash)
```

| 재생 시나리오 | 차단 수단 | 테스트 |
|---|---|---|
| 같은 tx 재실행 | `executed[hash]` 1회 기록 | `test_execute_replayRejected` |
| 다른 multisig 인스턴스에서 같은 서명 | domainSeparator에 자기 주소 | `test_execute_crossInstanceRejected` |
| 체인 ID 변경 후 같은 서명 | 현재 chainId로 도메인 재계산 | `test_typedDataBindsCurrentChainAndNonce` |
| 내용 위조 (to/value/data 교체) | 해시에 전부 포함 | `test_execute_wrongPayloadRejected` |
| 재발의 (합법적 재시도) | nonce 교체 = 새 해시 | `test_execute_newNonceIsNewTransaction` |
| deadline 교체·생략 | 서명·직접 승인 digest에 포함 | `test_deadlineCannotBeChangedByRelayer` |
| 만료 후 제출 | `block.timestamp > deadline` 거부 | `test_expiredTransactionRejected`, `test_directApprovalRejectsExpired` |

nonce는 순차 카운터가 아닌 작업 식별자다. 전체 digest가 한 번 실행되며
같은 nonce라도 다른 내용의 승인은 별개다. 최대 deadline 편의 함수는
만료가 없으므로 시간 제한이 필요한 작업은 명시적인 deadline을 쓴다.

## 서명 검증 상세

```
reject if signers.length != signatures.length or count < threshold
for each (signer, signature):
  reject if signer <= last or !isOwner[signer]
  if signature is empty: require approvals[h][signer]
  else: require SignatureChecker.isValidSignatureNow(signer, h, signature)
```

설계 의도:

- **엄격 오름차순**은 서명·직접 승인에서 같은 소유자의 중복 카운팅을
  자동 차단한다. 주소와 서명을 같은 인덱스로 짝짓는다.
- **비소유자 서명 스킵 없음**: 관대한 스킵은 "relayer가 서명 묶음을
  잘못 모았는데 우연히 통과"하는 상태를 만든다. 죽는 게 낫다.
- 코드 없는 주소는 low-s ECDSA, 코드가 있는 주소는 ERC-1271 staticcall의
  성공과 ABI 형식 magic value를 요구한다. false·revert·짧은 반환은 거부한다.
- 기존 `execute(...,bytes[])`도 `ECDSA.tryRecover` 후 SignatureChecker로
  재검증한다. high-s와 코드가 있는 소유자의 raw ECDSA 우회를 거부한다
  (`test_legacyEOARejectsHighS`, `test_legacyRecoveredOwnerWithCodeUses1271`).
- 직접 승인은 소유자 자신의 계정만 호출할 수 있으며 같은 EIP-712 digest에
  묶인다. 빈 서명은 이 승인 상태가 없으면 거부된다.

EastSeaAccount v2는 앱 digest를 계정 EIP-712 `Contents(bytes32 contents)`
도메인으로 감싸 SHA-256·P-256 검증을 한다. mock은 이 인터페이스와
128바이트 `r||s||x||y` 형식, 실제 P-256 검증을 재현한다.
계약 서명의 유효성은 실행 시점에 검사한다
(`test_erc1271RevocationCheckedAtExecution`). 직접 승인은 오프체인 서명과
별도의 권한이므로 계정의 서명 철회에 따라 자동으로 철회되지 않는다.

## 이 예제 고유의 위험

| 위험 | 완화 |
|---|---|
| 블라인드 서명 — 소유자가 무엇에 서명했는지 모름 | EIP-712만으로 임의 calldata의 의미가 설명되지는 않는다. 프론트엔드는 to/value/data/nonce/deadline을 디코딩·표시해야 한다 |
| 서명 수집 UX 실패 (소유자가 오래된 tx에 서명) | nonce 표시 — 프론트엔드가 "이 tx는 아직 실행 전" 상태를 함께 보여야 |
| relayer 프론트런닝 — 제출 서명을 가로채 자신이 제출 | 무해: relayer는 수수료만 내고 실행 결과는 동일 (권한은 서명에 있음) |
| 마지막 소유자 승인 후 relayer 지연 | 명시적인 deadline 사용. 최대 deadline 편의 함수에는 만료가 없다 |
| 잘못된 직접 승인 | 철회 API 없음. 실행·만료까지 권한이 남고 승인 슬롯은 이후에도 보관된다 |
| 계약 signer의 gas 소모·revert | 수집 시 계정 정책 확인과 실행 gas 추정. 무효 서명은 실행 기록까지 롤백한다 |
| 임계치 1 설정 | 다중 소유자 보호 없음. 2-of-3 이상 권장 |
| `to.call` 실패의 가스 소모 | `ExecutionFailed(ret)`로 revert 이유를 반환 데이터에 포함 — 디버깅 가능 |
| owner 키 유출 | 정적 소유자라 즉시 교체 불가 — 신규 multisig 배포·자산 이관 절차를 운영 문서로 준비 |

## CEI 증명 (F-01)

실행 digest를 먼저 `executed[h]`에 기록한 뒤 ERC-1271 staticcall과 대상
호출을 한다. 같은 digest로 재진입하면 `AlreadyExecuted`로 거부된다.
다른 digest의 실행은 별개의 소유자 임계치가 필요하다. ERC-1271 검증은
staticcall이므로 상태를 변경하지 못한다.

무효 서명과 대상 실패는 전체 실행을 revert해 `executed[h]`도 되돌린다.
이전에 생성한 직접 승인은 보존된다 (`test_wrongP256KeyRejected`,
`test_targetFailureRollsBackExecution`).
