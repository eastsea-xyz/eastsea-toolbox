# 예제 11 — 단순 DAO (가중 투표 + 타임락 실행)

> ⚠️ **법적 고지 — 공개 배포 전 법률 검토 필수.** 투표권 토큰과 국고를
> 가진 거버넌스는 일부 관할에서 투자계약(증권)으로 분류될 수 있다
> (토큰 발행은 제한 카테고리 — docs/legal-notes.md). 국고 보유·지급도
> 회계·세무 검토 대상이다. 이 예제는 코드 견본이며 법률 자문이 아니다.

투표권 토큰 보유량을 무게로 하는 제안-실행 거버넌스. 온체인 투표
모델(Governor 계열)이 유권자당 1슬롯씩 상태를 쌓는 것과 달리,
**투표는 전부 오프체인 서명**이고 체인에 남는 것은 제안 2슬롯뿐이다.

| | 이 예제 (서명 투표) | 온체인 투표 (Governor 계열) |
|---|---|---|
| 투표 1건 | **0 슬롯** — 오프체인 서명 | 유권자당 1슬롯 (참여 1만 명 = ~100만 u) |
| 제안 1건 | 2슬롯 (해시 + 타임라인) | 제안 + 스냅샷 + 집계 |
| 투표 비용 | 서명만 (가스 0) — 실행자가 묶어 제출 | 유권자가 매표 트랜잭션 |
| 개표 | 실행 시 서명 검증 | 실시간 집계 |
| 무게 기준 | **실행 시점 잔액** | 제안 시점 스냅샷 (체크포인트 상태 필요) |

유료 상태 체인에서 참여자 전원이 상태 비용을 내는 온체인 투표는
국고(모든 보유자)의 부담이다. 여기서 서명 수집·검증 비용은 실행자가
오프체인과 자기 트랜잭션으로 진다.

## 제안은 해시 커밋이다

`propose(executionHash)`는 실행할 행동의 해시
`keccak256(abi.encode(target, value, data))`만 체인에 남긴다 —
calldata를 스토리지에 저장하지 않는다. 전문은 포럼·IPFS 등 오프체인에
공개하고, 체인은 **약속(해시)과 증명(서명)**만 보관한다. 실행 시
해시가 일치해야 하므로 제안 문서와 실행 내용의 불일치는 구조적으로
차단된다.

## 라이프사이클

```
propose ──▶ 투표 (votingPeriod) ──▶ 타임락 (timelockDelay) ──▶ 실행 창구 (gracePeriod)
   2슬롯        오프체인 서명            exit 창구                  execute, 놓치면 폐기
```

- **타임락 창구**는 쿼럼 확인 후에도 반대 보유자가 토큰을 덜거나
  대응을 준비할 시간이다. 고전 Governor+Timelock 두 컨트랙트를
  하나로 합쳤다 — 실행 권한이 이미 "쿼럼 서명 보유자"로 좁혀져 있어
  별도 관리자 컨트랙트가 추가할 보증이 없다.
- 유예 기간(`gracePeriod`)이 지나면 제안은 폐기 — 같은 해시로
  재제안하면 새 id가 붙어 서명을 다시 모은다.

## 무게는 실행 시점 잔액이다 (문서화된 트레이드오프)

체크포인트 토큰(과거 시점 잔액 조회)은 투표 시점 지분을 정확히 고정하지만
계좌당 슬롯을 계속 쌓는다. 이 예제는 `balanceOf`(실행 시점)를 쓴다:

- 서명 후 토큰을 팔면 그 표는 줄어든다 (`test_soldTokensLoseWeight`)
- 반대로 제안 공개 후 매수하면 무게가 늘어난다 —
  `test_lateAccumulationCanVote`가 이 속성을 있는 그대로 증명한다.
  타임락 창구가 이 이동을 관찰할 시간을 준다. 스냅샷 정확성이
  필요하면 체크포인트 상태 비용을 지불하고 Governor 계열로 가라 —
  그 트레이드오프가 이 예제의 핵심 교훈이다.

## 함수표

### `SimpleDAO` (guardian, votesToken, quorum, votingPeriod, timelockDelay, gracePeriod)

| 함수 | 호출자 | brake | 효과 |
|---|---|---|---|
| `propose(executionHash)` | 누구나 | 진입 차단 | 제안 개시 — 해시 커밋 + 타임라인 확정 |
| `execute(id, target, value, data, signatures)` | 누구나 (relayer) | **무관 (탈출)**** | 서명 검증·쿼럼 확인 후 임의 호출 실행 |
| `getVoteHash(id)` | 뷰 | — | 유권자가 personal_sign으로 서명할 해시 |
| `state(id)` | 뷰 | — | 없음/투표중/타임락/실행가능/실행됨/만료 |

- 유권자 서명은 **주소 오름차순**으로 정렬해 제출한다 — 정렬 검사가
  중복·무효·미정렬을 한 번에 막는다 (예제 8과 동일 규칙).
- guardian은 **새 제안만** 막는다. 진행 중 제안의 실행(국고 지출)은
  brake 하에서도 열려 있다 — 실행을 막으면 자금이 잠긴다.
  guardian에 멀티시그(예제 8)나 DAO 자신의 주소를 지정하면 주권이
  거버넌스에 남는다.
- 국고는 `receive()`로 누구나 충전한다. 실행은 국고 잔액 내에서만.

## 배포

```bash
# executionHash 사전 계산 (제안 문서와 함께 공개)
cast keccak $(cast abi-encode "f(address,uint256,bytes)" $TARGET 1ether 0x)
# → 이 해시를 propose()에 제출한다

forge create src/dao/SimpleDAO.sol:SimpleDAO \
  --constructor-args $GUARDIAN $VOTE_TOKEN $QUORUM $VOTING_PERIOD $DELAY $GRACE \
  --rpc-url $RPC --private-key $DEPLOYER
```

quorum은 절대량(예: 공급량의 4%). 기간·쿼럼은 immutable — 바꾸려면
새 DAO를 배포하고 국고를 이전 제안으로 옮긴다.

상태 비용 요약 (측정 환경·전체 수치는 [GAS.md](GAS.md)):

| 항목 | units |
|---|---:|
| 배포 | 4,743u |
| 제안 1건 (해시 + 타임라인 2슬롯) | 208u |
| 투표 1건 | **0u** |
| 실행 (서명 5개, 0슬롯) | 7u |

## 커스터마이징 경고

- **무기명 찬성만 있다.** 반대(abstain/against) 가중치를 더하려면
  서명 해시에 선택지를 넣고 execute가 찬성-반대 순정(net)을 검증하게
  하라 — 상태 비용은 그대로 0이다 (해시만 바뀐다).
- 투표권 위임(delegation)은 토큰 쪽 기능이다. 고정 공급 토큰을
  쓰는 한 없는 기능이며, 위임 가능 토큰으로 바꾸면 무게 산정 시점
  논의가 다시 열린다.
- 제안 스팸 방지(예치금·발언권)를 넣으면 propose의 경제학이
  바뀐다 — 예치금 환급 경로가 또 하나의 탈출이 되어야 한다.

## 파일

| 파일 | 내용 |
|---|---|
| `contracts/src/dao/SimpleDAO.sol` | 해시 커밋 제안 + 서명 투표 DAO |
| `contracts/test/dao/SimpleDAO.t.sol` | 12 tests (기능·거부 경로·트레이드오프 PoC·fuzz·brake·meter) |
| [SECURITY.md](SECURITY.md) | F-01..F-08 매핑·불변식·고유 위험 |
| [GAS.md](GAS.md) | 상태 units 계량 |
