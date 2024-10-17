// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "../interfaces/IBitcoinDepositProcessingCallback.sol";

import "./scripts/IScript.sol";
import "../interfaces/IBitcoinNetwork.sol";

abstract contract BitcoinAbstractWallet is IBitcoinDepositProcessingCallback {
    struct InputMetadata {
        bool recorded;
        bool spendable;

        bytes32 txHash;
        uint256 txOutIndex;
        bytes32 keyImage;
        uint64 value;
    }

    address public immutable prover;

    IScript[] public scripts;

    mapping(bytes32 => InputMetadata) public inputs;

    uint256 public unspentInputsCount;

    event Deposit(bytes32 indexed inputHash, uint64 value, bytes32 indexed keyImage);
    event Spent(bytes32 indexed inputHash);

    constructor(address _prover) {
        prover = _prover;
    }

    function _setSupportedScripts(IScript[] memory _scripts) internal {
        scripts = _scripts;
    }

    function _inputHash(bytes32 txHash, uint256 txOutIndex) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(txHash, txOutIndex));
    }

    function _onDeposit(
        bytes4 scriptId,
        uint64 value,
        bytes memory to,
        bytes memory recoveryData,
        Transaction memory _tx
    ) internal virtual returns (bool, bytes32);

    // NOTE: Data for Base58 encoding on the frontend side
    function _generateAddress(bytes20 _dstHash, bytes1 _type) internal pure returns (bytes memory) {
        bytes memory addressData = bytes.concat(_dstHash);
        bytes32 checksum = bytes32(
            Endian.reverse256(
                uint256(BitcoinUtils.doubleSha256(abi.encodePacked(_type, addressData)))
            )
        );

        return abi.encodePacked(_type, addressData, bytes4(checksum));
    }

    function _spend(bytes32 _input) internal {
        InputMetadata storage input = inputs[_input];
        require(input.recorded, "INT");
        require(input.spendable, "IBS");

        input.spendable = false;
        emit Spent(_input);
    }

    function _processDeposit(Transaction memory _tx, bytes memory _data) internal {
        bytes memory btcAddress = new bytes(0);
        bytes4 _scriptId = bytes4(0);
        for (uint i = 0; i < scripts.length; i++) {
            btcAddress = scripts[i].deserialize(_tx.transaction.script);
            _scriptId = scripts[i].id();
            if (btcAddress.length > 0) {
                break;
            }
        }

        require(btcAddress.length > 0, "UIS");
        (bool isGlobal, bytes32 _keyImage) = _onDeposit(_scriptId, _tx.transaction.value, btcAddress, _data, _tx);

        bytes32 inputHash = _inputHash(_tx.txHash, _tx.txOutIndex);

        require(!inputs[inputHash].recorded, "IAA");
        inputs[inputHash] = InputMetadata(true, true, _tx.txHash, _tx.txOutIndex, _keyImage, _tx.transaction.value);

        if (isGlobal) {
            unspentInputsCount++;
            emit Deposit(inputHash, _tx.transaction.value, _keyImage);
        }
    }

    function processDeposit(
        Transaction memory _tx,
        bytes memory _data
    ) public override {
        require(msg.sender == prover);
        _processDeposit(_tx, _data);
    }
}
