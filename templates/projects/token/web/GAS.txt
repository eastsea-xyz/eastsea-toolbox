# 예제 1 가스·상태 비용 — `FixedSupplyToken`

측정 환경: forge 1.6.0-nightly (5e88010), solc 0.8.24, optimizer 200 runs,
evm_version = paris. 원본 출력은 `forge test --match-contract FixedSupplyTokenTest
--match-path 'test/token/*' -vv` 의 `test_meter_*` 로그.

## 측정치 (2026-10-05)

| 연산 | gasUsed¹ | 새 계정 | 새 슬롯 | 코드 B | 로그 B² | 상태 units³ |
|---|---:|---:|---:|---:|---:|---:|
| 배포 (생성자 mint 포함) | 886,650 | 1 | 4 | 3,839 | 224 | **4,345** |
| transfer — 신규 보유자 | 27,016 | 0 | 1 | — | 192 | **106** |
| transfer — 기존 보유자 | 4,318 | 0 | 0 | — | 192 | **6** |
| approve — 신규 spender | 23,693 | 0 | 1 | — | 160 | **104** |
| permit + transferFrom | (미측정⁴) | 0 | 2 | — | 352 | **212** |

¹ `gasleft` 차이 근사 — callee 프레임 실행 가스. 트랜잭션 intrinsic gas
  (21,000 + calldata 4/16 per byte)과 영수증 기본 비용은 별도다.
² 이벤트 계량 바이트 = 64 + (토픽 수 × 32) + data 길이.
  Transfer: 3 토픽 + 32B value = 192. Approval: 3 토픽 + 64B = 160.
³ `100×(새 슬롯+새 계정) + 코드 바이트 + ceil(로그 B/32)`.
⁴ permit은 서명 검증 + 논스 소진 + 허용량 기록의 합이라 측정 분해가
  필요하다 — 필요 시 `test_meter_permit` 추가. 슬롯 수(논스+허용량)는 확정.

## 체인이 추가로 청구하는 것 (테스트로 잡히지 않음)

| 항목 | 근사 | 비고 |
|---|---:|---|
| tx envelope + 영수증 | 128 B | 모든 tx 공통 (27-state-fee.md) |
| calldata 영속 바이트 | ceil(calldata/32) | transfer ≈ 68 B → 3 units |
| 배포 시 생성 calldata | ceil(creationCode/32) | 배포 tx에서만 |

즉 실제 발신자 부담은 위 표의 units + envelope/영수증 항목이다.
1 unit = 1e12 wei (0.000001 AETH).

## 배포 시 신규 슬롯 4개의 내역 (실측 newSlots=4)

1. `totalSupply` — OZ ERC20
2. `balances[recipient]` — 생성자 mint
3. `name` 문자열 (짧아 1 슬롯)
4. `symbol` 문자열 (짧아 1 슬롯)

permit의 논스 슬롯은 첫 서명 시점에야 생긴다 (배포 비용에 없음).

## 설계 시사점

- **홀더 수 = 상태 비용.** 신규 보유자 1명마다 106 units가 발신자
  (또는 에어드랍 실행자)에게 부과된다. 10,000명 에어드랍 ≈ 1,060,000
  units ≈ 1.06 AETH — 예제 13(Merkle 클레임)은 이 비용을 수신자
  각자의 클레임 tx로 분산시킨다.
- **기존 보유자 재이체는 사실상 공짜** (6 units). 포인트 적립·반환
  루프는 기존 사용자에게 2회째부터 저렴하다.
- **approve 최초 1회 104 units** — `permit`은 이 슬롯을 서명으로
  미리 확보하지 않는다(논스+허용량 2슬롯 212 units). 즉 permit이
  이득인 건 "승인을 아직 한 번도 안 한 사용자"가 서명만으로
  transferFrom을 유도할 때가 아니라, dapp이 서명 1개로 승인+집행을
  한 번에 처리할 때다.

## 재측정 방법

```bash
cd contracts
forge test --match-contract FixedSupplyTokenTest -vv 2>&1 | grep -E 'deploy |transfer-|approve-'
FOUNDRY_FUZZ_RUNS=5000 forge test --match-path 'test/token/*'  # 심층
```

체인 파라미터(유닛 가격, 슬롯 당 units)가 바뀌면 `docs/paid-state-design.md`와
`contracts/test/utils/StateMeter.sol` 주석을 먼저 갱신한 뒤 이 표를 다시 채운다.
