pragma solidity 0.4.24;

import "../BasicForeignBridge.sol";
import "../ERC20Bridge.sol";
import "../OtherSideBridgeStorage.sol";
import "../ChaiConnector.sol";
import "../GSNForeignERC20Bridge.sol";

contract ForeignBridgeErcToNative is OtherSideBridgeStorage, ChaiConnector, GSNForeignERC20Bridge {
    function initialize(
        address _validatorContract,
        address _erc20token,
        uint256 _requiredBlockConfirmations,
        uint256 _gasPrice,
        uint256[3] _dailyLimitMaxPerTxMinPerTxArray, // [ 0 = _dailyLimit, 1 = _maxPerTx, 2 = _minPerTx ]
        uint256[2] _homeDailyLimitHomeMaxPerTxArray, //[ 0 = _homeDailyLimit, 1 = _homeMaxPerTx ]
        address _owner,
        int256 _decimalShift,
        address _bridgeOnOtherSide
    ) external onlyRelevantSender returns (bool) {
        require(!isInitialized());
        require(AddressUtils.isContract(_validatorContract));

        addressStorage[VALIDATOR_CONTRACT] = _validatorContract;
        setErc20token(_erc20token);
        uintStorage[DEPLOYED_AT_BLOCK] = block.number;
        _setRequiredBlockConfirmations(_requiredBlockConfirmations);
        _setGasPrice(_gasPrice);
        _setLimits(_dailyLimitMaxPerTxMinPerTxArray);
        _setExecutionLimits(_homeDailyLimitHomeMaxPerTxArray);
        _setDecimalShift(_decimalShift);
        _setOwner(_owner);
        _setBridgeContractOnOtherSide(_bridgeOnOtherSide);
        setInitialize();

        return isInitialized();
    }

    function getBridgeMode() external pure returns (bytes4 _data) {
        return 0x18762d46; // bytes4(keccak256(abi.encodePacked("erc-to-native-core")))
    }

    /**
     * @dev Withdraws the erc20 tokens or native coins from this contract.
     * @param _token address of the claimed token or address(0) for native coins.
     * @param _to address of the tokens/coins receiver.
     */
    function claimTokens(address _token, address _to) external onlyIfUpgradeabilityOwner {
        // Since bridged tokens are locked at this contract, it is not allowed to claim them with the use of claimTokens function
        require(_token != address(erc20token()));
        // Chai token is not claimable if investing into Chai is enabled
        require(_token != address(chaiToken()) || !isChaiTokenEnabled());
        claimValues(_token, _to);
    }

    function onExecuteMessageGSN(address recipient, uint256 amount, uint256 fee) internal returns (bool) {
        addTotalExecutedPerDay(getCurrentDay(), amount);
        uint256 unshiftMaxFee = _unshiftValue(fee);
        uint256 unshiftLeft = _unshiftValue(amount - fee);

        ensureEnoughDai(unshiftMaxFee + unshiftLeft);

        // Send maxTokensFee to paymaster
        bool first = erc20token().transfer(addressStorage[PAYMASTER], unshiftMaxFee);

        // Send rest of tokens to user
        bool second = erc20token().transfer(recipient, unshiftLeft);

        return first && second;
    }

    function onExecuteMessage(
        address _recipient,
        uint256 _amount,
        bytes32 /*_txHash*/
    ) internal returns (bool) {
        addTotalExecutedPerDay(getCurrentDay(), _amount);
        uint256 amount = _unshiftValue(_amount);

        ensureEnoughDai(amount);

        bool res = erc20token().transfer(_recipient, amount);

        return res;
    }

    function ensureEnoughDai(uint256 amount) internal {
        uint256 currentBalance = tokenBalance(erc20token());

        // Convert part of Chai tokens back to DAI, if DAI balance is insufficient.
        // If Chai token is disabled, bridge will keep all funds directly in DAI token,
        // so it will have enough funds to cover any xDai => Dai transfer,
        // and currentBalance >= amount will always hold.
        if (currentBalance < amount) {
            _convertChaiToDai(amount.sub(currentBalance).add(minDaiTokenBalance()));
        }
    }

    function onFailedMessage(address, uint256, bytes32) internal {
        revert();
    }

    function tokenBalance(ERC20 _token) internal view returns (uint256) {
        return _token.balanceOf(address(this));
    }

    function relayTokens(address _receiver, uint256 _amount) external {
        require(_receiver != bridgeContractOnOtherSide());
        require(_receiver != address(0));
        require(_receiver != address(this));
        require(_amount > 0);
        require(withinLimit(_amount));

        addTotalSpentPerDay(getCurrentDay(), _amount);

        erc20token().transferFrom(msg.sender, address(this), _amount);
        emit UserRequestForAffirmation(_receiver, _amount);

        if (isDaiNeedsToBeInvested()) {
            convertDaiToChai();
        }
    }
}
