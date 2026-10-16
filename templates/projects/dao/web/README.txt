# 예제 11 — 단순 DAO (가중 투표 + 타임락 실행)

> ⚠️ **법적 고지 — 공개 배포 전 법률 검토 필수.** 투표권 토큰과 국고를
> 가진 거버넌스는 일부 관할에서 투자계약(증권)으로 분류될 수 있다
> (토큰 발행은 제한 카테고리 — docs/legal-notes.md). 국고 보유·지급도
> 회계·세무 검토 대상이다. 이 예제는 코드 견본이며 법률 자문이 아니다.

투표권 토큰 보유량을 무게로 하는 제안-실행 거버넌스.
**EIP-712 서명 투표는 0슬롯**이고 체인에 남는 것은 제안 2슬롯뿐이다.
EOA는 secp256k1, 스마트 계정은 ERC-1271로 검증하므로 EastSea의
P-256 Secure Enclave 계정도 참여한다. 오프체인 서명을 만들 수 없는
지갑은 계정에서 `vote(id)`를 직접 호출한다 — 이 선택은 표당 1슬롯이다.

| | 이 예제 (서명 투표) | 온체인 투표 (Governor 계열) |
|---|---|---|
| 투표 1건 | **서명 0슬롯 / 직접 vote 1슬롯** | 유권자당 1슬롯 (참여 1만 명 = ~100만 u) |
| 제안 1건 | 2슬롯 (해시 + 타임라인) | 제안 + 스냅샷 + 집계 |
| 투표 비용 | 서명만 또는 직접 vote 트랜잭션 — 실행자가 묶어 제출 | 유권자가 매표 트랜잭션 |
| 개표 | 실행 시 서명·직접 승인 검증 | 실시간 집계 |
| 무게 기준 | **실행 시점 잔액** | 제안 시점 스냅샷 (체크포인트 상태 필요) |

유료 상태 체인에서 참여자 전원이 상태 비용을 내는 온체인 투표는
국고(모든 보유자)의 부담이다. 기본 서명 경로의 수집·검증 비용은
실행자가 오프체인과 자기 트랜잭션으로 진다. 직접 vote는 서명 기능이
없는 지갑을 위한 별도 경로이며 상태 비용을 피하지는 않는다.

## EastSea 계정과 EIP-712 투표

기존 코드는 `personal_sign` 해시와 65바이트 `ecrecover`만 사용해서
P-256 스마트 계정의 투표를 처리할 수 없었다. v2는 OpenZeppelin
`SignatureChecker`를 사용한다: code 없는 EOA는 low-s secp256k1 서명,
code 있는 계정(7702 포함)은 `isValidSignature(bytes32,bytes)`의
ERC-1271 magic value `0x1626ba7e`로 승인한다. 원본 복제본은 변경하지 않았다.

서명할 typed data는 다음과 같다:

```text
domain: { name: "EastSeaSimpleDAO", version: "2", chainId, verifyingContract: DAO 주소 }
Vote(uint256 proposalId,bytes32 executionHash,uint48 votingEnds,uint48 expires)
```

`getVoteHash(id)`는 이 typed data의 최종 digest다. EOA 지갑은
`eth_signTypedData_v4`를 사용하고, digest에 `personal_sign` prefix를
다시 붙이지 않는다. `proposalId`가 제안별 nonce이며 도메인의 chainId·
DAO 주소와 실행 내용·기한을 함께 묶는다. 기존 `personal_sign` 서명은
v2에서 유효하지 않으므로 새 digest로 다시 수집해야 한다.

EastSea v2 계정은 이 DAO digest를 자기 `EastSeaAccount`/`2` 도메인의
`Contents(bytes32 contents)` shell에 넣고 그 EIP-712 메시지 bytes의
SHA-256을 P-256으로 검증한다. 계정에
제출하는 서명은 128바이트 `r || s || x || y`다. DAO는 계정에 digest와
원래 서명 bytes를 전달하고 계정의 검증 정책을 따른다.

스마트 계정·혼합 표는
`executeWithSigners(id, target, value, data, signers, signatures)`로 실행한다.
두 배열의 길이는 같아야 하고 `signers`는 **0이 아닌 주소의 엄격 오름차순**이다.
서명은 EOA 65바이트 또는 계정이 정의한 임의 길이를 허용한다.
빈 서명 `0x`는 그 주소가 이전에 `vote(id)`를 직접 호출한 경우에만 허용한다.
직접 승인과 서명을 섞어도 주소별 현재 잔액을 한 번만 합산한다.

직접 `vote(id)`는 **투표 종료 전**(`timestamp < votingEnds`)에 계정
본인이 호출해야 한다. 중복 호출·없는 제안·brake 중 신규 투표는 거부된다.
실행자는 승인된 주소를 `signers`에 넣어야 하며, 나열하지 않은 표는
자동으로 합산하지 않는다. 서명 없이 직접 vote만 모아도 실행할 수 있다.
직접 승인은 별도 철회 기능이 없고, 모든 표의 무게는 실행 시 잔액이다.
오프체인 서명의 생성 시각은 체인에서 확인하지 않으므로 그 경로는
votingEnds 이후에도 서명을 수집할 수 있고, 실행 시 expires까지
검증한다. 투표 마감 시각에 서명까지 고정하는 모델은 아니다.

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
   2슬롯    EIP-712 서명 / 직접 vote      exit 창구                  execute, 놓치면 폐기
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
| `vote(id)` | 유권자 계정 본인 | 진입 차단 | 투표 종료 전 직접 승인 — 유권자·제안당 1슬롯 |
| `execute(id, target, value, data, signatures)` | 누구나 (relayer) | **무관 (탈출)** | 기존 EOA ABI — 서명 검증·쿼럼 확인 후 실행 |
| `executeWithSigners(id, target, value, data, signers, signatures)` | 누구나 (relayer) | **무관 (탈출)** | EOA·ERC-1271·직접 승인 표를 섞어 실행 |
| `getVoteHash(id)` | 뷰 | — | EIP-712 Vote digest |
| `domainSeparator()` / `eip712Domain()` | 뷰 | — | 현재 chainId와 DAO 주소를 포함하는 서명 도메인 |
| `approvedVotes(id, voter)` | 뷰 | — | 해당 계정의 직접 vote 승인 여부 |
| `state(id)` | 뷰 | — | 없음/투표중/타임락/실행가능/실행됨/만료 |

- 유권자 서명은 **주소 오름차순**으로 정렬해 제출한다 — 정렬 검사가
  중복·무효·미정렬을 한 번에 막는다 (예제 8과 동일 규칙).
- guardian은 **새 제안과 직접 vote**를 막는다. 진행 중 제안의 실행(국고 지출)은
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
| v2 배포 | 8,198u |
| 제안 1건 (해시 + 타임라인 2슬롯) | 208u |
| 서명 투표 1건 | **0u** |
| 직접 vote 1건 (1슬롯 + 이벤트) | 105u |
| 실행 (서명 5개, 0슬롯) | 7u |

## 커스터마이징 경고

- **찬성만 있다.** 반대(abstain/against) 가중치를 더하려면
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
| `contracts/src/dao/SimpleDAO.sol` | 해시 커밋 제안 + EIP-712/ERC-1271/직접 투표 DAO |
| `contracts/test/dao/SimpleDAO.t.sol` | 12 tests (기능·거부 경로·트레이드오프 PoC·fuzz·brake·meter) |
| `contracts/test/dao/SimpleDAO1271.t.sol` | 27 tests (P-256·EOA·wrong signer·replay·expired·혼합/직접 투표·계정 정책·rollback) |
| `contracts/test/utils/EastSeaAccountMock.sol` | EastSea v2 ERC-1271 interface + 실제 P-256 검증 fixture |
| [SECURITY.md](SECURITY.md) | F-01..F-08 매핑·불변식·고유 위험 |
| [GAS.md](GAS.md) | 상태 units 계량 |

## Personal test instance: testnet and mainnet

<!-- i18n: personal_test.title personal_test.testnet personal_test.mainnet personal_test.accounts personal_test.local personal_test.fees personal_test.caps personal_test.identity -->

On **testnet**, use test coins. A shared demo is allowed. Publish with your
own wallet using `--network testnet --apps dao` and the testnet registry,
names service and owned name described in the [publisher guide](../../README.md#try-the-toolbox-on-the-eastsea-testnet-with-your-own-account).
Ordinary constructors retain the existing testnet behavior; `--personal-test`
also works on testnet for rehearsing the private flow.

On **mainnet**, deploy and use **your own private copy only**. Neither Pipln
nor the founder operates a financial service for other people. After setting
`YOUR_ACCOUNT`, `YOUR_NODE_RPC` and the actual `MAINNET_CHAIN_ID` from your
wallet/node, first inspect the offline plan:

```bash
python3 scripts/publish.py --network mainnet --personal-test --dry-run \
  --apps dao --from "$YOUR_ACCOUNT" --chain-id "$MAINNET_CHAIN_ID"

# Run from the repository root when you choose to deploy your own instance.
# Your EIP-1193 wallet approves each transaction; no key is passed to Python.
python3 scripts/publish.py --network mainnet --personal-test \
  --apps dao --from "$YOUR_ACCOUNT" --chain-id "$MAINNET_CHAIN_ID" \
  --rpc "$YOUR_NODE_RPC" --bundle-mode local
```

The atomic personal deployer sets `instanceMode()` to `personal-test` before
use. Only your deploying wallet is initially allowlisted. Add another account
**only if it is yours** with `setPersonalTestAccount(address,bool)` through
your wallet; counterparties/beneficiaries must be your own allowed accounts.
A native cap and an aggregate admitted token cap apply to each instance.
Defaults are `10000000000000000` native base units and `5000000000000000000`
18-decimal **own test-token** units; adjust with `--personal-native-cap` and
`--personal-token-cap`. These are quantities, **not a dollar-equivalence claim**.
No protocol fee or new administrative withdrawal exists in personal mode;
network fees still apply.

Use the generated local bundle against its fixed addresses. Serve it on
loopback or let the wallet browser load its local assets; do not upload it,
register it as a public app, or run a shared mainnet frontend. The frontend
checks mode, owner, caps, authority and your account before writes. See
[the policy and wallet interface](../../docs/personal-mainnet-testing.md)
for asset-cap limitations, account removal/exit behavior and local loading.
English copy has stable [translation keys](../../docs/i18n/personal-test.en.json);
this branch has not integrated the five-language pack.
