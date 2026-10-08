// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {NUKEHook} from "../src/NUKEHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

/// @notice Offline CREATE2 salt search; never broadcasts or deploys a contract.
contract MineHook {
    error SaltNotFound();

    /// @param create2Deployer The actual factory address executing CREATE2.
    /// @param firstSalt Start of a bounded, resumable search range.
    function run(IPoolManager manager, address token, address create2Deployer, uint256 firstSalt, uint256 attempts)
        external
        pure
        returns (address predicted, bytes32 salt, bytes32 initCodeHash)
    {
        initCodeHash = keccak256(abi.encodePacked(type(NUKEHook).creationCode, abi.encode(manager, token)));
        for (uint256 i; i < attempts; ++i) {
            salt = bytes32(firstSalt + i);
            predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), create2Deployer, salt, initCodeHash))))
            );
            if (uint160(predicted) & 0x3fff == 0x20c4) return (predicted, salt, initCodeHash);
        }
        revert SaltNotFound();
    }
}
