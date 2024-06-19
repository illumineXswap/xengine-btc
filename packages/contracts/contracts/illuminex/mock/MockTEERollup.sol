// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "../TEERollup.sol";

contract MockTEERollup is TEERollup {
    function _compute(bytes calldata input) internal virtual override view returns (bytes memory) {
        (uint256 a, uint256 b) = abi.decode(input, (uint256, uint256));
        return abi.encode(a + b);
    }

    function setMinWitness(uint8 v) public {
        _setMinWitnessSignatures(v);
    }

    function setWitness(bytes[] calldata publicKeys) public {
        TEERollup.WitnessActivation[] memory _witness = new TEERollup.WitnessActivation[](publicKeys.length);
        for (uint i = 0; i < _witness.length; i++) {
            _witness[i].publicKey = publicKeys[i];
            _witness[i].isActive = true;
        }

        _setWitnessPublicKeys(_witness);
    }
}
