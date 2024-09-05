// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

interface IVaultBitcoinWalletHook {
    function hook(uint64 value, bytes memory data) external;
    function resolveOriginalAddress(bytes memory data) external view returns (address);
}
