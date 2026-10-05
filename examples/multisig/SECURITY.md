# 예제 8 보안 노트 — 단순 멀티시그

범위: `contracts/src/multisig/SimpleMultisig.sol`. 감사 발견 클래스
F-01..F-08 회피 매핑과 이 예제 고유의 위험.

## F 클래스 매핑

| 클래스 | 해당 | 이 예제의 회피 |
|---|---|---|
| F-01 예치·인출 재진입 | 있음 | `executed[h] = true`를 외부 call보다 **먼저** 기록(CEI). execute가 재귀적으로 자신을 호출해도 두 번째는 `AlreadyExecuted`로 죽는다 — ReentrancyGuard 없이 구조적 방어 |
| F-02 수수료-온-전송 | 간접 | 멀티시그는 토큰 회계를 갖지 않는다. FoT 토큰 이체는 `data`의 임의 호출로 실행되며 결과는 타깃 토큰 규칙 그대로 — 멀티시그가 좌초분을 만들지 않는다 |
| F-03 무코드 토큰 | 해당 없음 | `to.call`은 무코드 주소에도 동작 (native 송금 = 정상) |
| F-04 비례 뷰 | 없음 | `getTransactionHash` 상수 시간 |
| F-05 EIP-7702 | 있음 | 7702로 위임된 EOA 대상 call도 일반 call과 동일. 소유자 서명 검증은 `ecrecover` 기반이라 위임 영향 없음 |
| F-06 단일 등록자 | 없음 | 소유자 집단 자체가 권한 — 프로토콜 등록자 없음 |
| F-07 오픈 로그 ≠ 승인 | 있음 | `Executed` 이벤트는 relayer 누구나 발화 가능. 실행의 근거는 이벤트가 아니라 서명 검증 통과다 |
| F-08 무작위성 | 없음 | 사용하지 않음 |

## 재생 방지 — 3겹

서명 대상 해시에 포함되는 도메인:

```
hash = keccak256("\x19Ethereum Signed Message:\n32" ++
         keccak256(abi.encode(domainSeparator, to, value, keccak256(data), nonce)))
domainSeparator = keccak256(chainId, address(this))   // 배포 시 immutable 고정
```

| 재생 시나리오 | 차단 수단 | 테스트 |
|---|---|---|
| 같은 tx 재실행 | `executed[hash]` 1회 기록 | `test_execute_replayRejected` |
| 다른 multisig 인스턴스에서 같은 서명 | domainSeparator에 자기 주소 | `test_execute_crossInstanceRejected` |
| 다른 체인에서 같은 서명 | domainSeparator에 chainId | 도메인 구조로 보장 |
| 내용 위조 (to/value/data 교체) | 해시에 전부 포함 | `test_execute_wrongPayloadRejected` |
| 재발의 (합법적 재시도) | nonce 교체 = 새 해시 | `test_execute_newNonceIsNewTransaction` |

## 서명 검증 상세

```
for each sig: recovered = ecrecover(h, v, r, s)
  reject if recovered <= last      // 0주소(무효)·중복·미정렬 동시 차단
  reject if !isOwner[recovered]    // 비소유자 — 스킵이 아니라 전체 거부
```

설계 의도:

- **엄격 오름차순**은 중복 서명 카운팅(같은 서명 N번 = N 컨펌)을
  정렬 검사로 자동 차단한다. 비트맵 없이 3줄로 끝난다.
- **비소유자 서명 스킵 없음**: 관대한 스킵은 "relayer가 서명 묶음을
  잘못 모았는데 우연히 통과"하는 상태를 만든다. 죽는 게 낫다.
- 서명 길이는 65바이트 고정 — `calldataload` 직접 절편으로 메모리
  복사 없이 검증한다.

## 이 예제 고유의 위험

| 위험 | 완화 |
|---|---|
| 블라인드 서명 — 소유자가 무엇에 서명했는지 모름 | `personal_sign` 프리픽스로 지갑이 서명 내용을 표시. 프론트엔드는 to/value/data를 디코딩해 사람이 읽게 표시해야 한다 |
| 서명 수집 UX 실패 (소유자가 오래된 tx에 서명) | nonce 표시 — 프론트엔드가 "이 tx는 아직 실행 전" 상태를 함께 보여야 |
| relayer 프론트런닝 — 제출 서명을 가로채 자신이 제출 | 무해: relayer는 수수료만 내고 실행 결과는 동일 (권한은 서명에 있음) |
| 마지막 소유자 서명 후 relayer 지연 | 서명은 만료가 없다 — 긴급한 tx는 프론트엔드에 "서명 시각" 경고 표시 |
| 임계치 1 설정 | 문서로 금지 권장 (README) — 재사용에 노출된 단일 키 |
| `to.call` 실패의 가스 소모 | `ExecutionFailed(ret)`로 revert 이유를 반환 데이터에 포함 — 디버깅 가능 |
| owner 키 유출 | 정적 소유자라 즉시 교체 불가 — 신규 multisig 배포·자산 이관 절차를 운영 문서로 준비 |

## CEI 증명 (F-01)

`execute`는 가드 없이 안전하다 — 유일한 상태 변경(`executed[h]`)이
모든 외부 상호작용(서명 검증은 뷰, 대상 call)보다 먼저다. 대상
컨트랙트가 악의적으로 `execute`를 재호출해도 첫 줄에서
`AlreadyExecuted`로 죽는다. 가드를 추가해도 같은 결과일 뿐 —
구조적 방어가 우선이고 가드는 보험이다.
