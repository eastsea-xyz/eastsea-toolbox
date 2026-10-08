# 예제 17 — Kelp Kiosk · 에이전트 자판기

> [!WARNING]
> **공개 배포 전 법률 검토 필수.** AI 생성물 판매는 관할별로 소비자
> 보호·저작권·책임 규제가 다르게 붙는다. 수익·가격 약속, 코인
> 리워드 추천 구조는 포함하지 않는다 (docs/legal-notes.md).

마지막 예제는 7702 시대의 기본 계약 형태 하나를 다룬다: **정가
선결제로 AI 에이전트에게 작업을 시키고, 기한 내 결과물 해시가
등록되면 즉시 정산, 기한이 지나면 전액 환불**. 주문자가 사람이든
다른 에이전트든, 위임 계정이든 무관하게 같은 규칙이 적용된다.

```
주문자:  order(specHash){value: price} ──▶ 주문 #N, 배달 마감 due
에이전트: deliver(N, resultHash)  (due 전) ──▶ 즉시 정산, 슬롯 반납
주문자:  refund(N)          (due 후) ──▶ 전액 회수, 슬롯 반납
```

## 왜 이 구조인가 — 자판기는 심사하지 않는다

에스크로(예제 9)는 "구매자가 승인하면 돈이 풀린다"다. AI 작업에는
그 승인 단계가 맞지 않는다 — 결과물의 품질을 온체인이 판정할 수
없고, 판정자를 두면 다시 신뢰 당사자가 생긴다. 이 예제는 승인을
**아예 없앤다**:

- `deliver`는 결과물 **해시** 등록만으로 정산한다. 온체인이 아는
  것은 "기한 내 뭔가 등록됐는가"뿐이다.
- 품질 분쟁은 온체인 밖(후기·평판)의 영역이다. 주문이 무엇을
  원했는지는 `Ordered` 로그의 `specHash`, 무엇이 왔는지는
  `Delivered` 로그의 `resultHash` — 계약의 양 끝이 로그에 있고
  누구도 검증할 필요가 없다. 결과물 자체(URL·문서)는 상태가
  아니다.
- 대신 **기한이 정직성의 담보**다. 기한 내 등록 실패의 대가는
  전액 환불 — 에이전트가 잠적해도 주문자는 `refund` 한 번으로
  빠져나온다. "합의를 기다리는 돈"이라는 상태가 존재하지 않는다.

## 설계 결정

### 1. 진행 중인 돈만 슬롯이다

주문 슬롯은 `{buyer, due}` 팩 하나. 배달·환불 모두 슬롯을
`delete`한다(CEI) — 완결된 주문은 존재하지 않는다(예제 16과 같은
원리). 재배달·이중 환불·기한 후 배달은 전부 "주문 부재"로 죽는다.

배달의 순영구 상태는 **0슬롯**이다: 정산은 들어온 value를 그대로
넘기고, 주문 슬롯은 반납된다. 자판기는 돈이 머무는 곳이 아니라
지나가는 곳이다.

### 2. 정가, 재고 없음

가격·기한은 배포 시 immutable — 주문마다 흥정하는 필드가 없다.
디지털 작업은 재고가 없으므로 재고 상태도 없다. 판매 조건을
바꾸려면 새 자판기를 새로 배포한다(주소가 곧 가격표다).

### 3. 주문자가 누구든 같은 규칙 (F-05)

`order`·`refund`가 보는 것은 `msg.sender` 주소와 `msg.value`뿐.
주문자가 EOA든, 7702로 위임 코드를 깐 계정이든, 아예 다른
에이전트 컨트랙트든 규칙은 동일하다 — "에이전트가 대신 산다"는
특별한 경로를 만들지 않는 것이 7702 체인의 정석이다.

### 4. brake는 주문만 막는다

`SimpleBrake`로 신규 주문을 멈출 수 있다(에이전트 운영 중단).
진행 중 주문의 배달·환불은 항상 열려 있다 — 판매를 멈춰도 돈의
출구를 막지 않는다.

## 라이프사이클 사용법

```bash
# 주문 — 명세의 해시와 정가 (spec 원문은 오프체인에서 보관·공개)
cast send $VEND 'order(bytes32)' $(cast keccak "translate 5 pages") --value 0.2ether

# 배달 — 에이전트가 결과물 해시 등록, 즉시 정산
cast send $VEND 'deliver(uint256,bytes32)' 1 $(cast keccak "ipfs://QmY")
```

## 커스터마이징 경고

- **승인 단계 추가 금지**: "구매자가 accept 하는" escrow 구조로
  바꾸는 건 예제 9의 영역이다 — 두 패턴을 섞으면 "승인 대기
  상태"(둘 다 못 받는 돈)가 생긴다. 하나를 고르라.
- **가격·기한 변경 키 금지**: 배포 후 가격을 바꾸는 키는 "이미
  주문한 사람과 새 주문의 약속이 다르다"는 상태를 만든다.
  새 배포가 유일한 변경 경로다.
- **부분 환불 금지**: "절반만 쓰레기였다"는 주장의 온체인 판정은
  불가능하다 — 부분 정산 키는 분쟁 조정자 키(F-06)가 된다.

## 함께 보기

- `contracts/src/vending/AgentVending.sol` — 구현
- `contracts/test/vending/AgentVending.t.sol` — 10 테스트
  (기한 경계, 재배달·이중환불 부재, fuzz 보존, brake, 계량)
- `examples/vending/SECURITY.md` · `examples/vending/GAS.md`
- 예제 9(`examples/escrow/`) — 승인형 에스크로와의 비교
- 예제 16(`examples/invoice/`) — 반대 방향(청구서)의 같은 원리

## Personal test instance: testnet and mainnet

<!-- i18n: personal_test.title personal_test.testnet personal_test.mainnet personal_test.accounts personal_test.local personal_test.fees personal_test.caps personal_test.identity -->

On **testnet**, use test coins. A shared demo is allowed. Publish with your
own wallet using `--network testnet --apps vending` and the testnet registry,
names service and owned name described in the [publisher guide](../../README.md#try-the-toolbox-on-the-eastsea-testnet-with-your-own-account).
Ordinary constructors retain the existing testnet behavior; `--personal-test`
also works on testnet for rehearsing the private flow.

On **mainnet**, deploy and use **your own private copy only**. Neither Pipln
nor the founder operates a financial service for other people. After setting
`YOUR_ACCOUNT`, `YOUR_NODE_RPC` and the actual `MAINNET_CHAIN_ID` from your
wallet/node, first inspect the offline plan:

```bash
python3 scripts/publish.py --network mainnet --personal-test --dry-run \
  --apps vending --from "$YOUR_ACCOUNT" --chain-id "$MAINNET_CHAIN_ID"

# Run from the repository root when you choose to deploy your own instance.
# Your EIP-1193 wallet approves each transaction; no key is passed to Python.
python3 scripts/publish.py --network mainnet --personal-test \
  --apps vending --from "$YOUR_ACCOUNT" --chain-id "$MAINNET_CHAIN_ID" \
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
