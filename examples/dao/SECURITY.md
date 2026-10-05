# 예제 11 보안 노트 — 단순 DAO

범위: `contracts/src/dao/SimpleDAO.sol`. 감사 발견 클래스 F-01..F-08
회피 매핑과 이 예제 고유의 위험.

## F 클래스 매핑

| 클래스 | 해당 | 이 예제의 회피 |
|---|---|---|
| F-01 예치·인출 재진입 | 있음 | `execute` nonReentrant + `p.executed = true`를 외부 호출보다 먼저(CEI) — 재진입해도 두 번째는 AlreadyExecuted |
| F-02 수수료-온-전송 | 있음 | 투표권 토큰이 FoT면 무게 산정이 왜곡된다. 배포 시 code 존재만 검증 가능 — **FoT 금지는 배포 요구사항** (README) |
| F-03 무코드 토큰 | 있음 | 생성자에서 `votesToken.code.length > 0` 강제 — 무코드 주소 배포 원천 차단 |
| F-04 비례 뷰 | 없음 | `state`/`getVoteHash` 상수 시간. 서명 검증은 실행 calldata 길이에만 비례 |
| F-05 EIP-7702 | 있음 | 7702 위임 EOA 서명도 ecrecover 동일 처리 — 주소 비교 기반 |
| F-06 단일 등록자 | 없음 | propose는 누구나. quorum·기간·토큰 전부 immutable |
| F-07 오픈 로그 ≠ 승인 | 있음 | `Proposed` 이벤트 ≠ 유효 제안 — 진실은 `proposals` 매핑. 제안 등록과 승인(쿼럼)의 구분이 이 설계의 전부 |
| F-08 무작위성 | 없음 | 사용하지 않음 |

## 불변식

테스트가 강제하는 성질 (`contracts/test/dao/SimpleDAO.t.sol`):

- **I1 쿼럼 판정 대응**: 서명 무게 합 ≥ quorum ⟺ execute 성공 —
  임의 유권자 부분집합에 대해 정확히 대응
  (`test_fuzz_quorumIffWeight`).
- **I2 일회 실행**: executed 플래그 후 재실행·재진입 전부 거부
  (`test_execute_reverts`, CEI 구조).
- **I3 해시 커밋**: target/value/data가 제안 해시와 다르면 실행
  불가 (`HashMismatch`) — 제안 문서 위조가 실행으로 이어질 수 없다.
- **I4 타임라인**: executableFrom = votingEnds + delay,
  expires = executableFrom + grace — 제안마다 생성 시 확정되고
  불변 (`test_propose_opensCommitment`).

## 서명·재생 방지 3겹

| 경계 | 차단 수단 |
|---|---|
| 같은 제안 내 이중 투표 | recovered 주소 엄격 오름차순 (`recovered <= last` revert) — 중복이 정렬 위반 |
| 제안 간 재생 | 서명 해시에 proposalId 포함 — 다른 제안엔 다른 해시 |
| 체인 간·인스턴스 간 재생 | 해시에 `block.chainid` + `address(this)` 포함 (도메인) |

서명은 실행 전까지 어디에도 기록되지 않는다 — 유권자는 서명을
수집자에게 건넨 뒤에도 실행 전이라면 "취소"할 방법이 없다
(무게가 실행 시점 잔액이라 토큰 매도가 사실상의 철회다).

## brake 매트릭스

| 함수 | 분류 | 근거 |
|---|---|---|
| `propose` | **진입** | 신규 상태 생성 — 제동 대상 (스팸·사고 대응) |
| `execute` | **탈출** | 이미 확정된 제안의 집행 — brake로 막으면 국고가 잠긴다 |

guardian이 제안을 영구히 막아도 기존 제안 실행·국고 인도는 열려
있다. guardian을 DAO 자신(또는 멀티시그)으로 지정하면 거버넌스
주권이 보존된다 — 배포 시 선택.

## 이 예제 고유의 위험

| 위험 | 완화 |
|---|---|
| **무게가 실행 시점 잔액** — 제안 공개 후 매수로 쿼럼 조작 | 알려진 트레이드오프 (`test_lateAccumulationCanVote`로 명시). 타임락 창구가 관찰 시간을 준다. 스냅샷 필요 시 체크포인트 토큰 + Governor 계열로 — 상태 비용을 지불하는 선택 |
| 유권자가 서명 후 실행 전 매도 | 표 무게가 줄어 쿼럼 깨짐 — 사실상의 표 철회이자 방어 (I1이 자동 정정) |
| relayer가 서명 묶음을 선택적 제출 (부결 시 생략) | 실행자는 누구나 — 다른 relayer가 전체 묶음을 제출할 수 있다. 오프체인 수집의 일반적 성질 |
| 제안 스팸 (2슬롯/건) | 제안자가 상태 비용을 낸다(~208u). 예치금 모델은 커스터마이징 경고로 문서화 |
| 국고가 EOA로 소각성 전송 승인 | 해시 커밋이 실행 내용을 고정 — 투표자가 전문을 검증하지 않으면 사회적 실패 (투표 UI의 책임) |
| quorum을 51% 미만으로 잘못 배포 | immutable — 재배포로만 수정. 배포 체크리스트에서 총공급 대비 비율 산출 필수 |
| FoT 투표권 토큰 사용 | 무게 왜곡 (F-02) — 고정 공급 표준 ERC-20 요구 |
