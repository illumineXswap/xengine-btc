// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

interface IBitcoinNetwork {
    struct ChainParams {
        bytes1 networkID;
        bool isTestnet;
    }

    function chainParams() external view returns (ChainParams memory);
}
