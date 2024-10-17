// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@oasisprotocol/sapphire-contracts/contracts/Sapphire.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import "./BitcoinAbstractWallet.sol";
import "../../../../RotatingKeys.sol";
import "./PeggedBTC.sol";
import "./IVaultBitcoinWalletHook.sol";
import "./OutgoingQueue.sol";

import "../AllowedRelayers.sol";

import "./tx-serializer/factories/TxSerializerFactory.sol";
import "./tx-serializer/factories/RefuelTxSerializerFactory.sol";
import "./tx-serializer/factories/RefundTxSerializerFactory.sol";

import "../../../../IComplianceManager.sol";

contract VaultBitcoinWallet is
BitcoinAbstractWallet,
RotatingKeys,
Ownable,
ITxInputsStorage,
ITxSecretsStorage,
AllowedRelayers
{
    using Buffer for Buffer.BufferIO;

    enum VaultTransactionType {
        Deposit,
        Outbound,
        Refund
    }

    struct OutboundTransaction {
        bytes32 finalisedCandidateHash;

        // Original transaction. Will be the same if no refuel submitted
        bytes32 txHash;

        uint256 changeOutputIdx;
        uint256 changeSystemIdx;
        uint64 changeExpectedValue;

        // Refuel candidates are potential transactions that can replace the original one
        // In case if original is stuck due to fees spike we can add a refuel candidate
        // NOTE: When refueling we can't change initial UTXO structure, only add 1 extra input with extra BTC for fees
        mapping(bytes32 => bool) refuelCandidatesHashes;
    }

    struct Refund {
        bool exists;

        address refundOwner;
        RefundTxSerializer[] serializers;
    }

    event SignedTxBroadcast(bytes32 indexed txHash, uint256 indexed id, bytes tx);
    event RefuelTxBroadcast(bytes32 indexed txHash, bytes32 indexed refuelingTxHash, bytes tx);
    event RefuelTxStarted(uint256 indexed originalOutgoingTxId, uint256 refuelTxId);

    event RefundInitiated(bytes32 indexed inputId, uint256 refundSeqId);
    event RefundTxBroadcast(bytes32 indexed inputId, bytes32 indexed refundtTxHash, bytes tx);

    event UpdateFeeSetter(address indexed prevSetter, address indexed newSetter);
    event UpdateMinWithdrawalLimit(uint256 newLimit);
    event FeeSet(uint64 satoshiPerByte);

    event ComplianceRecordLog(bytes vaultScriptHash, bytes32 recordId);
    event ChangeComplianceManager(address oldManager, address newManager);

    string public constant RECORD_TYPE = "BTC_DEPOSIT";

    BitcoinUtils.WorkingScriptSet public workingScriptSet;

    bytes[] public offchainSignerPubKeys;
    mapping(bytes32 => uint256) private _inputKeyImageToOffchainSignerPubKeyIndex;
    mapping(uint256 => uint256) private _changeSystemIdxToOffchainPubKeyIndex;

    mapping(bytes32 => Refund) private _refunds;

    bytes1 public constant TYPE_ADDR_P2SH = 0x05;
    bytes1 public constant TYPE_ADDR_P2SH_TESTNET = 0xC4;

    PeggedBTC public immutable btcToken;

    // BTC network fees
    uint16 public constant BYTES_PER_OUTGOING_TRANSFER = 30 + 250;
    uint16 public constant BYTES_PER_INCOMING_TRANSFER = 250;

    // To cover change output importing fee, tx headers and etc
    uint16 public constant INPUT_EXTRA_FIXED_BYTES_FEE = 300 + 30;

    address public constant REFUEL_VAULT_ADDRESS = address(1);

    uint64 public satoshiPerByte;
    address public feeSetter;

    OutgoingQueue public immutable queue;

    mapping(address => bool) public hooks;
    mapping(bytes32 => bytes32) internal _secrets;
    mapping(bytes32 => bool) internal _isRefuelInputSecret;

    uint256 public outboundTransactionsCount;
    mapping(uint256 => OutboundTransaction) public outboundTransactions;
    mapping(bytes32 => uint256) private _outboundTxHashToId;

    mapping(uint256 => TxSerializer) private _serializers;
    mapping(uint256 => RefuelTxSerializer[]) private _refuelSerializers;

    uint256 public changeSecretCounter = 0;
    bytes32 private _changeSecretDerivationRoot;

    bytes32[] internal _changeWalletsSecrets;

    // Protocol fees
    uint8 public constant MAX_DEPOSIT_FEE = 10;
    uint8 public constant MAX_WITHDRAWAL_FEE = 10;
    uint64 public constant MAX_DEPOSIT_FIXED_FEE = 7400;
    uint64 public constant MAX_WITHDRAWAL_FIXED_FEE = 7400;

    uint64 public depositFixedFee;
    uint64 public withdrawalFixedFee;
    uint8 public depositFee = 1;
    uint8 public withdrawalFee = 1;

    mapping(address => bool) public isExcludedFromFees;

    event ProtocolFeesUpdate(uint8 depositFee, uint8 withdrawalFee, uint64 depositFixedFee, uint64 withdrawalFixedFee);
    event OffchainSignerPubKeyUpdate(bytes pubKey);

    uint64 public minWithdrawalLimit = 700;

    TxSerializerFactory public immutable serializerFactory;
    RefuelTxSerializerFactory public immutable refuelSerializerFactory;
    RefundTxSerializerFactory public immutable refundSerializerFactory;

    IComplianceManager public complianceManager;

    constructor(
        address _prover,
        bytes memory _offchainSigner,
        BitcoinUtils.WorkingScriptSet memory _loadScripts,
        address _queue,
        TxSerializerFactory _serializerFactory,
        RefuelTxSerializerFactory _refuelSerializerFactory,
        RefundTxSerializerFactory _refundSerializerFactory,
        IComplianceManager _cm
    )
    BitcoinAbstractWallet(_prover)
    RotatingKeys(keccak256(abi.encodePacked(block.number)), type(VaultBitcoinWallet).name)
    AllowedRelayers(address(0))
    {
        btcToken = new PeggedBTC();
        queue = OutgoingQueue(_queue);

        workingScriptSet = _loadScripts;

        IScript[] memory _scripts = new IScript[](3);
        _scripts[0] = workingScriptSet.vaultScript;
        _scripts[1] = workingScriptSet.p2pkhScript;
        _scripts[2] = workingScriptSet.p2shScript;

        _setSupportedScripts(_scripts);
        _updateOffchainSignerPubKey(_offchainSigner);

        feeSetter = msg.sender;

        serializerFactory = _serializerFactory;
        refuelSerializerFactory = _refuelSerializerFactory;
        refundSerializerFactory = _refundSerializerFactory;
        complianceManager = _cm;
    }

    modifier onlyAuthorisedSerializer() {
        require(
            serializerFactory.isDeployedSerializer(msg.sender)
            ||
            refuelSerializerFactory.isDeployedSerializer(msg.sender)
            ||
            refundSerializerFactory.isDeployedSerializer(msg.sender),
            "Not a serializer");
        _;
    }

    function setComplianceManager(address _newCm) public onlyOwner {
        emit ChangeComplianceManager(address(complianceManager), _newCm);
        complianceManager = IComplianceManager(_newCm);
    }

    function setProtocolFees(
        uint8 _depositFee,
        uint8 _withdrawalFee,
        uint64 _depFixedFee,
        uint64 _withdrawFixedFee
    ) public onlyOwner {
        require(_depositFee <= MAX_DEPOSIT_FEE && _withdrawalFee <= MAX_WITHDRAWAL_FEE, "FTH");
        require(_depFixedFee <= MAX_DEPOSIT_FIXED_FEE && _withdrawalFee <= MAX_WITHDRAWAL_FIXED_FEE, "FFTH");

        emit ProtocolFeesUpdate(_depositFee, _withdrawalFee, _depFixedFee, _withdrawFixedFee);
        depositFee = _depositFee;
        withdrawalFee = _withdrawalFee;
        depositFixedFee = _depFixedFee;
        withdrawalFixedFee = _withdrawFixedFee;
    }

    function _getOffchainSignerPubKeyByInputId(bytes32 _inputId) private view returns (bytes memory) {
        uint256 _index = _inputKeyImageToOffchainSignerPubKeyIndex[inputs[_inputId].keyImage];
        return offchainSignerPubKeys[_index];
    }

    function _updateOffchainSignerPubKey(bytes memory newPubKey) private {
        emit OffchainSignerPubKeyUpdate(newPubKey);
        offchainSignerPubKeys.push(newPubKey);
    }

    function updateOffchainSignerPubKey(bytes memory newPubKey) public onlyOwner {
        _updateOffchainSignerPubKey(newPubKey);
    }

    function toggleFeesExclusion(address _user) public onlyOwner {
        isExcludedFromFees[_user] = !isExcludedFromFees[_user];
    }

    function setMinWithdrawalLimit(uint64 _newLimit) public onlyOwner {
        emit UpdateMinWithdrawalLimit(_newLimit);
        minWithdrawalLimit = _newLimit;
    }

    function setFeeSetter(address _newFeeSetter) public onlyOwner {
        emit UpdateFeeSetter(feeSetter, _newFeeSetter);
        feeSetter = _newFeeSetter;
    }

    function setFee(uint64 _satoshiPerByte) public {
        require(msg.sender == feeSetter);
        emit FeeSet(_satoshiPerByte);

        satoshiPerByte = _satoshiPerByte;
    }

    function spendInput(bytes32 inputId) public override onlyAuthorisedSerializer {
        if (!isRefundInput(inputId)) _spend(inputId);
    }

    function fetchInput(bytes32 inputId) public view override returns (
        uint64 value,
        bytes32 txHash,
        uint32 txOutIndex
    ) {
        InputMetadata memory _input = inputs[inputId];
        value = _input.value;
        txHash = _input.txHash;
        txOutIndex = uint32(_input.txOutIndex);
    }

    function fetchOffchainPubKey(bytes32 inputId) public override onlyAuthorisedSerializer view returns (bytes memory) {
        return _getOffchainSignerPubKeyByInputId(inputId);
    }

    function isRefuelInput(bytes32 inputId) public onlyAuthorisedSerializer override view returns (bool) {
        return _isRefuelInputSecret[inputs[inputId].keyImage];
    }

    function isRefundInput(bytes32 inputId) public onlyAuthorisedSerializer override view returns (bool) {
        return _refunds[inputId].exists;
    }

    function getKeyPair(bytes32 inputId) public onlyAuthorisedSerializer override view
    returns (bytes memory, bytes memory) {
        return _getKeyPairByKeyImage(inputId);
    }

    function deriveChangeInfo(bytes32 seed)
    public
    override onlyAuthorisedSerializer
    returns
    (uint256 _rChangeSystemIdx, bytes20 _changeScriptHash) {
        bytes32 _changeSecret = _deriveNextChangeSecret(seed);
        uint256 _offchainPubKeyIndex = offchainSignerPubKeys.length - 1;

        _rChangeSystemIdx = _changeWalletsSecrets.length;
        _changeScriptHash = _generateVaultScriptHashFromSecret(_offchainPubKeyIndex, _changeSecret);

        _changeSystemIdxToOffchainPubKeyIndex[_rChangeSystemIdx] = _offchainPubKeyIndex;

        changeSecretCounter++;
        _changeWalletsSecrets.push(_changeSecret);
    }

    function getLastDeployedSerializerAddress() public view returns (address) {
        return address(_serializers[outboundTransactionsCount]);
    }

    function getCurrentUnfinishedSerializer() public view returns (address) {
        address _lastDeployedSerializer = getLastDeployedSerializerAddress();
        if (_lastDeployedSerializer == address(0)) {
            return address(0);
        }

        if (TxSerializer(_lastDeployedSerializer).isFinished()) {
            return address(0);
        }

        return _lastDeployedSerializer;
    }

    function _deriveNextChangeSecret(bytes32 _seed) private view returns (bytes32) {
        return keccak256(abi.encodePacked(
            _seed,
            keccak256(abi.encodePacked(_changeSecretDerivationRoot, changeSecretCounter))
        ));
    }

    function _generateVaultScriptFromSecret(uint256 _offchainPubKeyIndex, bytes32 _secret) private view returns (bytes memory) {
        (bytes memory pubKey,) = Sapphire.generateSigningKeyPair(
            Sapphire.SigningAlg.Secp256k1PrehashedSha256,
            abi.encodePacked(_secret)
        );

        bytes20 contractSignerPubKeyHash = BitcoinUtils.hash160(pubKey);
        return workingScriptSet.vaultScript.serialize(abi.encode(
            contractSignerPubKeyHash, offchainSignerPubKeys[_offchainPubKeyIndex]
        ));
    }

    function _generateVaultScriptHashFromSecret(uint256 _offchainPubKeyIndex, bytes32 _secret) private view returns (bytes20) {
        return BitcoinUtils.hash160(_generateVaultScriptFromSecret(_offchainPubKeyIndex, _secret));
    }

    function _getKeyPairByKeyImage(bytes32 _inputId) private view returns (bytes memory, bytes memory) {
        InputMetadata memory _inputData = inputs[_inputId];
        return Sapphire.generateSigningKeyPair(
            Sapphire.SigningAlg.Secp256k1PrehashedSha256,
            abi.encodePacked(_secrets[_inputData.keyImage])
        );
    }

    function startRefundTxSerializing(bytes32 inputId, bytes memory inst, uint64 userSatoshiPerByte) public {
        Refund storage _refund = _refunds[inputId];
        require(_refund.exists, "NE");

        (bytes memory to, bytes memory sig) = abi.decode(inst, (bytes, bytes));
        (uint8 v, bytes32 r, bytes32 s) = abi.decode(sig, (uint8, bytes32, bytes32));

        bytes32 _hash = keccak256(abi.encodePacked(inputId, to, userSatoshiPerByte));
        require(ecrecover(_hash, v, r, s) == _refund.refundOwner, "NO");

        RefundTxSerializer _sr = refundSerializerFactory.createRefundSerializer(
            _getFees(userSatoshiPerByte),
            inputId,
            BitcoinUtils.resolveLockingScript(to, _isTestnet(), workingScriptSet)
        );

        _sr.init();

        _refund.serializers.push(_sr);
        emit RefundInitiated(inputId, _refund.serializers.length - 1);
    }

    function finaliseRefundTxSerializing(bytes32 inputId, uint256 seqId, bytes memory signature) public {
        Refund storage _refund = _refunds[inputId];
        require(_refund.exists, "NE");

        RefundTxSerializer _sr = _refund.serializers[seqId];
        require(!_sr.isFinished(), "IF");

        _sr.finalise(signature);

        (bytes memory txData, bytes32 txHash) = _sr.getRaw();
        emit RefundTxBroadcast(inputId, txHash, txData);
    }

    function _getOutboundTx(bytes32 outgoingTxHash) private view returns (uint256, OutboundTransaction storage) {
        uint256 _index = _outboundTxHashToId[outgoingTxHash];

        OutboundTransaction storage outboundTx = outboundTransactions[_index];
        require(outboundTx.txHash != bytes32(0) && outboundTx.finalisedCandidateHash == bytes32(0), "UOT");

        return (_index, outboundTx);
    }

    function startRefuelTxSerializing(bytes32 outgoingTxHash) public onlyRelayer {
        (uint256 _index,) = _getOutboundTx(outgoingTxHash);

        RefuelTxSerializer _sr = refuelSerializerFactory.createRefuelSerializer(_serializers[_index]);
        _refuelSerializers[_index].push(_sr);
        emit RefuelTxStarted(_index, _refuelSerializers[_index].length - 1);
    }

    function finaliseRefuelTxSerializing(bytes32 outgoingTxHash, uint256 refuelTxId) public onlyRelayer {
        (uint256 _index, OutboundTransaction storage outboundTx) = _getOutboundTx(outgoingTxHash);

        RefuelTxSerializer _sr = _refuelSerializers[_index][refuelTxId];

        (bytes memory txData, bytes32 txHash) = _sr.getRaw();
        emit RefuelTxBroadcast(txHash, outgoingTxHash, txData);

        require(!outboundTx.refuelCandidatesHashes[txHash], "AA");

        outboundTx.refuelCandidatesHashes[txHash] = true;
        _outboundTxHashToId[txHash] = _index;
    }

    function _getFees(uint64 _satoshiPerByte) internal pure returns (AbstractTxSerializer.FeeConfig memory) {
        return AbstractTxSerializer.FeeConfig({
            outgoingTransferCost: BYTES_PER_OUTGOING_TRANSFER * _satoshiPerByte,
            incomingTransferCost: BYTES_PER_INCOMING_TRANSFER * _satoshiPerByte
        });
    }

    function startOutgoingTxSerializing() public onlyRelayer {
        uint256 _index = outboundTransactionsCount;
        require(address(_serializers[_index]) == address(0), "AC");

        bytes32 sliceIndex = queue.popBufferedTransfersToBatch();

        TxSerializer _sr = serializerFactory.createSerializer(
            _getFees(satoshiPerByte),
            address(queue),
            sliceIndex
        );

        queue.registerWalker(address(_sr));

        _serializers[_index] = _sr;
    }

    function finaliseOutgoingTxSerializing() public onlyRelayer {
        uint256 _index = outboundTransactionsCount++;
        TxSerializer _sr = _serializers[_index];

        (bytes memory txData, bytes32 txHash) = _sr.getRaw();

        emit SignedTxBroadcast(txHash, _index, txData);

        (uint256 _changeSystemIdx, uint64 _changeValue, uint256 _changeIdx) = _sr.getChangeInfo();
        _addOutboundTransaction(
            _index,
            txHash,
            _changeIdx,
            _changeSystemIdx,
            _changeValue
        );
    }

    function _addOutboundTransaction(
        uint256 _index,
        bytes32 _txHash,
        uint256 _changeIdx,
        uint256 _changeSystemIdx,
        uint64 _changeValue
    ) private {
        OutboundTransaction storage _outTx = outboundTransactions[_index];

        _outTx.txHash = _txHash;

        _outTx.changeExpectedValue = _changeValue;
        _outTx.changeOutputIdx = _changeIdx;
        _outTx.changeSystemIdx = _changeSystemIdx;

        _outboundTxHashToId[_txHash] = _index;
    }

    function enableHooks(address[] memory _hooks) public onlyOwner {
        for (uint i = 0; i < _hooks.length; i++) {
            hooks[_hooks[i]] = true;
        }
    }

    function _isTestnet() internal virtual view returns (bool) {
        IBitcoinNetwork.ChainParams memory _params = IBitcoinNetwork(prover).chainParams();
        return _params.isTestnet;
    }

    function withdraw(bytes memory to, uint64 amount, uint64 minReceiveAmount, bytes32 idSeed) public {
        uint64 amountAfterNetworkFee = amount - (BYTES_PER_OUTGOING_TRANSFER * satoshiPerByte);
        require(amountAfterNetworkFee >= minWithdrawalLimit, "AFL");

        uint64 protocolFees = (amountAfterNetworkFee * withdrawalFee / 1000) + withdrawalFixedFee;
        if (isExcludedFromFees[msg.sender]) {
            protocolFees = 0;
        }

        uint64 amountAfterFee = amountAfterNetworkFee - protocolFees;
        require(amountAfterFee >= minReceiveAmount, "FTH");

        btcToken.burn(msg.sender, amount);
        if (protocolFees > 0) {
            btcToken.mint(owner(), protocolFees);
        }

        bytes32 _transferId = keccak256(abi.encodePacked(idSeed, to, amount));
        queue.push(
            OutgoingQueue.OutgoingTransfer(
                BitcoinUtils.resolveLockingScript(to, _isTestnet(), workingScriptSet),
                amountAfterFee,
                _transferId
            )
        );
    }

    function getAddressByOrderRecoveryData(bytes memory _recoveryData) public view returns (bytes memory btcAddr) {
        (uint256 _keyIndex, bytes memory _encryptedRecoveryData) = abi.decode(_recoveryData, (uint256, bytes));
        bytes memory recoveryData = _decryptPayload(_keyIndex, _encryptedRecoveryData);

        (uint256 _offchainPubKeyIndex,,,) = abi.decode(
            recoveryData,
            (uint256, bytes32, address, bytes)
        );

        bytes20 _scriptHash = _keyDataToScriptHash(_offchainPubKeyIndex, _keyIndex, keccak256(recoveryData));
        btcAddr = _generateAddress(_scriptHash, _isTestnet() ? TYPE_ADDR_P2SH_TESTNET : TYPE_ADDR_P2SH);
    }

    function _random(bytes32 _entropy) internal virtual view returns (bytes32) {
        return bytes32(Sapphire.randomBytes(32, abi.encodePacked(_entropy)));
    }

    function _updateKey(bytes32 _entropy) internal virtual {
        _updateRingKey(_entropy);
    }

    function generateOrder(
        address to,
        bytes memory _data,
        bytes32 _entropy
    ) public view returns (bytes memory orderData, bytes memory btcAddr) {
        uint256 _keyIndex = _ringKeys.length - 1;
        uint256 _offchainPubKeyIndex = offchainSignerPubKeys.length - 1;

        bytes32 userSeed = _random(_entropy);
        bytes memory recoveryData = abi.encode(_offchainPubKeyIndex, userSeed, to, _data);

        bytes20 _scriptHash = _keyDataToScriptHash(_offchainPubKeyIndex, _keyIndex, keccak256(recoveryData));

        (bytes memory _encryptedOrder,) = _encryptPayload(recoveryData);

        orderData = abi.encode(_keyIndex, _encryptedOrder);
        btcAddr = _generateAddress(_scriptHash, _isTestnet() ? TYPE_ADDR_P2SH_TESTNET : TYPE_ADDR_P2SH);
    }

    function _getKeyPairSeed(uint256 _keyIndex, bytes32 _userSeed) private view returns (bytes32) {
        return keccak256(abi.encodePacked(_ringKeys[_keyIndex], _userSeed));
    }

    function _keyDataToScriptHash(uint256 _offchainPubKeyIndex, uint256 _keyIndex, bytes32 _userSeed) internal view returns (bytes20) {
        return _generateVaultScriptHashFromSecret(_offchainPubKeyIndex, _getKeyPairSeed(_keyIndex, _userSeed));
    }

    function _ensureValidBtcReceiver(bytes memory _vaultScriptHash, bytes memory _recoveryData) private view returns (
        uint256,
        bytes memory,
        address,
        bytes memory,
        uint256
    ) {
        (uint256 _keyIndex, bytes memory _encryptedRecoveryData) = abi.decode(_recoveryData, (uint256, bytes));
        bytes memory recoveryData = _decryptPayload(_keyIndex, _encryptedRecoveryData);

        (uint256 offchainPubKeyIndex,, address destination, bytes memory data) = abi.decode(
            recoveryData,
            (uint256, bytes32, address, bytes)
        );

        require(bytes20(_vaultScriptHash) == _keyDataToScriptHash(offchainPubKeyIndex, _keyIndex, keccak256(recoveryData)), "IR");

        return (_keyIndex, recoveryData, destination, data, offchainPubKeyIndex);
    }

    function _onActionDeposit(
        uint64 value,
        bytes memory _vaultScriptHash,
        bytes memory _recoveryData
    ) internal returns (bytes32) {
        (
            uint256 _keyIndex,
            bytes memory recoveryData,
            address destination,
            bytes memory data,
            uint256 offchainPubKeyIndex
        ) = _ensureValidBtcReceiver(_vaultScriptHash, _recoveryData);

        if (_changeSecretDerivationRoot == bytes32(0)) {
            _changeSecretDerivationRoot = _random(keccak256(
                abi.encodePacked(
                    value, _vaultScriptHash, _recoveryData, block.number
                )
            ));
        }

        if (address(complianceManager) != address(0)) {
            bytes memory _complianceData = abi.encode(destination, data);
            emit ComplianceRecordLog(_vaultScriptHash, complianceManager.pushRecord(RECORD_TYPE, _complianceData));
        }

        uint64 protocolFees = value * depositFee / 1000;
        if (isExcludedFromFees[destination]) {
            protocolFees = 0;
        }

        protocolFees += depositFixedFee;

        uint64 importFees = ((BYTES_PER_INCOMING_TRANSFER + INPUT_EXTRA_FIXED_BYTES_FEE) * satoshiPerByte);
        protocolFees += importFees;

        uint64 valueAfterFees = value - protocolFees;

        btcToken.mint(destination, valueAfterFees);
        if ((protocolFees - importFees) > 0 && destination != REFUEL_VAULT_ADDRESS) {
            btcToken.mint(owner(), protocolFees - importFees);
        }

        if (hooks[destination] && destination != REFUEL_VAULT_ADDRESS) {
            IVaultBitcoinWalletHook(destination).hook(valueAfterFees, data);
        }

        bytes32 _secret = _getKeyPairSeed(_keyIndex, keccak256(recoveryData));
        bytes32 _keyImage = keccak256(abi.encodePacked(_secret));
        _secrets[_keyImage] = _secret;

        if (destination == REFUEL_VAULT_ADDRESS) {
            _isRefuelInputSecret[_keyImage] = true;
        }

        _inputKeyImageToOffchainSignerPubKeyIndex[_keyImage] = offchainPubKeyIndex;

        _updateKey(keccak256(abi.encodePacked(
            value,
            _vaultScriptHash,
            _recoveryData,
            block.number
        )));

        return _keyImage;
    }

    function _onActionOutbound(
        uint64 value,
        bytes memory _vaultScriptHash,
        Transaction memory _tx
    ) private returns (bytes32) {
        uint256 _index = _outboundTxHashToId[_tx.txHash];
        OutboundTransaction storage _currentOutbound = outboundTransactions[_index];
        require(_currentOutbound.txHash != bytes32(0) && _currentOutbound.finalisedCandidateHash == bytes32(0), "IC");

        bytes32 _changeSecret = _changeWalletsSecrets[_currentOutbound.changeSystemIdx];
        bytes20 changeScriptHash = _generateVaultScriptHashFromSecret(
            _changeSystemIdxToOffchainPubKeyIndex[_currentOutbound.changeSystemIdx],
            _changeSecret
        );

        require(bytes20(_vaultScriptHash) == changeScriptHash, "IH");
        require(_tx.txOutIndex == _currentOutbound.changeOutputIdx, "IOI");
        require(value == _currentOutbound.changeExpectedValue, "ICV");

        _currentOutbound.finalisedCandidateHash = _tx.txHash;

        bytes32 _keyImage = keccak256(abi.encodePacked(_changeSecret));
        _secrets[_keyImage] = _changeSecret;

        return _keyImage;
    }

    function _onActionRefund(
        bytes memory _vaultScriptHash,
        bytes memory _recoveryData,
        Transaction memory _tx
    ) private returns (bytes32) {
        (
            uint256 _keyIndex,
            bytes memory recoveryData,
            address destination,
            bytes memory data,
        ) = _ensureValidBtcReceiver(_vaultScriptHash, _recoveryData);

        bytes32 _inputId = _inputHash(_tx.txHash, _tx.txOutIndex);
        if (hooks[destination]) {
            destination = IVaultBitcoinWalletHook(destination).resolveOriginalAddress(data);
        }

        _refunds[_inputId] = Refund(true, destination, new RefundTxSerializer[](0));

        bytes32 _secret = _getKeyPairSeed(_keyIndex, keccak256(recoveryData));
        bytes32 _keyImage = keccak256(abi.encodePacked(_secret));
        _secrets[_keyImage] = _secret;

        return _keyImage;
    }

    function _onDeposit(
        bytes4 scriptId,
        uint64 value,
        bytes memory _vaultScriptHash,
        bytes memory _recoveryData,
        Transaction memory _tx
    ) internal virtual override returns (bool, bytes32) {
        require(scriptId == bytes4(keccak256(abi.encodePacked(type(ScriptP2SH).name))), "IS");

        (VaultTransactionType _type, bytes memory _data) = abi.decode(_recoveryData, (VaultTransactionType, bytes));

        if (_type == VaultTransactionType.Deposit) {
            return (true, _onActionDeposit(value, _vaultScriptHash, _data));
        } else if (_type == VaultTransactionType.Outbound) {
            return (true, _onActionOutbound(value, _vaultScriptHash, _tx));
        } else if (_type == VaultTransactionType.Refund) {
            return (false, _onActionRefund(_vaultScriptHash, _data, _tx));
        } else {
            revert("IAT");
        }
    }
}
