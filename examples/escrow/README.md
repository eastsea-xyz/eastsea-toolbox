# 예제 9 — 마일스톤 에스크로

> ⚠️ **법적 고지 — 공개 배포 전 법률 검토 필수.** 제3자 자금 보관은
> 관할에 따라 수탁업·전자금융업 등록 요건을 유발할 수 있다. 이
> 예제는 코드 견본이며 법률 자문이 아니다.

구매자가 native coin을 예치하고, 결과가 마음에 들 때마다 마일스톤을
승인해 판매자에게 인출권을 넘긴다. 미승인 잔여는 언제든 구매자가
회수한다 — 판매자의 완수 위험과 구매자의 지급 위험을 동시에 묶는
가장 단순한 형태의 양방향 에스크로.

**복사해서 배포하려면:** `contracts/src/escrow/MilestoneEscrow.sol`
(의존성: `src/system/SimpleBrake.sol`, OZ ReentrancyGuard).
[배포](#배포) 절차를 따른다.

## 자금 흐름

```
구매자 ──createDeal(10 ETH)──▶ 에스크로 ──buyerRefund──▶ 구매자 (미승인분)
                                   │
              approveMilestone(i)  │ 판매자 인출권 = 승인 누적
                                   ▼
                              sellerWithdraw ──▶ 판매자
```

불변식: `남은예치 == 승인누적 - 인출누적 + 환불가능`. 승인은 취소할 수
없다 — 되돌림이 필요하면 구매자·판매자가 합의해 판매자가 직접
되돌려보내는 것이 오프체인 합의 영역이다.

## 설계 — 마일스톤 배열을 상태에 두지 않는다

전형적인 구현은 마일스톤 금액 배열을 스토리지에 저장한다. 이 예제는
다르다:

- **금액은 승인 시점에 구매자가 지정**한다 (`approveMilestone(dealId,
  index, amount)`). 저장되는 것은 "승인 누적" 스칼라 하나.
- 마일스톤 **개수**만 생성 시 고정 — 인덱스당 1회 승인을 해시 슬롯
  (`milestoneApproved[keccak(dealId, index)]`)으로 막는 가드일 뿐.
- 상세 금액 목록은 **오프체인 계약서가 진실**이다. 체인은 합의된
  개수 내에서 구매자가 얼마를 풀었는지만 증명한다.

거래 1건 = 구조체 4슬롯 + 승인당 해시 슬롯 1개. 마일스톤 10개짜리
거래도 금액 배열 없이 승인 슬롯 10개가 전부다.

## 함수표

| 함수 | 호출자 | brake | 효과 |
|---|---|---|---|
| `createDeal(seller, milestoneCount)` payable | 구매자 | 진입 차단 | 전액 예치, 거래 개시 |
| `approveMilestone(dealId, index, amount)` | 구매자 본인 | 무관 | 승인 누적 증가 (취소 없음) |
| `sellerWithdraw(dealId)` | 판매자 본인 | **무관 (탈출)** | 승인 미인출분 수령 |
| `buyerRefund(dealId)` | 구매자 본인 | **무관 (탈출)** | 미승인 잔여 회수 |
| `dealInfo(dealId)` | 뷰 | — | (buyer, seller, 환불가능, 인출가능) |

전액 환불된 거래는 소멸 상태가 된다 (`deposited == 0` — 미사용 id와
구분 불가). 이는 버그가 아니라 상태 절약의 결과이며, 남은 승인분 0과
일관된 의미론이다.

## 배포

```bash
forge create src/escrow/MilestoneEscrow.sol:MilestoneEscrow \
  --constructor-args $GUARDIAN --rpc-url $RPC --private-key $DEPLOYER
```

상태 비용 요약 (측정 환경·전체 수치는 [GAS.md](GAS.md)):

| 항목 | units |
|---|---:|
| 배포 | 4,342u |
| createDeal (거래당 1회) | 408u |
| approveMilestone (마일스톤당) | 106u |
| sellerWithdraw / buyerRefund (반복) | **5u** |

인출·환불이 로그만큼 싸다 (5u) — 분쟁이 나도 탈출 비용은 거의 0이다.

## 커스터마이징 경고

- **승인 취소 기능을 넣지 마라.** "승인했지만 아직 인출 전" 상태를
  되돌리는 기능은 구매자·판매자가 동시에 조작할 수 있는 새로운
  경쟁 상태(race)를 만든다. 취소가 필요한 비즈니스라면 예치 자체를
  나눠 여러 딜로 발행하라.
- 중재자(arbiter) 역할을 추가하면 F-06(단일 등록자)·키 관리 문제가
  함께 온다. 필요하면 예제 8 멀티시그를 중재자 주소로 쓰는 조합이
  낫다.
- `receive()`가 revert한다 — 직접 송금은 회계를 우회하므로. 토큰을
  받게 바꾸려면 F-02(FoT)·F-03(무코드) 대응을 SafeToken 경로로
  다시 해야 한다 (예제 3·6 참고).

## 파일

| 파일 | 내용 |
|---|---|
| `contracts/src/escrow/MilestoneEscrow.sol` | 에스크로 |
| `contracts/test/escrow/MilestoneEscrow.t.sol` | 14 tests (기능·brake·fuzz·meter) |
| [SECURITY.md](SECURITY.md) | F-01..F-08 매핑·불변식·분쟁 시나리오 |
| [GAS.md](GAS.md) | 상태 units 계량 |

## Personal test instance: testnet and mainnet

<!-- i18n: personal_test.title personal_test.testnet personal_test.mainnet personal_test.accounts personal_test.local personal_test.fees personal_test.caps personal_test.identity -->

On **testnet**, use test coins. A shared demo is allowed. Publish with your
own wallet using `--network testnet --apps escrow` and the testnet registry,
names service and owned name described in the [publisher guide](../../README.md#try-the-toolbox-on-the-eastsea-testnet-with-your-own-account).
Ordinary constructors retain the existing testnet behavior; `--personal-test`
also works on testnet for rehearsing the private flow.

On **mainnet**, deploy and use **your own private copy only**. Neither Pipln
nor the founder operates a financial service for other people. After setting
`YOUR_ACCOUNT`, `YOUR_NODE_RPC` and the actual `MAINNET_CHAIN_ID` from your
wallet/node, first inspect the offline plan:

```bash
python3 scripts/publish.py --network mainnet --personal-test --dry-run \
  --apps escrow --from "$YOUR_ACCOUNT" --chain-id "$MAINNET_CHAIN_ID"

# Run from the repository root when you choose to deploy your own instance.
# Your EIP-1193 wallet approves each transaction; no key is passed to Python.
python3 scripts/publish.py --network mainnet --personal-test \
  --apps escrow --from "$YOUR_ACCOUNT" --chain-id "$MAINNET_CHAIN_ID" \
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
