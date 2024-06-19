// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "../../../Endian.sol";
import "./BitcoinUtils.sol";

library BitcoinMerkleTree {
    struct ProofNode {
        bool isLeft;
        bytes32 data;
    }

    function verifyMerkleTreeInclusion(bytes32 leaf, ProofNode[] memory proof, bytes32 root) internal pure returns (bool) {
        bytes32 _hash = leaf;
        for (uint i = 0; i < proof.length; i++) {
            bytes32[] memory _buffers = new bytes32[](2);
            if (proof[i].isLeft) {
                _buffers[0] = bytes32(Endian.reverse256(uint256(proof[i].data)));
                _buffers[1] = bytes32(Endian.reverse256(uint256(_hash)));
            } else {
                _buffers[1] = bytes32(Endian.reverse256(uint256(proof[i].data)));
                _buffers[0] = bytes32(Endian.reverse256(uint256(_hash)));
            }

            _hash = BitcoinUtils.doubleSha256(abi.encodePacked(_buffers[0], _buffers[1]));
        }

        return _hash == root;
    }
}
