# 예제 11 보안 노트 — 단순 DAO

범위: `contracts/src/dao/SimpleDAO.sol`. 감사 발견 클래스 F-01..F-08
회피 매핑과 이 예제 고유의 위험.

## F 클래스 매핑

| 클래스 | 해당 | 이 예제의 회피 |
|---|---|---|
| F-01 예치·인출 재진입 | 있음 | 두 실행 경로에 nonReentrant + `executed = true`를 외부 호출보다 먼저(CEI) — 대상 호출 실패는 실행 플래그도 롤백 |
| F-02 수수료-온-전송 | 있음 | 투표권 토큰이 FoT면 무게 산정이 왜곡된다. 배포 시 code 존재만 검증 가능 — **FoT 금지는 배포 요구사항** (README) |
| F-03 무코드 토큰 | 있음 | 생성자에서 `votesToken.code.length > 0` 강제 — 무코드 주소 배포 원천 차단 |
| F-04 비례 뷰 | 없음 | `state`/`getVoteHash`/`approvedVotes` 상수 시간. 실행 시 나열된 유권자만 검증·합산하며 전체 승인 상태를 순회하지 않는다 |
| F-05 EIP-7702 | 있음 | OpenZeppelin `SignatureChecker`: code 없는 EOA만 low-s ecrecover, code 있는 계정(7702 포함)은 ERC-1271 정책. 기존 EOA ABI에도 같은 정책을 강제한다 |
| F-06 단일 등록자 | 없음 | propose는 누구나. quorum·기간·토큰 전부 immutable |
| F-07 오픈 로그 ≠ 승인 | 있음 | `Proposed` 이벤트 ≠ 유효 제안 — 진실은 `proposals` 매핑. 제안 등록과 승인(쿼럼)의 구분이 이 설계의 전부 |
| F-08 무작위성 | 없음 | 사용하지 않음 |

## 불변식

테스트가 강제하는 성질 (`contracts/test/dao/SimpleDAO.t.sol`,
`contracts/test/dao/SimpleDAO1271.t.sol`):

- **I1 쿼럼 판정 대응**: 유효한 서명·직접 승인 주소의 현재 잔액 합 ≥ quorum ⟺ execute 성공 —
  임의 유권자 부분집합에 대해 정확히 대응
  (`test_fuzz_quorumIffWeight`).
- **I2 일회 실행**: executed 플래그 후 재실행·재진입 전부 거부
  (`test_execute_reverts`, CEI 구조).
- **I3 해시 커밋**: target/value/data가 제안 해시와 다르면 실행
  불가 (`HashMismatch`) — 제안 문서 위조가 실행으로 이어질 수 없다.
- **I4 타임라인**: executableFrom = votingEnds + delay,
  expires = executableFrom + grace — 제안마다 생성 시 확정되고
  불변 (`test_propose_opensCommitment`).
- **I5 주소별 한 표**: 명시적 유권자 배열은 0 아닌 주소의 엄격
  오름차순이고 서명 배열과 길이가 같다. 직접 승인과 서명을 섞어도
  중복·미정렬 주소는 거부하며, 유권자 잔액을 한 번만 합산한다.
- **I6 직접 투표권**: `vote`는 msg.sender의 표만 기록한다. 제안이
  존재하고 `timestamp < votingEnds`인 동안 한 번 승인할 수 있다.
  미승인 주소의 빈 서명은 실행에서 거부된다.

## 서명·재생 방지

| 경계 | 차단 수단 |
|---|---|
| 같은 제안 내 이중 투표 | signer 주소 엄격 오름차순 — 직접 승인·서명 혼합도 주소당 한 번 |
| 제안 간 재생 | `Vote`에 proposalId(nonce) 포함 — 같은 실행 내용이어도 새 제안은 새 해시 |
| 체인 간·인스턴스 간 재생 | EIP-712 `EastSeaSimpleDAO`/`2` 도메인에 현재 `block.chainid` + `address(this)` 포함 |
| 실행 내용·기한 변경 | `executionHash`, `votingEnds`, `expires`도 typed data에 포함 |
| 이미 실행된 제안 재생 | 공통 실행 검증의 `executed` 플래그 + nonReentrant |
| 만료 제안 | `timestamp > expires`이면 서명·직접 승인 모두 실행 불가 |
| 직접 승인 재생 | `approvedVotes[proposalId][msg.sender]`에 저장 — 중복 vote 거부, 다른 제안에 적용되지 않는다 |

EOA의 오프체인 서명은 low-s·65바이트 secp256k1로 검증한다. 계정
서명은 임의 길이이며 `isValidSignature`를 staticcall한 결과가 ABI로
인코딩된 ERC-1271 magic value여야 한다. false·revert·짧은 반환은 모두
거부한다. EastSea v2 fixture는 128바이트 P-256 서명을 실제 곡선
검증으로 확인하고, 계정의 `Contents(bytes32 contents)` 도메인도 적용한다.
계정 서명의 유효성은 실행 시점에 다시 확인하므로 키·검증 정책 변경으로
과거 승인이 무효가 될 수 있다.

EOA 서명과 직접 vote 자체의 철회 API는 없다. 무게가 실행 시점
잔액이므로 토큰 매도가 사실상의 표 철회다. 직접 승인은 기록된 주소를
명시적으로 나열해야 합산되며, 승인 당시 잔액을 저장하지 않는다.

`vote`는 votingEnds에 정확히 닫힌다. 오프체인 서명은 생성 시각을
증명하지 않으므로 votingEnds 이후에도 생성할 수 있고, 실행 시
expires까지 검증한다. 이는 기존 실행 시 서명 수집 모델의 성질이다.
투표 마감 시점의 서명·잔액까지 고정하려면 별도의 등록 또는 스냅샷
설계가 필요하다.

## brake 매트릭스

| 함수 | 분류 | 근거 |
|---|---|---|
| `propose` | **진입** | 신규 상태 생성 — 제동 대상 (스팸·사고 대응) |
| `vote` | **진입** | 신규 직접 승인 상태 생성 — 제동 대상 |
| `execute` / `executeWithSigners` | **탈출** | 기존 서명·직접 승인으로 제안 집행 — brake로 막으면 국고가 잠긴다 |

guardian이 제안을 영구히 막아도 기존 제안 실행·국고 인도는 열려
있다. guardian을 DAO 자신(또는 멀티시그)으로 지정하면 거버넌스
주권이 보존된다 — 배포 시 선택.

## 이 예제 고유의 위험

| 위험 | 완화 |
|---|---|
| **무게가 실행 시점 잔액** — 제안 공개 후 매수로 쿼럼 조작 | 알려진 트레이드오프 (`test_lateAccumulationCanVote`로 명시). 타임락 창구가 관찰 시간을 준다. 스냅샷 필요 시 체크포인트 토큰 + Governor 계열로 — 상태 비용을 지불하는 선택 |
| 유권자가 서명 후 실행 전 매도 | 표 무게가 줄어 쿼럼 깨짐 — 사실상의 표 철회이자 방어 (I1이 자동 정정) |
| relayer가 서명 묶음을 선택적 제출 (부결 시 생략) | 실행자는 누구나 — 다른 relayer가 전체 묶음을 제출할 수 있다. 오프체인 수집의 일반적 성질 |
| ERC-1271 검증 정책·키 변경으로 서명이 무효가 됨 | 실행 시 재검증이 의도된 의미다. 유효한 새 서명을 수집하거나 votingEnds 전 계정이 직접 vote한다 |
| ERC-1271 구현의 비싼 검증 | 검증 비용은 signer 구현에 달려 있다. 승인 주소 목록을 제한한 별도 실행 트랜잭션으로 조합 가능하며 상태 전체를 순회하지 않는다 |
| 직접 vote의 영구 상태 | 유권자·제안당 승인 1슬롯(~105u). 오프체인 서명이 가능하면 0슬롯 경로를 쓴다 |
| 제안 스팸 (2슬롯/건) | 제안자가 상태 비용을 낸다(~208u). 예치금 모델은 커스터마이징 경고로 문서화 |
| 국고가 EOA로 소각성 전송 승인 | 해시 커밋이 실행 내용을 고정 — 투표자가 전문을 검증하지 않으면 사회적 실패 (투표 UI의 책임) |
| quorum을 51% 미만으로 잘못 배포 | immutable — 재배포로만 수정. 배포 체크리스트에서 총공급 대비 비율 산출 필수 |
| FoT 투표권 토큰 사용 | 무게 왜곡 (F-02) — 고정 공급 표준 ERC-20 요구 |
