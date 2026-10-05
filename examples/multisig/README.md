# 예제 8 — 단순 멀티시그

> ⚠️ **법적 고지 — 공개 배포 전 법률 검토 필수.** 멀티시그가 관리하는
> 자산·운영 범위에 따라 수탁·사업자 등록 요건이 생길 수 있다.
> 이 예제는 코드 견본이며 법률 자문이 아니다.

K-of-N 멀티시그. 소유자 서명을 **오프체인에서 수집**하고, 임계치가
채워진 서명 묶음을 누구나 체인에 제출해 실행한다 (relayer 패턴).

**복사해서 배포하려면:** `contracts/src/multisig/SimpleMultisig.sol`
하나가 전부다 (외부 의존성 없음). [배포](#배포) 절차를 따른다.

## 왜 오프체인 서명인가

온체인 컨펌 모델(Gnosis Multisig 계열)은 트랜잭션마다 컨펌 비트맵을
체인에 기록한다. EastSea의 유료 상태에서 이는 컨펌 1건당 슬롯 1개씩
비용을 낸다는 뜻이다. 이 예제는 서명을 지갑끼리 주고받는 메시지로
두고, 체인에는 **실행 완료 해시 1슬롯**만 남긴다.

| | 온체인 컨펌 (Gnosis식) | 이 예제 (오프체인 서명) |
|---|---|---|
| 제출 트랜잭션 | 제안 + 컨펌 각각 | 실행 1회 |
| 체인 상태 | tx마다 컨펌 비트맵 | `executed[hash]` 1슬롯 |
| 컨펌 수집 비용 | 컨펌당 gas | 0 (서명은 무료) |
| 진행 상황 열람 | 체인 조회 | 오프체인 공유 필요 |

## 서명 검증 규칙

- 서명 배열은 **오름차순·고유**해야 한다 — `recovered > last` 검사가
  중복 서명(같은 주소 2회), 무효 서명(`ecrecover` → 0주소), 미정렬을
  한 번에 거부한다.
- **비소유자 서명이 섞이면 전체가 revert**한다. 스킵하지 않는다 —
  "정확히 임계치의 유효 서명"이 아니면 실행되지 않아야 실수가
  조용히 넘어가지 않는다.
- 해시에 **도메인 분리**(chainId + 컨트랙트 주소)와 **nonce**가
  들어간다 — 다른 체인, 다른 multisig 인스턴스, 같은 tx 재실행이
  모두 차단된다 (`test_execute_crossInstanceRejected`,
  `test_execute_replayRejected`).
- 서명 프리픽스는 `personal_sign` 형식 — 지갑 UI에서 일반 메시지
  서명으로 보여 사용자가 서명 내용을 읽을 수 있다.

## 함수표

| 함수 | 호출자 | 효과 |
|---|---|---|
| `execute(to, value, data, nonce, signatures)` | 누구나 (relayer) | 서명 검증 후 임의 호출 실행 |
| `getTransactionHash(to, value, data, nonce)` | 뷰 | 서명 대상 해시 (상수 시간) |
| `isOwner(a)` / `threshold()` / `domainSeparator()` / `executed(h)` | 뷰 | 설정 조회 |

실패한 대상 호출은 `ExecutionFailed`로 전체 revert — 조용한 실패가
없다 (실행자가 결과를 반드시 보게 된다).

## 배포

```bash
# 소유자 주소는 오름차순으로 정렬해 전달한다 (컨트랙트 강제)
forge create src/multisig/SimpleMultisig.sol:SimpleMultisig \
  --constructor-args "[0xAAA...,0xBBB...,0xCCC...,0xDDD...,0xEEE...]" 3 \
  --rpc-url $RPC --private-key $DEPLOYER
```

서명 수집 흐름:

1. 제안자가 `cast call $MS "getTransactionHash(address,uint256,bytes,uint256)" ...`로 해시 계산
2. 각 소유자가 지갑으로 해시에 `personal_sign` 서명
3. relayer가 서명 묶음을 오름차순 정렬해 `execute` 제출

상태 비용 요약 (측정 환경·전체 수치는 [GAS.md](GAS.md)):

| 항목 | units |
|---|---:|
| 배포 (소유자 5, threshold 3) | 2,802u |
| execute (서명 3개, 송금) | **108u** |

## 커스터마이징 경고

- **소유자 목록은 정적이다.** 교체·추가 기능을 넣는 순간 그 기능
  자체가 최대 공격면이 된다(소유자 교체 tx를 가로채는 시나리오).
  필요하면 멀티시그가 새 multisig를 배포해 자산을 이전하라 —
  변경 로직이 없으면 변경 공격도 없다.
- 임계치를 1로 설정하는 것은 일반 EOA보다 나쁘다 — 서명 재사용
  공격에 노출된 단일 키 지갑이다. 2-of-3 이상을 권장.
- `execute`의 `to`에 임의 주소가 가능하다 — 프론트엔드에서
  서명 대상 파라미터를 명확히 표시하지 않으면 사용자가 무엇에
  서명했는지 모르게 된다 (블라인드 서명 문제, docs/safety-checklist.md).

## 파일

| 파일 | 내용 |
|---|---|
| `contracts/src/multisig/SimpleMultisig.sol` | 멀티시그 (의존성 0) |
| `contracts/test/multisig/SimpleMultisig.t.sol` | 18 tests (검증·재생·fuzz·meter) |
| [SECURITY.md](SECURITY.md) | F-01..F-08 매핑·서명 검증 상세 |
| [GAS.md](GAS.md) | 상태 units 계량·온체인 컨펌 대비 |
