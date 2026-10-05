// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {VmSafe} from "forge-std/Vm.sol";

/// @notice EastSea 유료 상태(state fee) 근사 계량 유틸. docs/design/27-state-fee.md 참조.
/// @dev
///  체인 규칙: 새 계정 100 units, 새 슬롯 100 units, 코드 바이트 1 unit,
///  영속 바이트(tx envelope + receipt 128 + return/revert + 이벤트 프레이밍)는
///  ceil(bytes/32) units. 이벤트 1건당 프레이밍 64 + 토픽당 32 + data 바이트.
///  되돌리거나 set-then-cleared 슬롯은 새 슬롯으로 안 친다.
///
///  여기서 재는 것 (vm.startStateDiffRecording + vm.recordLogs + vm.lastFrameGas):
///   - gasUsed: callee 프레임 관점 실행 가스 (intrinsic/tx envelope 제외)
///   - newSlots: tracked 주소의 0 -> non-zero 슬롯 전이 수 (최종값 기준)
///   - clearedSlots: non-zero -> 0 슬롯 (새 슬롯 계량에서 제외되는 것들)
///   - newAccounts: 배포로 새로 생긴 계정 수
///   - codeBytes: 배포된 런타임 코드 바이트
///   - logBytes: 이벤트 계량 바이트 근사
///   - stateUnits: 100*(newSlots+newAccounts) + codeBytes + ceil(logBytes/32)
///  트랜잭션 봉투/영수증 바이트는 테스트 환경에서 잡을 수 없으므로 별도
///  항목으로 GAS.md 표에 명시한다 (128 + calldata/32 근사).
library StateMeter {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    struct Result {
        uint256 gasUsed;
        uint256 newSlots;
        uint256 clearedSlots;
        uint256 newAccounts;
        uint256 codeBytes;
        uint256 logBytes;
        uint256 stateUnits;
    }

    /// @dev tracked 주소들의 저장소만 집계한다. 측정 구간 안에 다른 상태 쓰기
    ///      (발신자 잔액 등)가 있으면 tracked에 넣지 않는 한 제외된다.
    ///      gasUsed는 gasleft 차이 근사다 (63/64 규칙, intrinsic gas 제외).
    function measureCall(address from, address[] memory tracked, address target, bytes memory data)
        internal
        returns (Result memory r)
    {
        return r = _measure(from, tracked, target, data, 0);
    }

    /// @dev payable 호출 계량 (msg.value 지정).
    function measureCallValue(address from, address[] memory tracked, address target, bytes memory data, uint256 value)
        internal
        returns (Result memory r)
    {
        return r = _measure(from, tracked, target, data, value);
    }

    function _measure(address from, address[] memory tracked, address target, bytes memory data, uint256 value)
        private
        returns (Result memory r)
    {
        vm.startStateDiffRecording();
        vm.recordLogs();
        uint256 g0 = gasleft();
        vm.prank(from);
        (bool ok, bytes memory ret) = target.call{value: value}(data);
        uint256 g1 = gasleft();
        VmSafe.AccountAccess[] memory diff = vm.stopAndReturnStateDiff();
        VmSafe.Log[] memory logs = vm.getRecordedLogs();
        if (!ok) assembly { revert(add(ret, 32), mload(ret)) }
        r.gasUsed = g0 - g1;
        _foldDiff(r, diff, tracked);
        r.logBytes = _logBytes(logs);
        r.stateUnits = 100 * (r.newSlots + r.newAccounts) + r.codeBytes + _ceil32(r.logBytes);
    }

    /// @dev 배포 계량. creationCode를 직접 실행하고 만들어진 계정을 결과로 돌려준다.
    ///      gasUsed는 gasleft 차이 근사다 (CREATE 프레임, intrinsic gas 제외).
    function measureDeploy(bytes memory creationCode) internal returns (address deployed, Result memory r) {
        vm.startStateDiffRecording();
        vm.recordLogs();
        uint256 g0 = gasleft();
        deployed = _deploy(creationCode);
        uint256 g1 = gasleft();
        VmSafe.AccountAccess[] memory diff = vm.stopAndReturnStateDiff();
        VmSafe.Log[] memory logs = vm.getRecordedLogs();
        r.gasUsed = g0 - g1;
        address[] memory self = new address[](1);
        self[0] = deployed;
        _foldDiff(r, diff, self);
        for (uint256 i; i < diff.length; i++) {
            if (diff[i].kind == VmSafe.AccountAccessKind.Create && diff[i].account == deployed) {
                r.newAccounts = 1;
                r.codeBytes = diff[i].deployedCode.length;
            }
        }
        r.logBytes = _logBytes(logs);
        r.stateUnits = 100 * (r.newSlots + r.newAccounts) + r.codeBytes + _ceil32(r.logBytes);
    }

    function _deploy(bytes memory code) private returns (address a) {
        assembly {
            a := create(0, add(code, 32), mload(code))
            if iszero(a) { revert(0, 0) }
        }
    }

    function _foldDiff(Result memory r, VmSafe.AccountAccess[] memory diff, address[] memory tracked) private {
        for (uint256 i; i < diff.length; i++) {
            VmSafe.AccountAccess memory aa = diff[i];
            if (aa.reverted) continue;
            for (uint256 j; j < aa.storageAccesses.length; j++) {
                VmSafe.StorageAccess memory sa = aa.storageAccesses[j];
                if (!sa.isWrite || sa.reverted) continue;
                if (!_contains(tracked, sa.account)) continue;
                if (sa.previousValue == 0 && sa.newValue != 0) r.newSlots++;
                else if (sa.previousValue != 0 && sa.newValue == 0) r.clearedSlots++;
            }
        }
    }

    function _logBytes(VmSafe.Log[] memory logs) private pure returns (uint256 b) {
        for (uint256 i; i < logs.length; i++) {
            b += 64 + logs[i].topics.length * 32 + logs[i].data.length;
        }
    }

    function _contains(address[] memory arr, address v) private pure returns (bool) {
        for (uint256 i; i < arr.length; i++) {
            if (arr[i] == v) return true;
        }
        return false;
    }

    function _ceil32(uint256 n) private pure returns (uint256) {
        return (n + 31) / 32;
    }
}
