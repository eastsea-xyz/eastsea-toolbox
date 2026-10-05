# eastsea-toolbox

실제 제품까지 갈 수 있는 스마트 컨트랙트 예제 모음. **폴더 하나를 통째로
복사해 배포하는 제3자 빌더를 위한 툴박스다.**

17개 예제 · Foundry 테스트 280개 · 각 예제마다 가스/상태 비용 문서,
보안 문서(F-01…F-08 매핑), 앱 레지스트리 manifest, 정적 프론트엔드.

> [!WARNING]
> **모든 예제는 교육·프로토타입용 템플릿이다.** 특히 토큰 발행이
> 포함된 예제(1·4·5)는 제한 카테고리다 — **법률 검토 전 공개 배포
> 금지.** `docs/legal-notes.md` 참고.

## 카탈로그

| # | 예제 | 폴더 | 앱 이름 | 다루는 것 |
|---|---|---|---|---|
| 1 | 고정 공급 ERC-20 | `examples/token` | Island Coin | EIP-2612 permit, 발행 없는 토큰 |
| 2 | 온체인 메타데이터 NFT | `examples/nft` | Island Folk Studio | ERC-721 + 한정판 ERC-1155 판매, EIP-2981 |
| 3 | 고정가 NFT 시장 | `examples/market` | Harbor Market | 에스크로 리스팅, 로열티 분할, pull 지급 — F-01 재진입 플레이북 |
| 4 | 유니스왑 V2식 AMM | `examples/amm` | Harbor Swap | 팩토리·페어·LP 토큰·TWAP·4홉 라우터, FoT 회피 |
| 5 | 본딩 커브 런치패드 | `examples/launchpad` | Tidepool Launchpad | 스나이핑 방지 세금, 인당 한도, AMM(예제 4)으로 졸업 |
| 6 | 선형 스테이킹 보상 | `examples/rewards` | Driftwood Staking | 스폰서 예치 풀, Synthetix 전량언스테이크 보상 손실 수정 |
| 7 | 토큰 락 | `examples/lock` | Harbor Lock | 배치 타임락 + 자체 에스크로 그랜트, 베스팅 |
| 8 | K-of-N 멀티시그 | `examples/multisig` | Tidal Council | 오프체인 서명 수집 — execute 1회 = 상태 1슬롯 |
| 9 | 마일스톤 에스크로 | `examples/escrow` | Sea Chest | 구매자 예치·승인 릴리즈·언제든 잔액 환불 |
| 10 | 구독 | `examples/subscription` | Tide Pass | 초당 정가 시간 판매, 일부 환불 cancel, 만료 정산 |
| 11 | 해시 커밋 DAO | `examples/dao` | Coral Senate | 오프체인 가중 투표 서명(투표 상태 0슬롯) |
| 12 | 올오어낫씽 크라우드펀드 | `examples/crowdfund` | Lighthouse Fund | 성공 시 permissionless 일괄 지급, 실패 시 자기청구 환불 |
| 13 | 머클 에어드랍 | `examples/airdrop` | Pearl Drop | 32바이트 루트가 전체 명단, 증명 청구, 마감 스윕 |
| 14 | 커밋-리빌 래플 | `examples/raffle` | Tidal Draw | 호스트 시드 커밋 → 참가 → 리빌 혼합 추첨, 무시드 폴백 |
| 15 | 이름 위임 드롭 | `examples/names` | Reef Drop | 자격 전부를 .aeth 이름 서비스에 위임 — 앱의 자격 상태 0슬롯 |
| 16 | 번호 청구서 장부 | `examples/invoice` | Tide Ledger | 발행→정확 금액 결제→슬롯 delete, 이중결제 원천 차단 |
| 17 | 에이전트 자판기 | `examples/vending` | Kelp Kiosk | 정가 선결제, 기한 내 결과 해시 등록 즉시 정산, 배달 0슬롯 |

각 예제 폴더(`examples/<slug>/`)에는:

- `README.md` — 설계 결정, 라이프사이클 사용법, 커스터마이징 경고
- `SECURITY.md` — F-01…F-08 위협 클래스별 회피 근거, 불변식, 고유 위험
- `GAS.md` — gas·상태 units(≈u) 측정, 대량 시나리오, 누적 경로 분석
- `manifest.json` — `eastsea-app/1` 스키마 앱 등록 원고 (0x0 플레이스홀더)

## 빠른 시작

```bash
# 의존성: foundryup (forge, cast), python3 + jsonschema

make test          # 전체 forge test (기본 fuzz)
make test-deep     # FOUNDRY_FUZZ_RUNS=5000 — 자금 보유 불변식 심층
make fmt           # forge fmt
make manifests     # 전 manifest 스키마 검증
make apps          # apps/ 정적 프론트 재생성 (scripts/gen-apps.py)
```

수동 실행은 항상 `contracts/` 안에서:

```bash
cd contracts && forge test -vv
cd contracts && FOUNDRY_FUZZ_RUNS=5000 forge test
cd contracts && forge fmt --check
```

## 구조

```
contracts/          Foundry 프로젝트 (src/system/ = 공통 기반: SimpleBrake, StateMeter…)
  src/<slug>/       17개 예제 컨트랙트
  test/<slug>/      테스트 (기능·거부 경로·fuzz 보존·brake·계량)
examples/<slug>/    문서 4종 + manifest (배포 단위)
apps/<slug>/        정적 프론트엔드 — 단일 index.html, 빌드·서버 불필요
apps/index.html     앱 카탈로그
templates/publish/  배포 도구 — 스키마 사본, manifest 검증기, bundle-hash
docs/               paid-state-design · safety-checklist · legal-notes
```

### 프론트엔드

`apps/<slug>/index.html`은 의존성 없는 단일 파일이다 — 지갑 탐지는
EIP-6963 + `window.aether` 폴백, 체인 검증 `chainId 0x1e64` (EastSea),
바닐라 ABI 인코딩(selector·topic은 사전 계산 상수), `eth_call` 조회,
`eth_sendTransaction` 실행, `eth_getLogs` 이벤트 조회. 배포 주소는
쿼리로 전달한다:

```
https://<host>/apps/vending/?contract=0x1234…
```

### 배포 파이프라인

1. `examples/<slug>/manifest.json`의 0x0 플레이스홀더를 실제 값으로
   교체 (`app_id`, `bundle.sha256`, `contracts[].address`)
2. `templates/publish/bundle-hash.sh <앱 폴더>` — 캐노니컬 bundle index
   sha256
3. `python3 templates/publish/validate-manifests.py` — 스키마 최종 검증
4. **법률 검토 통과 후** 공개 레지스트리 제출 (`docs/legal-notes.md`)

## 안전과 비용의 원칙

- **F-01…F-08 회피**: 재진입·FoT 토큰·무코드 토큰·비례 뷰 순회·7702
  위임·단일 registrar 키·오픈 로그 오인·온체인 무작위성 — 전 예제가
  8클래스를 회피한다. 정의와 체크리스트: `docs/safety-checklist.md`
- **유료 상태 최소 설계**: EastSea는 상태가 유료다(슬롯 ≈100u, 로그
  ≈5u). 문자열은 로그에, 완결은 delete, 통계는 이벤트 스캔 —
  `docs/paid-state-design.md`
- **수익·가격 약속 없음, 코인 추천 리워드 없음** — 전 예제 공통.

## CI

`.github/workflows/ci.yml` — `forge fmt --check` + `FOUNDRY_PROFILE=ci`
(fuzz 1,000 runs) 테스트 + manifest 검증. 로컬 심층은 5,000 runs.

## 라이선스·책임

예제 코드는 MIT. **감사를 받은 적 없다** — 제품화 전 자체 감사·외부
감사를 거쳐라. 법률 검토 없는 공개 배포는 금지다.
