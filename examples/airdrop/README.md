# 예제 13 — 머클 에어드랍

> ⚠️ **법적 고지 — 공개 배포 전 법률 검토 필수.** 무상 배포라도
> "누구에게 얼마를 왜 주는가"에 따라 마케팅 규제(송금·보상 공시),
> 세법(기타소득), 증권법(토큰 배정의 이전 거래 조건)이 얽힌다.
> 코인 보상 조건부 추천(referral) 구조는 처음부터 만들지 마라 —
> 이 예제는 그 약속을 하지 않는다 (docs/legal-notes.md 참조).

수령인 1만 명의 명단을 32바이트로 커밋한다. 체인은 루트 하나만
알고, 각자가 증명을 들고 와서 자기 몫을 청구한다.

| | 머클 에어드랍 (이 예제) | 전원 사전 등록 |
|---|---|---|
| 명단 상태 | **루트 1슬롯** (32B) | 1만 슬롯 = 100만 units |
| 명단 등록 가스 | 배포자 부담 0 (오프체인) | 배포자가 전액 선불 |
| 개별 지급 | 청구자가 자기 가스로 claim | 배포자가 1만 건 전송 |
| 미수령분 | 마감 후 sweep — 회수 | 배포자 지갑에 잔류 |
| 명단 공개 | 루트는 공개, 원본은 선택 | 전원 주소가 체인에 영구 |

**핵심 설계 — 명단은 상태가 아니라 약속이다.** 매핑에
`eligible[user] = amount`를 넣으면 배포자가 1만 슬롯의 상태 비용을
선불한다 — 수령인이 누구인지 체인이 기억할 필요는 없다. 머클
루트는 명단 전체의 해시 커밋일 뿐:

```
leaf(u) = keccak256(abi.encodePacked(u, amount))
root     = 머클화(정렬된 전체 리프)   ← 오프체인에서 한 번
claim    = 리프 해시 → 루트까지 32B 증명 log₂N개 제출
```

청구 시점의 상태 비용은 **청구자당 1슬롯(claimed 비트)** — 그리고
이 비트조차 배포자가 아니라 청구 행위가 만든다. 배포자가 지는
비용은 배포 1회뿐이다.

**리프는 주소와 금액을 함께 묶는다.** `keccak256(user, amount)` —
증명을 훔쳐도 남의 주소로는 소용없고, 금액을 낮춰 청구하면 그
금액의 리프가 없어 실패한다. 1청구 1주소 1회(AlreadyClaimed).

## "얼마나 남았나"는 체인이 모른다

남은 미청구액은 `Σ(명단) − Σ(청구)`인데 체인은 명단을 모른다
(F-04). 온체인으로 아는 것:

- `balance` — 풀 잔액 (후원 receive가 섞일 수 있어 **상한**)
- `totalClaimed` — 지급 누적 스칼라 (정확)

정확한 미청구 집계는 **오프체인 인덱스**(명단 − Claimed 이벤트)의
몫이다. 이벤트 스캔은 상태 비용 없이 가능하다 — "계산은
이벤트에서, 진실은 매핑에서" (F-07).

## 마감과 회수

청구 기간을 무한으로 두면 못 받은 몫이 영구 잠긴다. 그래서:

- `deadline`까지 claim — 이후 `ClaimClosed`
- 마감 후 `sweep()` — 잔여 전액을 `distributor`에게, **누구나**
  트리거 가능 (수령인은 고정)

`distributor`는 수령인일 뿐 키가 아니다 — 루트·마감·청구에는
아무 권한이 없다 (F-06). 마감은 계약 조건이므로 프론트·공지로
널리 알려야 한다.

## 함수표

### `MerkleAirdrop` (merkleRoot, distributor, claimPeriod)

| 함수 | 호출자 | 효과 |
|---|---|---|
| `claim(amount, proof)` | 명단 수령인 본인 | 리프 검증 → 지급. 이중 청구·마감 후 거부 |
| `sweep()` | **누구나** | 마감 후 잔여 전액을 distributor에게 |
| `claimed(u)` / `totalClaimed()` | 뷰 | 상수 시간 |

이 컨트랙트에는 brake가 없다 — SimpleBrake는 신규 진입(자금·권리
유입)을 막는 제동인데, 진입은 배포 시점(루트·마감 immutable)에
끝났다. claim·sweep은 둘 다 탈출이라 막으면 자금이 잠긴다.
**막을 진입이 없는 컨트랙트에 brake는 죽은 코드다.**

## 배포

```bash
# 1) 오프체인에서 명단 → 루트·증명 생성 (예: @openzeppelin/merkle-tree)
#    leaf = solidityPackedKeccak256(["address", "uint256"], [user, amount])
#    — 컨트랙트의 abi.encodePacked(account, amount)와 바이트가 같아야 한다

forge create src/airdrop/MerkleAirdrop.sol:MerkleAirdrop \
  --constructor-args $ROOT $DISTRIBUTOR 2592000 \
  --rpc-url $RPC --private-key $DEPLOYER
# claimPeriod 2_592_000초(30일)

# 2) 풀 충전 — 명단 합계 이상을 전송 (receive 허용)
cast send $DROP_ADDRESS --value 15ether --rpc-url $RPC --private-key $FUNDER
```

- `merkleRoot`: 명단 커밋 — **배포 후 변경 불가**. 루트가 틀리면
  전원 청구 실패 → 마감 후 sweep으로 전액 회수·재배포가 유일한
  회복 경로다 (그래서 sweep이 필수다).
- `distributor`: 마감 후 잔여 수령인 — 서명 키가 필요 없다
  (sweep은 permissionless).
- 풀은 명단 합계 이상 충전한다. 부족하면 부족한 시점부터
  `InsufficientPool` — 청구자가 나중에 다시 오면 된다 (claimed
  비트는 실패 시 쓰이지 않는다).

상태 비용 요약 (측정 환경·전체 수치는 [GAS.md](GAS.md)):

| 항목 | units |
|---|---:|
| 배포 (루트·마감·수령인 immutable) | 2,136u |
| claim (청구자 비트 + totalClaimed 최초 기록) | 205u |
| claim 둘째부터 (청구자 비트만) | ~105u |
| sweep (잔여 회수) | 5u |

## 커스터마이징 경고

- **루트 갱신 키**를 만들지 마라. "명단을 실수로 잘못 올렸다"의
  정답은 sweep 후 재배포다. 갱신 가능한 루트는 배포자가 임의로
  자격을 재발행할 수 있다는 뜻이다.
- **마감 없는 무기한 청구**는 잔여를 영구 잠근다 — 반드시
  deadline + sweep 쌍으로 둔다.
- **리프 형식 변경**(예: 금액 대신 클레임 시점 계산)은 증명
  생성기와 반드시 함께 바꿔라 — 컨트랙트와 생성기가 어긋나면
  전원 InvalidProof다.
- **ERC-20 지급**으로 바꾸면 F-02(FoT)·F-03(무코드 토큰) 검사가
  새로 생긴다 — 예제 1·2의 패턴을 먼저 본다.

## 파일

| 파일 | 내용 |
|---|---|
| `contracts/src/airdrop/MerkleAirdrop.sol` | 머클 에어드랍 |
| `contracts/test/airdrop/MerkleAirdrop.t.sol` | 9 tests (증명·이중청구·마감·sweep·보존 fuzz·meter) |
| [SECURITY.md](SECURITY.md) | F-01..F-08 매핑·불변식·고유 위험 |
| [GAS.md](GAS.md) | 상태 units 계량 |
