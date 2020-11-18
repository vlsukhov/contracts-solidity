// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity 0.6.12;
import "../../ConverterVersion.sol";
import "../../interfaces/IConverter.sol";
import "../../interfaces/IConverterAnchor.sol";
import "../../interfaces/IConverterUpgrader.sol";
import "../../../token/interfaces/IDSToken.sol";
import "../../../utility/ContractRegistryClient.sol";
import "../../../utility/ReentrancyGuard.sol";
import "../../../utility/SafeMath.sol";
import "../../../utility/TokenHandler.sol";
import "../../../utility/TokenHolder.sol";
import "../../../utility/Math.sol";

/**
 * @dev This contract is a specialized version of the converter, which is
 * optimized for a liquidity pool that has 2 reserves with 50%/50% weights.
 */
contract StandardPoolConverter is
    ConverterVersion,
    IConverter,
    TokenHandler,
    TokenHolder,
    ContractRegistryClient,
    ReentrancyGuard
{
    using SafeMath for uint256;
    using Math for *;

    IERC20Token private constant ETH_RESERVE_ADDRESS = IERC20Token(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);
    uint256 private constant MAX_UINT128 = 2**128 - 1;
    uint256 private constant MAX_UINT112 = 2**112 - 1;
    uint256 private constant AVERAGE_RATE_PERIOD = 10 minutes;
    uint32 private constant PPM_RESOLUTION = 1000000;

    uint256 private __reserveBalances;
    IERC20Token[] private __reserveTokens;
    mapping(IERC20Token => uint256) private __reserveIds;

    IConverterAnchor public override anchor; // converter anchor contract
    uint32 public override maxConversionFee; // maximum conversion fee, represented in ppm, 0...1000000
    uint32 public override conversionFee; // current conversion fee, represented in ppm, 0...maxConversionFee

    // average rate details:
    // bits 0...111 represent the numerator of the rate between reserve token 0 and reserve token 1
    // bits 111...223 represent the denominator of the rate between reserve token 0 and reserve token 1
    // bits 224...255 represent the update-time of the rate between reserve token 0 and reserve token 1
    // where `numerator / denominator` gives the worth of one reserve token 0 in units of reserve token 1
    uint256 public averageRateInfo;

    /**
     * @dev triggered when the converter is activated
     *
     * @param _type        converter type
     * @param _anchor      converter anchor
     * @param _activated   true if the converter was activated, false if it was deactivated
     */
    event Activation(uint16 indexed _type, IConverterAnchor indexed _anchor, bool indexed _activated);

    /**
     * @dev triggered when a conversion between two tokens occurs
     *
     * @param _fromToken       source ERC20 token
     * @param _toToken         target ERC20 token
     * @param _trader          wallet that initiated the trade
     * @param _amount          input amount in units of the source token
     * @param _return          output amount minus conversion fee in units of the target token
     * @param _conversionFee   conversion fee in units of the target token
     */
    event Conversion(
        IERC20Token indexed _fromToken,
        IERC20Token indexed _toToken,
        address indexed _trader,
        uint256 _amount,
        uint256 _return,
        int256 _conversionFee
    );

    /**
     * @dev triggered when the rate between two tokens in the converter changes
     * note that the event might be dispatched for rate updates between any two tokens in the converter
     *
     * @param  _token1 address of the first token
     * @param  _token2 address of the second token
     * @param  _rateN  rate of 1 unit of `_token1` in `_token2` (numerator)
     * @param  _rateD  rate of 1 unit of `_token1` in `_token2` (denominator)
     */
    event TokenRateUpdate(IERC20Token indexed _token1, IERC20Token indexed _token2, uint256 _rateN, uint256 _rateD);

    /**
     * @dev triggered when the conversion fee is updated
     *
     * @param  _prevFee    previous fee percentage, represented in ppm
     * @param  _newFee     new fee percentage, represented in ppm
     */
    event ConversionFeeUpdate(uint32 _prevFee, uint32 _newFee);

    /**
     * @dev triggered after liquidity is added
     *
     * @param  _provider       liquidity provider
     * @param  _reserveToken   reserve token address
     * @param  _amount         reserve token amount
     * @param  _newBalance     reserve token new balance
     * @param  _newSupply      pool token new supply
     */
    event LiquidityAdded(
        address indexed _provider,
        IERC20Token indexed _reserveToken,
        uint256 _amount,
        uint256 _newBalance,
        uint256 _newSupply
    );

    /**
     * @dev triggered after liquidity is removed
     *
     * @param  _provider       liquidity provider
     * @param  _reserveToken   reserve token address
     * @param  _amount         reserve token amount
     * @param  _newBalance     reserve token new balance
     * @param  _newSupply      pool token new supply
     */
    event LiquidityRemoved(
        address indexed _provider,
        IERC20Token indexed _reserveToken,
        uint256 _amount,
        uint256 _newBalance,
        uint256 _newSupply
    );

    /**
     * @dev initializes a new StandardPoolConverter instance
     *
     * @param  _anchor             anchor governed by the converter
     * @param  _registry           address of a contract registry contract
     * @param  _maxConversionFee   maximum conversion fee, represented in ppm
     */
    constructor(
        IConverterAnchor _anchor,
        IContractRegistry _registry,
        uint32 _maxConversionFee
    ) public ContractRegistryClient(_registry) validAddress(address(_anchor)) validConversionFee(_maxConversionFee) {
        anchor = _anchor;
        maxConversionFee = _maxConversionFee;
    }

    // ensures that the converter is active
    modifier active() {
        _active();
        _;
    }

    // error message binary size optimization
    function _active() internal view {
        require(isActive(), "ERR_INACTIVE");
    }

    // ensures that the converter is not active
    modifier inactive() {
        _inactive();
        _;
    }

    // error message binary size optimization
    function _inactive() internal view {
        require(!isActive(), "ERR_ACTIVE");
    }

    // validates a reserve token address - verifies that the address belongs to one of the reserve tokens
    modifier validReserve(IERC20Token _address) {
        _validReserve(_address);
        _;
    }

    // error message binary size optimization
    function _validReserve(IERC20Token _address) internal view {
        require(__reserveIds[_address] != 0, "ERR_INVALID_RESERVE");
    }

    // validates conversion fee
    modifier validConversionFee(uint32 _conversionFee) {
        _validConversionFee(_conversionFee);
        _;
    }

    // error message binary size optimization
    function _validConversionFee(uint32 _conversionFee) internal pure {
        require(_conversionFee <= PPM_RESOLUTION, "ERR_INVALID_CONVERSION_FEE");
    }

    // validates reserve weight
    modifier validReserveWeight(uint32 _weight) {
        _validReserveWeight(_weight);
        _;
    }

    // error message binary size optimization
    function _validReserveWeight(uint32 _weight) internal pure {
        require(_weight == PPM_RESOLUTION / 2, "ERR_INVALID_RESERVE_WEIGHT");
    }

    /**
     * @dev returns the converter type
     *
     * @return see the converter types in the the main contract doc
     */
    function converterType() public pure override returns (uint16) {
        return 3;
    }

    /**
     * @dev deposits ether
     * can only be called if the converter has an ETH reserve
     */
    receive() external payable override validReserve(ETH_RESERVE_ADDRESS) {}

    /**
     * @dev withdraws ether
     * can only be called by the owner if the converter is inactive or by upgrader contract
     * can only be called after the upgrader contract has accepted the ownership of this contract
     * can only be called if the converter has an ETH reserve
     *
     * @param _to  address to send the ETH to
     */
    function withdrawETH(address payable _to) public override protected ownerOnly validReserve(ETH_RESERVE_ADDRESS) {
        address converterUpgrader = addressOf(CONVERTER_UPGRADER);

        // verify that the converter is inactive or that the owner is the upgrader contract
        require(!isActive() || owner == converterUpgrader, "ERR_ACCESS_DENIED");
        _to.transfer(address(this).balance);

        // sync the ETH reserve balance
        syncReserveBalance(ETH_RESERVE_ADDRESS);
    }

    /**
     * @dev checks whether or not the converter version is 28 or higher
     *
     * @return true, since the converter version is 28 or higher
     */
    function isV28OrHigher() public pure returns (bool) {
        return true;
    }

    /**
     * @dev returns true if the converter is active, false otherwise
     *
     * @return true if the converter is active, false otherwise
     */
    function isActive() public view virtual override returns (bool) {
        return anchor.owner() == address(this);
    }

    /**
     * @dev transfers the anchor ownership
     * the new owner needs to accept the transfer
     * can only be called by the converter upgrder while the upgrader is the owner
     * note that prior to version 28, you should use 'transferAnchorOwnership' instead
     *
     * @param _newOwner    new token owner
     */
    function transferAnchorOwnership(address _newOwner) public override ownerOnly only(CONVERTER_UPGRADER) {
        anchor.transferOwnership(_newOwner);
    }

    /**
     * @dev accepts ownership of the anchor after an ownership transfer
     * most converters are also activated as soon as they accept the anchor ownership
     * can only be called by the contract owner
     * note that prior to version 28, you should use 'acceptTokenOwnership' instead
     */
    function acceptAnchorOwnership() public virtual override ownerOnly {
        // verify the the converter has exactly two reserves
        require(reserveTokenCount() == 2, "ERR_INVALID_RESERVE_COUNT");
        anchor.acceptOwnership();
        syncReserveBalances();
        emit Activation(converterType(), anchor, true);
    }

    /**
     * @dev updates the current conversion fee
     * can only be called by the contract owner
     *
     * @param _conversionFee new conversion fee, represented in ppm
     */
    function setConversionFee(uint32 _conversionFee) public override ownerOnly {
        require(_conversionFee <= maxConversionFee, "ERR_INVALID_CONVERSION_FEE");
        emit ConversionFeeUpdate(conversionFee, _conversionFee);
        conversionFee = _conversionFee;
    }

    /**
     * @dev withdraws tokens held by the converter and sends them to an account
     * can only be called by the owner
     * note that reserve tokens can only be withdrawn by the owner while the converter is inactive
     * unless the owner is the converter upgrader contract
     *
     * @param _token   ERC20 token contract address
     * @param _to      account to receive the new amount
     * @param _amount  amount to withdraw
     */
    function withdrawTokens(
        IERC20Token _token,
        address _to,
        uint256 _amount
    ) public override(IConverter, TokenHolder) protected ownerOnly {
        address converterUpgrader = addressOf(CONVERTER_UPGRADER);
        uint256 reserveId = __reserveIds[_token];

        // if the token is not a reserve token, allow withdrawal
        // otherwise verify that the converter is inactive or that the owner is the upgrader contract
        require(reserveId == 0 || !isActive() || owner == converterUpgrader, "ERR_ACCESS_DENIED");
        super.withdrawTokens(_token, _to, _amount);

        // if the token is a reserve token, sync the reserve balance
        if (reserveId != 0) {
            syncReserveBalance(_token);
        }
    }

    /**
     * @dev upgrades the converter to the latest version
     * can only be called by the owner
     * note that the owner needs to call acceptOwnership on the new converter after the upgrade
     */
    function upgrade() public ownerOnly {
        IConverterUpgrader converterUpgrader = IConverterUpgrader(addressOf(CONVERTER_UPGRADER));

        // trigger de-activation event
        emit Activation(converterType(), anchor, false);

        transferOwnership(address(converterUpgrader));
        converterUpgrader.upgrade(version);
        acceptOwnership();
    }

    /**
     * @dev returns the number of reserve tokens
     * note that prior to version 17, you should use 'connectorTokenCount' instead
     *
     * @return number of reserve tokens
     */
    function reserveTokenCount() public view returns (uint16) {
        return uint16(__reserveTokens.length);
    }

    /**
     * @dev returns the array of reserve tokens
     *
     * @return array of reserve tokens
     */
    function reserveTokens() public view returns (IERC20Token[] memory) {
        return __reserveTokens;
    }

    /**
     * @dev defines a new reserve token for the converter
     * can only be called by the owner while the converter is inactive
     *
     * @param _token   address of the reserve token
     * @param _weight  reserve weight, represented in ppm, 1-1000000
     */
    function addReserve(IERC20Token _token, uint32 _weight)
        public
        virtual
        override
        ownerOnly
        inactive
        validAddress(address(_token))
        notThis(address(_token))
        validReserveWeight(_weight)
    {
        // validate input
        require(address(_token) != address(anchor) && __reserveIds[_token] == 0, "ERR_INVALID_RESERVE");
        require(reserveTokenCount() < 2, "ERR_INVALID_RESERVE_COUNT");

        __reserveTokens.push(_token);
        __reserveIds[_token] = __reserveTokens.length;
    }

    /**
     * @dev returns the reserve's weight
     * added in version 28
     *
     * @param _reserveToken    reserve token contract address
     *
     * @return reserve weight
     */
    function reserveWeight(IERC20Token _reserveToken) public view validReserve(_reserveToken) returns (uint32) {
        return PPM_RESOLUTION / 2;
    }

    /**
     * @dev returns the balance of a given reserve token
     *
     * @param _reserveToken    reserve token contract address
     *
     * @return the balance of the given reserve token
     */
    function reserveBalance(IERC20Token _reserveToken) public view override returns (uint256) {
        uint256 reserveId = __reserveIds[_reserveToken];
        require(reserveId != 0, "ERR_INVALID_RESERVE");
        return reserveBalance(reserveId);
    }

    /**
     * @dev returns the balances of both reserve tokens
     *
     * @return the balances of both reserve tokens
     */
    function reserveBalances() public view returns (uint256, uint256) {
        return reserveBalances(1, 2);
    }

    /**
     * @dev converts a specific amount of source tokens to target tokens
     * can only be called by the bancor network contract
     *
     * @param _sourceToken source ERC20 token
     * @param _targetToken target ERC20 token
     * @param _amount      amount of tokens to convert (in units of the source token)
     * @param _trader      address of the caller who executed the conversion
     * @param _beneficiary wallet to receive the conversion result
     *
     * @return amount of tokens received (in units of the target token)
     */
    function convert(
        IERC20Token _sourceToken,
        IERC20Token _targetToken,
        uint256 _amount,
        address _trader,
        address payable _beneficiary
    ) public payable override protected only(BANCOR_NETWORK) returns (uint256) {
        // validate input
        require(_sourceToken != _targetToken, "ERR_SAME_SOURCE_TARGET");

        return doConvert(_sourceToken, _targetToken, _amount, _trader, _beneficiary);
    }

    /**
     * @dev returns the conversion fee for a given target amount
     *
     * @param _targetAmount  target amount
     *
     * @return conversion fee
     */
    function calculateFee(uint256 _targetAmount) internal view returns (uint256) {
        return _targetAmount.mul(conversionFee) / PPM_RESOLUTION;
    }

    /**
     * @dev loads the stored reserve balance for a given reserve id
     *
     * @param _reserveId   reserve id
     */
    function reserveBalance(uint256 _reserveId) internal view returns (uint256) {
        return decodeReserveBalance(__reserveBalances, _reserveId);
    }

    /**
     * @dev loads the stored reserve balances
     *
     * @param _sourceId    source reserve id
     * @param _targetId    target reserve id
     */
    function reserveBalances(uint256 _sourceId, uint256 _targetId) internal view returns (uint256, uint256) {
        require((_sourceId == 1 && _targetId == 2) || (_sourceId == 2 && _targetId == 1), "ERR_INVALID_RESERVES");
        return decodeReserveBalances(__reserveBalances, _sourceId, _targetId);
    }

    /**
     * @dev stores the stored reserve balance for a given reserve id
     *
     * @param _reserveId       reserve id
     * @param _reserveBalance  reserve balance
     */
    function setReserveBalance(uint256 _reserveId, uint256 _reserveBalance) internal {
        require(_reserveBalance <= MAX_UINT128, "ERR_RESERVE_BALANCE_OVERFLOW");
        uint256 otherBalance = decodeReserveBalance(__reserveBalances, 3 - _reserveId);
        __reserveBalances = encodeReserveBalances(_reserveBalance, _reserveId, otherBalance, 3 - _reserveId);
    }

    /**
     * @dev stores the stored reserve balances
     *
     * @param _sourceId        source reserve id
     * @param _targetId        target reserve id
     * @param _sourceBalance   source reserve balance
     * @param _targetBalance   target reserve balance
     */
    function setReserveBalances(
        uint256 _sourceId,
        uint256 _targetId,
        uint256 _sourceBalance,
        uint256 _targetBalance
    ) internal {
        require(_sourceBalance <= MAX_UINT128 && _targetBalance <= MAX_UINT128, "ERR_RESERVE_BALANCE_OVERFLOW");
        __reserveBalances = encodeReserveBalances(_sourceBalance, _sourceId, _targetBalance, _targetId);
    }

    /**
     * @dev syncs the stored reserve balance for a given reserve with the real reserve balance
     *
     * @param _reserveToken    address of the reserve token
     */
    function syncReserveBalance(IERC20Token _reserveToken) internal {
        uint256 reserveId = __reserveIds[_reserveToken];
        uint256 balance = _reserveToken == ETH_RESERVE_ADDRESS
            ? address(this).balance
            : _reserveToken.balanceOf(address(this));
        setReserveBalance(reserveId, balance);
    }

    /**
     * @dev syncs all stored reserve balances
     */
    function syncReserveBalances() internal {
        IERC20Token _reserveToken0 = __reserveTokens[0];
        IERC20Token _reserveToken1 = __reserveTokens[1];
        uint256 balance0 = _reserveToken0 == ETH_RESERVE_ADDRESS
            ? address(this).balance
            : _reserveToken0.balanceOf(address(this));
        uint256 balance1 = _reserveToken1 == ETH_RESERVE_ADDRESS
            ? address(this).balance
            : _reserveToken1.balanceOf(address(this));
        setReserveBalances(1, 2, balance0, balance1);
    }

    /**
     * @dev syncs all stored reserve balances, excluding a given amount of ether from the ether reserve balance (if relevant)
     *
     * @param _value   amount of ether to exclude from the ether reserve balance (if relevant)
     */
    function syncReserveBalances(uint256 _value) internal {
        IERC20Token _reserveToken0 = __reserveTokens[0];
        IERC20Token _reserveToken1 = __reserveTokens[1];
        uint256 balance0 = _reserveToken0 == ETH_RESERVE_ADDRESS
            ? address(this).balance - _value
            : _reserveToken0.balanceOf(address(this));
        uint256 balance1 = _reserveToken1 == ETH_RESERVE_ADDRESS
            ? address(this).balance - _value
            : _reserveToken1.balanceOf(address(this));
        setReserveBalances(1, 2, balance0, balance1);
    }

    /**
     * @dev helper, dispatches the Conversion event
     *
     * @param _sourceToken     source ERC20 token
     * @param _targetToken     target ERC20 token
     * @param _trader          address of the caller who executed the conversion
     * @param _amount          amount purchased/sold (in the source token)
     * @param _returnAmount    amount returned (in the target token)
     */
    function dispatchConversionEvent(
        IERC20Token _sourceToken,
        IERC20Token _targetToken,
        address _trader,
        uint256 _amount,
        uint256 _returnAmount,
        uint256 _feeAmount
    ) internal {
        // fee amount is converted to 255 bits -
        // negative amount means the fee is taken from the source token, positive amount means its taken from the target token
        // currently the fee is always taken from the target token
        // since we convert it to a signed number, we first ensure that it's capped at 255 bits to prevent overflow
        assert(_feeAmount < 2**255);
        emit Conversion(_sourceToken, _targetToken, _trader, _amount, _returnAmount, int256(_feeAmount));
    }

    /**
     * @dev returns the expected target amount of converting one reserve to another along with the fee
     *
     * @param _sourceToken contract address of the source reserve token
     * @param _targetToken contract address of the target reserve token
     * @param _amount      amount of tokens received from the user
     *
     * @return expected target amount
     * @return expected fee
     */
    function targetAmountAndFee(
        IERC20Token _sourceToken,
        IERC20Token _targetToken,
        uint256 _amount
    ) public view override active returns (uint256, uint256) {
        uint256 sourceId = __reserveIds[_sourceToken];
        uint256 targetId = __reserveIds[_targetToken];

        (uint256 sourceBalance, uint256 targetBalance) = reserveBalances(sourceId, targetId);
        uint256 amount = crossReserveTargetAmount(sourceBalance, targetBalance, _amount);

        // return the amount minus the conversion fee and the conversion fee
        uint256 fee = calculateFee(amount);
        return (amount - fee, fee);
    }

    /**
     * @dev converts a specific amount of source tokens to target tokens
     *
     * @param _sourceToken source ERC20 token
     * @param _targetToken target ERC20 token
     * @param _amount      amount of tokens to convert (in units of the source token)
     * @param _trader      address of the caller who executed the conversion
     * @param _beneficiary wallet to receive the conversion result
     *
     * @return amount of tokens received (in units of the target token)
     */
    function doConvert(
        IERC20Token _sourceToken,
        IERC20Token _targetToken,
        uint256 _amount,
        address _trader,
        address payable _beneficiary
    ) internal returns (uint256) {
        // update the recent average rate
        updateRecentAverageRate();

        uint256 sourceId = __reserveIds[_sourceToken];
        uint256 targetId = __reserveIds[_targetToken];

        (uint256 sourceBalance, uint256 targetBalance) = reserveBalances(sourceId, targetId);
        uint256 targetAmount = crossReserveTargetAmount(sourceBalance, targetBalance, _amount);

        // get the target amount minus the conversion fee and the conversion fee
        uint256 fee = calculateFee(targetAmount);
        uint256 amount = targetAmount - fee;

        // ensure that the trade gives something in return
        require(amount != 0, "ERR_ZERO_TARGET_AMOUNT");

        // ensure that the trade won't deplete the reserve balance
        assert(amount < targetBalance);

        // ensure that the input amount was already deposited
        uint256 actualSourceBalance;
        if (_sourceToken == ETH_RESERVE_ADDRESS) {
            actualSourceBalance = address(this).balance;
            require(msg.value == _amount, "ERR_ETH_AMOUNT_MISMATCH");
        } else {
            actualSourceBalance = _sourceToken.balanceOf(address(this));
            require(msg.value == 0 && actualSourceBalance.sub(sourceBalance) >= _amount, "ERR_INVALID_AMOUNT");
        }

        // sync the reserve balances
        setReserveBalances(sourceId, targetId, actualSourceBalance, targetBalance - amount);

        // transfer funds to the beneficiary in the to reserve token
        if (_targetToken == ETH_RESERVE_ADDRESS) {
            _beneficiary.transfer(amount);
        } else {
            safeTransfer(_targetToken, _beneficiary, amount);
        }

        // dispatch the conversion event
        dispatchConversionEvent(_sourceToken, _targetToken, _trader, _amount, amount, fee);

        // dispatch rate updates
        dispatchTokenRateUpdateEvents(_sourceToken, _targetToken, actualSourceBalance, targetBalance - amount);

        return amount;
    }

    /**
     * @dev returns the recent average rate of 1 `_token` in the other reserve token units
     *
     * @param _token   token to get the rate for
     * @return recent average rate between the reserves (numerator)
     * @return recent average rate between the reserves (denominator)
     */
    function recentAverageRate(IERC20Token _token) external view returns (uint256, uint256) {
        // get the recent average rate of reserve 0
        uint256 rate = calcRecentAverageRate(averageRateInfo);

        uint256 rateN = decodeAverageRateN(rate);
        uint256 rateD = decodeAverageRateD(rate);

        if (_token == __reserveTokens[0]) {
            return (rateN, rateD);
        }

        return (rateD, rateN);
    }

    /**
     * @dev updates the recent average rate if needed
     */
    function updateRecentAverageRate() internal {
        uint256 averageRateInfo1 = averageRateInfo;
        uint256 averageRateInfo2 = calcRecentAverageRate(averageRateInfo1);
        if (averageRateInfo1 != averageRateInfo2) {
            averageRateInfo = averageRateInfo2;
        }
    }

    /**
     * @dev returns the recent average rate of 1 reserve token 0 in reserve token 1 units
     *
     * @param _averageRateInfo a local copy of the `averageRateInfo` state-variable
     * @return recent average rate between the reserves
     */
    function calcRecentAverageRate(uint256 _averageRateInfo) internal view returns (uint256) {
        // get the previous average rate and its update-time
        uint256 prevAverageRateT = decodeAverageRateT(_averageRateInfo);
        uint256 prevAverageRateN = decodeAverageRateN(_averageRateInfo);
        uint256 prevAverageRateD = decodeAverageRateD(_averageRateInfo);

        // get the elapsed time since the previous average rate was calculated
        uint256 currentTime = time();
        uint256 timeElapsed = currentTime - prevAverageRateT;

        // if the previous average rate was calculated in the current block, the average rate remains unchanged
        if (timeElapsed == 0) {
            return _averageRateInfo;
        }

        // get the current rate between the reserves
        (uint256 currentRateD, uint256 currentRateN) = reserveBalances();

        // if the previous average rate was calculated a while ago or never, the average rate is equal to the current rate
        if (timeElapsed >= AVERAGE_RATE_PERIOD || prevAverageRateT == 0) {
            (currentRateN, currentRateD) = Math.reducedRatio(currentRateN, currentRateD, MAX_UINT112);
            return encodeAverageRateInfo(currentTime, currentRateN, currentRateD);
        }

        uint256 x = prevAverageRateD.mul(currentRateN);
        uint256 y = prevAverageRateN.mul(currentRateD);

        // since we know that timeElapsed < AVERAGE_RATE_PERIOD, we can avoid using SafeMath:
        uint256 newRateN = y.mul(AVERAGE_RATE_PERIOD - timeElapsed).add(x.mul(timeElapsed));
        uint256 newRateD = prevAverageRateD.mul(currentRateD).mul(AVERAGE_RATE_PERIOD);

        (newRateN, newRateD) = Math.reducedRatio(newRateN, newRateD, MAX_UINT112);
        return encodeAverageRateInfo(currentTime, newRateN, newRateD);
    }

    /**
     * @dev increases the pool's liquidity and mints new shares in the pool to the caller
     * note that prior to version 28, you should use 'fund' instead
     *
     * @param _reserveTokens   address of each reserve token
     * @param _reserveAmounts  amount of each reserve token
     * @param _minReturn       token minimum return-amount
     *
     * @return amount of pool tokens issued
     */
    function addLiquidity(
        IERC20Token[2] memory _reserveTokens,
        uint256[2] memory _reserveAmounts,
        uint256 _minReturn
    ) public payable protected active returns (uint256) {
        // verify the user input
        verifyLiquidityInput(_reserveTokens, _reserveAmounts, _minReturn);

        // if one of the reserves is ETH, then verify that the input amount of ETH is equal to the input value of ETH
        for (uint256 i = 0; i < 2; i++) {
            if (_reserveTokens[i] == ETH_RESERVE_ADDRESS) {
                require(_reserveAmounts[i] == msg.value, "ERR_ETH_AMOUNT_MISMATCH");
            }
        }

        // if the input value of ETH is larger than zero, then verify that one of the reserves is ETH
        if (msg.value > 0) {
            require(__reserveIds[ETH_RESERVE_ADDRESS] != 0, "ERR_NO_ETH_RESERVE");
        }

        // save a local copy of the pool token
        IDSToken poolToken = IDSToken(address(anchor));

        // get the total supply
        uint256 totalSupply = poolToken.totalSupply();

        // transfer from the user an equally-worth amount of each one of the reserve tokens
        uint256 amount = addLiquidityToPool(poolToken, _reserveTokens, _reserveAmounts, totalSupply);

        // verify that the equivalent amount of tokens is equal to or larger than the user's expectation
        require(amount >= _minReturn, "ERR_RETURN_TOO_LOW");

        // issue the tokens to the user
        poolToken.issue(msg.sender, amount);

        // return the amount of pool tokens issued
        return amount;
    }

    /**
     * @dev decreases the pool's liquidity and burns the caller's shares in the pool
     * note that prior to version 28, you should use 'liquidate' instead
     *
     * @param _amount                  token amount
     * @param _reserveTokens           address of each reserve token
     * @param _reserveMinReturnAmounts minimum return-amount of each reserve token
     *
     * @return the amount of each reserve token granted for the given amount of pool tokens
     */
    function removeLiquidity(
        uint256 _amount,
        IERC20Token[2] memory _reserveTokens,
        uint256[2] memory _reserveMinReturnAmounts
    ) public protected active returns (uint256[2] memory) {
        // verify the user input
        bool inputRearranged = verifyLiquidityInput(_reserveTokens, _reserveMinReturnAmounts, _amount);

        // save a local copy of the pool token
        IDSToken poolToken = IDSToken(address(anchor));

        // get the total supply BEFORE destroying the user tokens
        uint256 totalSupply = poolToken.totalSupply();

        // destroy the user tokens
        poolToken.destroy(msg.sender, _amount);

        // transfer to the user an equivalent amount of each one of the reserve tokens
        uint256[2] memory reserveAmounts = removeLiquidityFromPool(poolToken, _reserveTokens, _reserveMinReturnAmounts, totalSupply, _amount);

        if (inputRearranged) {
            uint256 tempReserveAmount = reserveAmounts[0];
            reserveAmounts[0] = reserveAmounts[1];
            reserveAmounts[1] = tempReserveAmount;
        }

        return reserveAmounts;
    }

    /**
     * @dev increases the pool's liquidity and mints new shares in the pool to the caller
     * for example, if the caller increases the supply by 10%,
     * then it will cost an amount equal to 10% of each reserve token balance
     * note that starting from version 28, you should use 'addLiquidity' instead
     *
     * @param _amount  amount to increase the supply by (in the pool token)
     *
     * @return amount of pool tokens issued
     */
    function fund(uint256 _amount) public payable protected returns (uint256) {
        syncReserveBalances(msg.value);

        IDSToken poolToken = IDSToken(address(anchor));
        uint256 supply = poolToken.totalSupply();

        uint256[2] memory oldReserveBalances;
        uint256[2] memory newReserveBalances;

        (oldReserveBalances[0], oldReserveBalances[1]) = reserveBalances();

        // iterate through the reserve tokens and transfer a percentage equal to the weight between
        // _amount and the total supply in each reserve from the caller to the converter
        for (uint256 i = 0; i < 2; i++) {
            IERC20Token reserveToken = __reserveTokens[i];
            uint256 reserveAmount = fundCost(supply, oldReserveBalances[i], _amount);

            // transfer funds from the caller in the reserve token
            if (reserveToken == ETH_RESERVE_ADDRESS) {
                if (msg.value > reserveAmount) {
                    msg.sender.transfer(msg.value - reserveAmount);
                } else {
                    require(msg.value == reserveAmount, "ERR_INVALID_ETH_VALUE");
                }
            } else {
                safeTransferFrom(reserveToken, msg.sender, address(this), reserveAmount);
            }

            // save the new reserve balance
            newReserveBalances[i] = oldReserveBalances[i].add(reserveAmount);

            uint256 newPoolTokenSupply = supply.add(_amount);

            // dispatch liquidity update for the pool token/reserve
            emit LiquidityAdded(msg.sender, reserveToken, reserveAmount, newReserveBalances[i], newPoolTokenSupply);

            // dispatch the `TokenRateUpdate` event for the pool token
            emit TokenRateUpdate(poolToken, reserveToken, newReserveBalances[i], newPoolTokenSupply);
        }

        // set the reserve balances
        setReserveBalances(1, 2, newReserveBalances[0], newReserveBalances[1]);

        // issue new funds to the caller in the pool token
        poolToken.issue(msg.sender, _amount);

        // return the amount of pool tokens issued
        return _amount;
    }

    /**
     * @dev decreases the pool's liquidity and burns the caller's shares in the pool
     * for example, if the holder sells 10% of the supply,
     * then they will receive 10% of each reserve token balance in return
     * note that starting from version 28, you should use 'removeLiquidity' instead
     *
     * @param _amount  amount to liquidate (in the pool token)
     *
     * @return the amount of each reserve token granted for the given amount of pool tokens
     */
    function liquidate(uint256 _amount) public protected returns (uint256[2] memory) {
        require(_amount > 0, "ERR_ZERO_AMOUNT");

        IDSToken poolToken = IDSToken(address(anchor));
        uint256 totalSupply = poolToken.totalSupply();
        poolToken.destroy(msg.sender, _amount);

        IERC20Token[2] memory _reserveTokens;
        for (uint256 i = 0; i < 2; i++) _reserveTokens[i] = __reserveTokens[i];

        return removeLiquidityFromPool(poolToken, _reserveTokens, [uint256(1), uint256(1)], totalSupply, _amount);
    }

    /**
     * @dev given the amount of one of the reserve tokens to add liquidity of,
     * returns the required amount of each one of the other reserve tokens
     * since an empty pool can be funded with any list of non-zero input amounts,
     * this function assumes that the pool is not empty (has already been funded)
     *
     * @param _reserveTokens       address of each reserve token
     * @param _reserveTokenIndex   index of the relevant reserve token
     * @param _reserveAmount       amount of the relevant reserve token
     *
     * @return the required amount of each one of the reserve tokens
     */
    function addLiquidityCost(
        IERC20Token[2] memory _reserveTokens,
        uint256 _reserveTokenIndex,
        uint256 _reserveAmount
    ) public view returns (uint256[2] memory) {
        uint256[2] memory _reserveAmounts;
        uint256[2] memory _reserveBalances;

        uint256 reserve0Id = __reserveIds[_reserveTokens[0]];
        uint256 reserve1Id = __reserveIds[_reserveTokens[1]];
        (_reserveBalances[0], _reserveBalances[1]) = reserveBalances(reserve0Id, reserve1Id);

        uint256 totalSupply = IDSToken(address(anchor)).totalSupply();
        uint256 amount = fundSupplyAmount(totalSupply, _reserveBalances[_reserveTokenIndex], _reserveAmount);

        for (uint256 i = 0; i < 2; i++) _reserveAmounts[i] = fundCost(totalSupply, _reserveBalances[i], amount);

        return _reserveAmounts;
    }

    /**
     * @dev given the amount of one of the reserve tokens to add liquidity of,
     * returns the amount of pool tokens entitled for it
     * since an empty pool can be funded with any list of non-zero input amounts,
     * this function assumes that the pool is not empty (has already been funded)
     *
     * @param _reserveToken    address of the reserve token
     * @param _reserveAmount   amount of the reserve token
     *
     * @return the amount of pool tokens entitled
     */
    function addLiquidityReturn(IERC20Token _reserveToken, uint256 _reserveAmount) public view returns (uint256) {
        uint256 totalSupply = IDSToken(address(anchor)).totalSupply();
        return fundSupplyAmount(totalSupply, reserveBalance(__reserveIds[_reserveToken]), _reserveAmount);
    }

    /**
     * @dev returns the amount of each reserve token entitled for a given amount of pool tokens
     *
     * @param _amount          amount of pool tokens
     * @param _reserveTokens   address of each reserve token
     *
     * @return the amount of each reserve token entitled for the given amount of pool tokens
     */
    function removeLiquidityReturn(uint256 _amount, IERC20Token[2] memory _reserveTokens)
        public
        view
        returns (uint256[2] memory)
    {
        uint256 totalSupply = IDSToken(address(anchor)).totalSupply();
        return removeLiquidityReserveAmounts(_amount, _reserveTokens, totalSupply);
    }

    /**
     * @dev verifies that a given array of tokens is identical to the converter's array of reserve tokens
     * we take this input in order to allow specifying the corresponding reserve amounts in any order
     * this function rearranges the input arrays according to the converter's array of reserve tokens
     *
     * @param _reserveTokens   array of reserve tokens
     * @param _reserveAmounts  array of reserve amounts
     * @param _amount          token amount
     *
     * @return true if the function has rearranged the input arrays; false otherwise
     */
    function verifyLiquidityInput(
        IERC20Token[2] memory _reserveTokens,
        uint256[2] memory _reserveAmounts,
        uint256 _amount
    ) private view returns (bool) {
        require(_reserveAmounts[0] > 0 && _reserveAmounts[1] > 0 && _amount > 0, "ERR_ZERO_AMOUNT");

        uint256 reserve0Id = __reserveIds[_reserveTokens[0]];
        uint256 reserve1Id = __reserveIds[_reserveTokens[1]];

        if (reserve0Id == 2 && reserve1Id == 1) {
            IERC20Token tempReserveToken = _reserveTokens[0];
            _reserveTokens[0] = _reserveTokens[1];
            _reserveTokens[1] = tempReserveToken;
            uint256 tempReserveAmount = _reserveAmounts[0];
            _reserveAmounts[0] = _reserveAmounts[1];
            _reserveAmounts[1] = tempReserveAmount;
            return true;
        }

        require(reserve0Id == 1 && reserve1Id == 2, "ERR_INVALID_RESERVE");
        return false;
    }

    /**
     * @dev adds liquidity (reserve) to the pool
     *
     * @param _poolToken       address of the pool token
     * @param _reserveTokens   address of each reserve token
     * @param _reserveAmounts  amount of each reserve token
     * @param _totalSupply     token total supply
     *
     * @return amount of pool tokens issued
     */
    function addLiquidityToPool(
        IDSToken _poolToken,
        IERC20Token[2] memory _reserveTokens,
        uint256[2] memory _reserveAmounts,
        uint256 _totalSupply
    ) private returns (uint256) {
        syncReserveBalances(msg.value);

        uint256[2] memory oldReserveBalances;
        uint256[2] memory newReserveBalances;

        (oldReserveBalances[0], oldReserveBalances[1]) = reserveBalances();

        uint256 amount;
        uint256[] memory reserveAmounts = new uint256[](2);

        if (_totalSupply == 0) {
            for (uint256 i = 0; i < 2; i++) {
                reserveAmounts[i] = _reserveAmounts[i];
            }
            amount = Math.geometricMean(reserveAmounts);
        }
        else {
            uint256 index = (_reserveAmounts[0].mul(oldReserveBalances[1]) < _reserveAmounts[1].mul(oldReserveBalances[0])) ? 0 : 1;
            amount = fundSupplyAmount(_totalSupply, oldReserveBalances[index], _reserveAmounts[index]);
            for (uint256 i = 0; i < 2; i++) {
                reserveAmounts[i] = fundCost(_totalSupply, oldReserveBalances[i], amount);
            }
        }

        uint256 newPoolTokenSupply = _totalSupply.add(amount);

        for (uint256 i = 0; i < 2; i++) {
            IERC20Token reserveToken = _reserveTokens[i];
            uint256 reserveAmount = reserveAmounts[i];
            require(reserveAmount > 0, "ERR_ZERO_TARGET_AMOUNT");
            assert(reserveAmount <= _reserveAmounts[i]);

            // transfer each one of the reserve amounts from the user to the pool
            if (reserveToken != ETH_RESERVE_ADDRESS) {
                // ETH has already been transferred as part of the transaction
                safeTransferFrom(reserveToken, msg.sender, address(this), reserveAmount);
            } else if (_reserveAmounts[i] > reserveAmount) {
                // transfer the extra amount of ETH back to the user
                msg.sender.transfer(_reserveAmounts[i] - reserveAmount);
            }

            // save the new reserve balance
            newReserveBalances[i] = oldReserveBalances[i].add(reserveAmount);

            emit LiquidityAdded(msg.sender, reserveToken, reserveAmount, newReserveBalances[i], newPoolTokenSupply);

            // dispatch the `TokenRateUpdate` event for the pool token
            emit TokenRateUpdate(_poolToken, reserveToken, newReserveBalances[i], newPoolTokenSupply);
        }

        // set the reserve balances
        setReserveBalances(1, 2, newReserveBalances[0], newReserveBalances[1]);

        // return the amount of pool tokens issued
        return amount;
    }

    /**
     * @dev returns the amount of each reserve token entitled for a given amount of pool tokens
     *
     * @param _amount          amount of pool tokens
     * @param _reserveTokens   address of each reserve token
     * @param _totalSupply     token total supply
     *
     * @return the amount of each reserve token entitled for the given amount of pool tokens
     */
    function removeLiquidityReserveAmounts(
        uint256 _amount,
        IERC20Token[2] memory _reserveTokens,
        uint256 _totalSupply
    ) private view returns (uint256[2] memory) {
        uint256[2] memory _reserveAmounts;
        uint256[2] memory _reserveBalances;

        uint256 reserve0Id = __reserveIds[_reserveTokens[0]];
        uint256 reserve1Id = __reserveIds[_reserveTokens[1]];
        (_reserveBalances[0], _reserveBalances[1]) = reserveBalances(reserve0Id, reserve1Id);

        for (uint256 i = 0; i < 2; i++)
            _reserveAmounts[i] = liquidateReserveAmount(_totalSupply, _reserveBalances[i], _amount);
        return _reserveAmounts;
    }

    /**
     * @dev removes liquidity (reserve) from the pool
     *
     * @param _poolToken               address of the pool token
     * @param _reserveTokens           address of each reserve token
     * @param _reserveMinReturnAmounts minimum return-amount of each reserve token
     * @param _totalSupply             token total supply
     * @param _amount                  token amount
     *
     * @return the amount of each reserve token granted for the given amount of pool tokens
     */
    function removeLiquidityFromPool(
        IDSToken _poolToken,
        IERC20Token[2] memory _reserveTokens,
        uint256[2] memory _reserveMinReturnAmounts,
        uint256 _totalSupply,
        uint256 _amount
    ) private returns (uint256[2] memory) {
        syncReserveBalances();

        uint256 newPoolTokenSupply = _totalSupply.sub(_amount);
        uint256[2] memory reserveAmounts = removeLiquidityReserveAmounts(_amount, _reserveTokens, _totalSupply);

        uint256[2] memory oldReserveBalances;
        uint256[2] memory newReserveBalances;

        (oldReserveBalances[0], oldReserveBalances[1]) = reserveBalances();

        for (uint256 i = 0; i < 2; i++) {
            IERC20Token reserveToken = _reserveTokens[i];
            uint256 reserveAmount = reserveAmounts[i];
            require(reserveAmount >= _reserveMinReturnAmounts[i], "ERR_ZERO_TARGET_AMOUNT");

            // save the new reserve balance
            newReserveBalances[i] = oldReserveBalances[i].sub(reserveAmount);

            // transfer each one of the reserve amounts from the pool to the user
            if (reserveToken == ETH_RESERVE_ADDRESS) {
                msg.sender.transfer(reserveAmount);
            } else {
                safeTransfer(reserveToken, msg.sender, reserveAmount);
            }

            emit LiquidityRemoved(msg.sender, reserveToken, reserveAmount, newReserveBalances[i], newPoolTokenSupply);

            // dispatch the `TokenRateUpdate` event for the pool token
            emit TokenRateUpdate(_poolToken, reserveToken, newReserveBalances[i], newPoolTokenSupply);
        }

        // set the reserve balances
        setReserveBalances(1, 2, newReserveBalances[0], newReserveBalances[1]);

        // return the amount of each reserve token granted for the given amount of pool tokens
        return reserveAmounts;
    }

    /**
     * @dev dispatches token rate update events for the reserve tokens and the pool token
     *
     * @param _sourceToken     address of the source reserve token
     * @param _targetToken     address of the target reserve token
     * @param _sourceBalance   balance of the source reserve token
     * @param _targetBalance   balance of the target reserve token
     */
    function dispatchTokenRateUpdateEvents(
        IERC20Token _sourceToken,
        IERC20Token _targetToken,
        uint256 _sourceBalance,
        uint256 _targetBalance
    ) private {
        // save a local copy of the pool token
        IDSToken poolToken = IDSToken(address(anchor));

        // get the total supply of pool tokens
        uint256 poolTokenSupply = poolToken.totalSupply();

        // dispatch token rate update event for the reserve tokens
        emit TokenRateUpdate(_sourceToken, _targetToken, _targetBalance, _sourceBalance);

        // dispatch token rate update events for the pool token
        emit TokenRateUpdate(poolToken, _sourceToken, _sourceBalance, poolTokenSupply);
        emit TokenRateUpdate(poolToken, _targetToken, _targetBalance, poolTokenSupply);
    }

    /**
     * @dev returns the current time
     * utility to allow overrides for tests
     */
    function time() internal view virtual returns (uint256) {
        return block.timestamp;
    }

    function encodeReserveBalance(uint256 _balance, uint256 _id) private pure returns (uint256) {
        return _balance << ((_id - 1) * 128);
    }

    function decodeReserveBalance(uint256 _balances, uint256 _id) private pure returns (uint256) {
        return (_balances >> ((_id - 1) * 128)) & MAX_UINT128;
    }

    function encodeReserveBalances(
        uint256 _balance0,
        uint256 _id0,
        uint256 _balance1,
        uint256 _id1
    ) private pure returns (uint256) {
        return encodeReserveBalance(_balance0, _id0) | encodeReserveBalance(_balance1, _id1);
    }

    function decodeReserveBalances(
        uint256 _balances,
        uint256 _id0,
        uint256 _id1
    ) private pure returns (uint256, uint256) {
        return (decodeReserveBalance(_balances, _id0), decodeReserveBalance(_balances, _id1));
    }

    function encodeAverageRateInfo(
        uint256 _averageRateT,
        uint256 _averageRateN,
        uint256 _averageRateD
    ) private pure returns (uint256) {
        return (_averageRateT << 224) | (_averageRateN << 112) | _averageRateD;
    }

    function decodeAverageRateT(uint256 _averageRateInfo) private pure returns (uint256) {
        return _averageRateInfo >> 224;
    }

    function decodeAverageRateN(uint256 _averageRateInfo) private pure returns (uint256) {
        return (_averageRateInfo >> 112) & MAX_UINT112;
    }

    function decodeAverageRateD(uint256 _averageRateInfo) private pure returns (uint256) {
        return _averageRateInfo & MAX_UINT112;
    }

    function crossReserveTargetAmount(
        uint256 _sourceReserveBalance,
        uint256 _targetReserveBalance,
        uint256 _amount
    ) private pure returns (uint256) {
        // validate input
        require(_sourceReserveBalance > 0 && _targetReserveBalance > 0, "ERR_INVALID_RESERVE_BALANCE");

        return _targetReserveBalance.mul(_amount) / _sourceReserveBalance.add(_amount);
    }

    function fundCost(
        uint256 _supply,
        uint256 _reserveBalance,
        uint256 _amount
    ) private pure returns (uint256) {
        // validate input
        require(_supply > 0, "ERR_INVALID_SUPPLY");
        require(_reserveBalance > 0, "ERR_INVALID_RESERVE_BALANCE");

        // special case for 0 amount
        if (_amount == 0) {
            return 0;
        }

        return (_amount.mul(_reserveBalance) - 1) / _supply + 1;
    }

    function fundSupplyAmount(
        uint256 _supply,
        uint256 _reserveBalance,
        uint256 _amount
    ) private pure returns (uint256) {
        // validate input
        require(_supply > 0, "ERR_INVALID_SUPPLY");
        require(_reserveBalance > 0, "ERR_INVALID_RESERVE_BALANCE");

        // special case for 0 amount
        if (_amount == 0) {
            return 0;
        }

        return _amount.mul(_supply) / _reserveBalance;
    }

    function liquidateReserveAmount(
        uint256 _supply,
        uint256 _reserveBalance,
        uint256 _amount
    ) private pure returns (uint256) {
        // validate input
        require(_supply > 0, "ERR_INVALID_SUPPLY");
        require(_reserveBalance > 0, "ERR_INVALID_RESERVE_BALANCE");
        require(_amount <= _supply, "ERR_INVALID_AMOUNT");

        // special case for 0 amount
        if (_amount == 0) {
            return 0;
        }

        // special case for liquidating the entire supply
        if (_amount == _supply) {
            return _reserveBalance;
        }

        return _amount.mul(_reserveBalance) / _supply;
    }

    /**
     * @dev deprecated since version 28, backward compatibility - use only for earlier versions
     */
    function token() public view override returns (IConverterAnchor) {
        return anchor;
    }

    /**
     * @dev deprecated, backward compatibility
     */
    function transferTokenOwnership(address _newOwner) public override ownerOnly {
        transferAnchorOwnership(_newOwner);
    }

    /**
     * @dev deprecated, backward compatibility
     */
    function acceptTokenOwnership() public override ownerOnly {
        acceptAnchorOwnership();
    }

    /**
     * @dev deprecated, backward compatibility
     */
    function connectors(IERC20Token _address)
        public
        view
        override
        returns (
            uint256,
            uint32,
            bool,
            bool,
            bool
        )
    {
        uint256 reserveId = __reserveIds[_address];
        if (reserveId != 0) {
            return (reserveBalance(reserveId), PPM_RESOLUTION / 2, false, false, true);
        }
        return (0, 0, false, false, false);
    }

    /**
     * @dev deprecated, backward compatibility
     */
    function connectorTokens(uint256 _index) public view override returns (IERC20Token) {
        return __reserveTokens[_index];
    }

    /**
     * @dev deprecated, backward compatibility
     */
    function connectorTokenCount() public view override returns (uint16) {
        return reserveTokenCount();
    }

    /**
     * @dev deprecated, backward compatibility
     */
    function getConnectorBalance(IERC20Token _connectorToken) public view override returns (uint256) {
        return reserveBalance(_connectorToken);
    }

    /**
     * @dev deprecated, backward compatibility
     */
    function getReturn(
        IERC20Token _sourceToken,
        IERC20Token _targetToken,
        uint256 _amount
    ) public view returns (uint256, uint256) {
        return targetAmountAndFee(_sourceToken, _targetToken, _amount);
    }
}