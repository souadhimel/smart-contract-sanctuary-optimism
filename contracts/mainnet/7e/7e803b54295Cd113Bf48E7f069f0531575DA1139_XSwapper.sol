// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.2;

import { Address } from "Address.sol";
import "AccessControlUpgradeable.sol";
import "UUPSUpgradeable.sol";
import "PausableUpgradeable.sol";
import "ERC20.sol";
import "ECDSA.sol";
import "SafeERC20.sol";
import "ReentrancyGuard.sol";

import "Supervisor.sol";
import "IDexAggregatorAdaptor.sol";
import "IYPoolVault.sol";


/// @title XSwapper contract
/// @notice Users call `swap` to swap asset to specified bridgeable asset and then initiate a cross-chain swap request.
/// YPool workers call `closeSwap` to complete a cross-chain swap, `claim` & `batchClaim` to claim the credit back.
/// YPool validators call `lockCloseSwap` & `refund` to lock the swap and refund asset back to user if no applicable
/// liquidity or a YPool worker sent an invalidated closeSwap tx.
/// - "User" and "Account" refer to the same thing
/// - "fromChain" and "source chain" refer to the same thing
/// - "toChain" and "target chain" refer to the same thing
/// - "XYChain" and "Settlement chain" refer to the same thing
contract XSwapper is AccessControlUpgradeable, UUPSUpgradeable, PausableUpgradeable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using ECDSA for bytes32;

    /* ========== STRUCTURE ========== */

    // Status of a swap request (on source chain)
    enum RequestStatus { Open, Closed }
    // Result of a swap when it's closed (on target chain)
    enum CloseSwapResult { NonSwapped, Success, Failed, Locked }
    // Type of how the asset is transferred when the swap is completed
    enum CompleteSwapType { Claimed, FreeClaimed, Refunded }

    // Fees settings on each chain
    // Fee is calculated as `inputAmount * FeeStructure.rate / (10 ** FeeStructure.decimals)`
    struct FeeStructure {
        bool isSet;
        uint256 gas;
        uint256 min;
        uint256 max;
        uint256 rate;
        uint256 decimals;
    }

    // Info of a swap request
    struct SwapRequest {
        uint32 toChainId;
        uint256 swapId;
        address receiver;
        address sender;
        uint256 YPoolTokenAmount;
        uint256 xyFee;
        uint256 gasFee;
        IERC20 YPoolToken;
        RequestStatus status;
    }

    // Info of an expecting swap on target chain of a swap request
    struct ToChainDescription {
        uint32 toChainId;
        IERC20 toChainToken;
        uint256 expectedToChainTokenAmount;
        uint32 slippage;
    }

    /* ========== STATE VARIABLES ========== */

    // Roles
    bytes32 public constant ROLE_OWNER = keccak256("ROLE_OWNER");
    bytes32 public constant ROLE_MANAGER = keccak256("ROLE_MANAGER");
    bytes32 public constant ROLE_STAFF = keccak256("ROLE_STAFF");
    bytes32 public constant ROLE_YPOOL_WORKER = keccak256("ROLE_YPOOL_WORKER");

    // Mapping of YPool token to its max amount in a single swap
    mapping (address => uint256) public maxYPoolTokenSwapAmount;

    // A contract that supervises each refund and claim by providing signatures
    Supervisor public supervisor;
    // A referenced address of native currency
    address public constant ETHER_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    // Id of the current chain
    uint32 public chainId;
    // Next available id of a swap request
    // Note: the value is monotonically increasing as there MUST NOT exist swap requests with same Id
    // Note: swapId must be set to start accepting swap requests.
    uint256 public swapId;
    // The starting swap Id of the XSwapper
    // Note: It is immutable after setting startSwapId
    uint256 public startSwapId;
    // Note: swapIdIsSet should only be set to True and freeze once in function `setStartSwapId`
    bool public swapIdIsSet;
    // Accept swap requests or not
    bool public acceptSwapRequest;
    // Close status of each swap
    mapping (bytes32 => bool) everClosed;

    // Supported YPool tokens
    mapping (address => bool) public YPoolSupportedToken;
    // YPoolVault of a YPoolSupportedToken
    mapping (address => address) public YPoolVaults;
    // Whitelist of AggregatorAdaptors
    mapping (address => bool) public isWhitelistedAggregatorAdaptor;
    // SwapValidator contract on XYChain that validates a `closeSwap` transaction
    // Note: this contract does not exist on periphery chains so its address is used only for signature verification purpose in `claim` and `batchClaim`
    address public swapValidatorXYChain;

    // Fees setting of a supported token on each chain
    mapping (bytes32 => FeeStructure) public feeStructures;
    // All swap requests initiated by users
    mapping (uint256 => SwapRequest) public swapRequests;

    receive() external payable {}
    function _authorizeUpgrade(address) internal override onlyRole(ROLE_OWNER) {}

    /// @notice Initialize XSwapper
    /// @param owner The owner address
    /// @param manager The manager address
    /// @param staff The staff address
    /// @param worker The swap worker address
    /// @param _supervisor The supervisor contract address
    /// @param _chainId The chain ID
    function initialize(address owner, address manager, address staff, address worker, address _supervisor, uint32 _chainId) initializer public {
        require(Address.isContract(_supervisor), "ERR_SUPERVISOR_NOT_CONTRACT");
        supervisor = Supervisor(_supervisor);
        chainId = _chainId;
        acceptSwapRequest = false;

        // Validate chainId
        uint256 _realChainId;
        assembly {
            _realChainId := chainid()
        }
        require(_chainId == _realChainId, "ERR_WRONG_CHAIN_ID");

        _setRoleAdmin(ROLE_OWNER, ROLE_OWNER);
        _setRoleAdmin(ROLE_MANAGER, ROLE_OWNER);
        _setRoleAdmin(ROLE_STAFF, ROLE_OWNER);
        _setRoleAdmin(ROLE_YPOOL_WORKER, ROLE_OWNER);
        _setupRole(ROLE_OWNER, owner);
        _setupRole(ROLE_MANAGER, manager);
        _setupRole(ROLE_STAFF, staff);
        _setupRole(ROLE_YPOOL_WORKER, worker);
    }

    /* ========== MODIFIERS ========== */

    modifier acceptSwap() {
        require(acceptSwapRequest, "ERR_NOT_ACCEPTING_SWAP_REQUESTS");
        _;
    }

    /* ========== PRIVATE FUNCTIONS ========== */

    function max(uint256 a, uint256 b) private pure returns (uint256) {
        return a >= b ? a : b;
    }

    function min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }

    /// @notice Get the XY protocol fee setting of `_token` on chain `_toChainId`
    /// @param _toChainId Chain Id of the periphery chain
    /// @param _token YPool token
    function _getFeeStructure(uint32 _toChainId, address _token) private view returns (FeeStructure memory) {
        bytes32 universalTokenId = keccak256(abi.encodePacked(_toChainId, _token));
        return feeStructures[universalTokenId];
    }

    function _safeTransferAsset(address receiver, IERC20 token, uint256 amount) private {
        if (address(token) == ETHER_ADDRESS) {
            payable(receiver).transfer(amount);
        } else {
            token.safeTransfer(receiver, amount);
        }
    }

    function _safeTransferFromAsset(IERC20 fromToken, address from, uint256 amount) private {
        if (address(fromToken) == ETHER_ADDRESS)
            require(msg.value == amount, "ERR_INVALID_AMOUNT");
        else {
            uint256 _fromTokenBalance = getTokenBalance(fromToken, address(this));
            fromToken.safeTransferFrom(from, address(this), amount);
            require(getTokenBalance(fromToken, address(this)) - _fromTokenBalance == amount, "ERR_INVALID_AMOUNT");
        }
    }

    /// @notice Check whether the swap amount reaches the threshold or not
    /// @param _toChainId Chain Id of the target chain
    /// @param token YPool token
    /// @param amount Swap amount
    /// @dev A swap could be closed by YPool worker on target chain or get refunded on source chain, i.e., this chain,
    /// therefore, we require the `amount` not only be GTE the fee on target chain but also on source chain
    function _checkMinimumSwapAmount(uint32 _toChainId, IERC20 token, uint256 amount) private view returns (bool) {
        FeeStructure memory feeStructure = _getFeeStructure(_toChainId, address(token));
        require(feeStructure.isSet, "ERR_FEE_NOT_SET");
        uint256 minToChainFee = feeStructure.min;  // closeSwap

        feeStructure = _getFeeStructure(chainId, address(token));
        require(feeStructure.isSet, "ERR_FEE_NOT_SET");
        uint256 minFromChainFee = feeStructure.min;  // refund

        return amount >= max(minToChainFee, minFromChainFee);
    }

    /// @notice Calculate the XY protocol fee and gas fee
    /// @param _chainId Chain Id of the periphery chain
    /// @param token YPool token
    /// @param amount YPool token amount
    function _calculateFee(uint32 _chainId, IERC20 token, uint256 amount) private view returns (uint256 xyFee, uint256 gasFee) {
        FeeStructure memory feeStructure = _getFeeStructure(_chainId, address(token));
        require(feeStructure.isSet, "ERR_FEE_NOT_SET");

        xyFee = amount * feeStructure.rate / (10 ** feeStructure.decimals);
        xyFee = min(max(xyFee, feeStructure.min), feeStructure.max);
        gasFee = feeStructure.gas;
    }

    /* ========== VIEW FUNCTIONS ========== */

    /// @notice Get a certain swap request
    /// @dev TODO: Though swapRequests is a public mapping, here we keep getSwapRequest for those applications that need this interface. Should be removed since next upgrade.
    /// @param _swapId Swap Id of a swap request
    function getSwapRequest(uint256 _swapId) external view returns (SwapRequest memory) {
        return swapRequests[_swapId];
    }

    /// @notice Get the XY protocol fee setting of `_token` on chain `_toChainId`
    /// @param _chainId Chain Id of the periphery chain
    /// @param _token YPool token
    function getFeeStructure(uint32 _chainId, address _token) external view returns (FeeStructure memory) {
        FeeStructure memory feeStructure = _getFeeStructure(_chainId, _token);
        require(feeStructure.isSet, "ERR_FEE_NOT_SET");
        return feeStructure;
    }

    /// @notice Check whether a swap is closed or not on this chain, assuming this chain is the target chain
    /// @param _chainId Chain Id of the source chain
    /// @param _swapId Swap Id of a swap request
    function getEverClosed(uint32 _chainId, uint256 _swapId) external view returns (bool) {
        bytes32 universalSwapId = keccak256(abi.encodePacked(_chainId, _swapId));
        return everClosed[universalSwapId];
    }

    /// @notice Get the token or native token balance of given account
    /// @param _token ERC20 token address or ETHER_ADDRESS which stands for native token
    /// @param _account YPool token
    function getTokenBalance(IERC20 _token, address _account) public view returns (uint256 balance) {
        balance = address(_token) == ETHER_ADDRESS ? _account.balance : _token.balanceOf(_account);
    }

    /* ========== RESTRICTED FUNCTIONS (OWNER) ========== */

    /// @notice Set start swapId
    /// @dev swapId can only be set once and before any swap request comes in
    /// @param _swapId Swap Id of a swap request
    function setStartSwapId(uint256 _swapId) external onlyRole(ROLE_OWNER) {
        require(!swapIdIsSet, "ERR_SWAP_ID_ALREADY_SET");
        swapIdIsSet = true;
        startSwapId = _swapId;
        swapId = _swapId;
        emit StartSwapIdSet(_swapId);
    }

    /// @notice Set YPoolVault and its token
    /// @param _supportedToken YPool token
    /// @param _vault Address of the YPoolVault
    /// @param _isSet To Add or to remove
    function setYPoolVault(address _supportedToken, address _vault, bool _isSet) external onlyRole(ROLE_OWNER) {
        if (_supportedToken != ETHER_ADDRESS) {
            require(Address.isContract(_supportedToken), "ERR_YPOOL_TOKEN_NOT_CONTRACT");
        }
        require(Address.isContract(_vault), "ERR_YPOOL_VAULT_NOT_CONTRACT");
        YPoolSupportedToken[_supportedToken] = _isSet;
        YPoolVaults[_supportedToken] = _vault;
        emit YPoolVaultSet(_supportedToken, _vault, _isSet);
    }

    /// @notice Rescue fund accidentally sent to this contract. Can not rescue YPool token
    /// @param tokens List of token address to rescue
    function rescue(IERC20[] memory tokens) external onlyRole(ROLE_OWNER) {
        for (uint256 i; i < tokens.length; i++) {
            IERC20 token = tokens[i];
            require(!YPoolSupportedToken[address(token)], "ERR_CAN_NOT_RESCUE_YPOOL_TOKEN");
            uint256 _tokenBalance = token.balanceOf(address(this));
            token.safeTransfer(msg.sender, _tokenBalance);
        }
    }

    /* ========== RESTRICTED FUNCTIONS (MANAGER) ========== */

    /// @notice Set the maximum swap amount of a YPool token
    /// @param _supportedToken YPool token
    /// @param amount Maximum swap amount
    function setMaxYPoolTokenSwapAmount(address _supportedToken, uint256 amount) external onlyRole(ROLE_MANAGER) {
        require(YPoolSupportedToken[_supportedToken], "ERR_INVALID_YPOOL_TOKEN");
        maxYPoolTokenSwapAmount[_supportedToken] = amount;
    }

    /// @notice Set the dex aggregator
    /// @param _aggregatorAdaptor Address of the aggregator
    function setAggregatorAdaptor(address _aggregatorAdaptor, bool _isSet) external onlyRole(ROLE_MANAGER) {
        require(Address.isContract(_aggregatorAdaptor), "ERR_AGGREGATOR_ADAPTOR_NOT_CONTRACT");
        require(isWhitelistedAggregatorAdaptor[_aggregatorAdaptor] != _isSet, "ERR_ALREADY_SET");
        isWhitelistedAggregatorAdaptor[_aggregatorAdaptor] = _isSet;
        emit AggregatorAdaptorSet(_aggregatorAdaptor, _isSet);
    }

    /// @notice Pause the major functions
    function pause() external onlyRole(ROLE_MANAGER) {
        _pause();
    }

    /// @notice Unpause the major functions
    function unpause() external onlyRole(ROLE_MANAGER) {
        _unpause();
    }

    /// @notice Set to accept swap request or not
    function setAcceptSwapRequest(bool _isSet) external onlyRole(ROLE_MANAGER) {
        require(acceptSwapRequest != _isSet, "ERR_ALREADY_SET");
        acceptSwapRequest = _isSet;
        emit AcceptSwapRequestSet(_isSet);
    }

    /* ========== RESTRICTED FUNCTIONS (STAFF) ========== */

    /// @notice Set the XY protocol fee setting of `_token` on chain `_toChainId`
    /// @param _toChainId Chain Id of the periphery chain
    /// @param _supportedToken YPool token
    /// @param _gas Estimated gas fee of closeSwap/refund in form of YPool Token
    /// @param _min Minimum amount of the XY protocol fee of `_supportedToken`
    /// @param _max Maximum amount of the XY protocol fee of `_supportedToken`
    /// @param rate Fee rate of the XY protocol fee of `_supportedToken`
    /// @param decimals Decimals of `_rate`
    function setFeeStructure(uint32 _toChainId, address _supportedToken, uint256 _gas, uint256 _min, uint256 _max, uint256 rate, uint256 decimals) external onlyRole(ROLE_STAFF) {
        if (_supportedToken != ETHER_ADDRESS) {
            require(Address.isContract(_supportedToken), "ERR_YPOOL_TOKEN_NOT_CONTRACT");
        }
        require(_max > _min, "ERR_INVALID_MAX_MIN");
        require(_min >= _gas, "ERR_INVALID_MIN_GAS");
        bytes32 universalTokenId = keccak256(abi.encodePacked(_toChainId, _supportedToken));
        FeeStructure memory feeStructure = FeeStructure(true, _gas, _min, _max, rate, decimals);
        feeStructures[universalTokenId] = feeStructure;
        emit FeeStructureSet(_toChainId, _supportedToken, _gas, _min, _max, rate, decimals);
    }

    /// @notice Set the SwapValidator
    /// @param _swapValidatorXYChain Address of the SwapValidator on XY chain
    function setSwapValidatorXYChain(address _swapValidatorXYChain) external onlyRole(ROLE_STAFF) {
        swapValidatorXYChain = _swapValidatorXYChain;
        emit SwapValidatorXYChainSet(_swapValidatorXYChain);
    }

    /* ========== RESTRICTED FUNCTIONS (YPOOL_WORKER) ========== */

    /// @notice Fulfill a swap request for a user by YPool worker
    /// Closing a swap MUST be performed on target chain and only by YPool worker
    /// @dev swapDesc is the swap info for swapping on DEX on target chain, not the info of the swap request user initiated on source chain
    /// @param aggregatorAdaptor The address of the adaptor of the specific dex aggregator
    /// @param swapDesc Description of the swap on DEX, see IDexAggregatorAdaptor.SwapDescription
    /// @param aggregatorData Raw data consists of instructions to swap user's token for YPool token
    /// @param fromChainId Source chain id of the swap request
    /// @param fromSwapId Swap id of the swap request
    function closeSwap(
        address aggregatorAdaptor,
        IDexAggregatorAdaptor.SwapDescription calldata swapDesc,
        bytes memory aggregatorData,
        uint32 fromChainId,
        uint256 fromSwapId
    ) external payable whenNotPaused nonReentrant onlyRole(ROLE_YPOOL_WORKER) {
        require(YPoolSupportedToken[address(swapDesc.fromToken)], "ERR_INVALID_YPOOL_TOKEN");

        {
            bytes32 universalSwapId = keccak256(abi.encodePacked(fromChainId, fromSwapId));
            require(!everClosed[universalSwapId], "ERR_ALREADY_CLOSED");
            everClosed[universalSwapId] = true;
        }

        require(swapDesc.amount <= maxYPoolTokenSwapAmount[address(swapDesc.fromToken)], "ERR_EXCEED_MAX_SWAP_AMOUNT");
        IYPoolVault(YPoolVaults[address(swapDesc.fromToken)]).transferToSwapper(swapDesc.fromToken, swapDesc.amount);

        uint256 toTokenAmountOut;
        CloseSwapResult swapResult;
        if (swapDesc.toToken == swapDesc.fromToken) {
            toTokenAmountOut = swapDesc.amount;
            swapResult = CloseSwapResult.NonSwapped;
        } else {
            require(isWhitelistedAggregatorAdaptor[aggregatorAdaptor], "ERR_INVALID_AGGREGATOR_ADAPTOR");
            uint256 value = (address(swapDesc.fromToken) == ETHER_ADDRESS) ? swapDesc.amount : 0;
            // If the swapDesc.toToken doest not consist of balanceOf, considered as swap failed
            try this.getTokenBalance(swapDesc.toToken, swapDesc.receiver) returns (uint256 balance) {
                toTokenAmountOut = balance;
                if (address(swapDesc.fromToken) != ETHER_ADDRESS) swapDesc.fromToken.safeApprove(aggregatorAdaptor, swapDesc.amount);
                try IDexAggregatorAdaptor(aggregatorAdaptor).swap{value: value}(swapDesc, aggregatorData) {
                    if (address(swapDesc.fromToken) != ETHER_ADDRESS) swapDesc.fromToken.safeApprove(aggregatorAdaptor, 0);
                    toTokenAmountOut = getTokenBalance(swapDesc.toToken, swapDesc.receiver) - toTokenAmountOut;
                    swapResult = CloseSwapResult.Success;
                } catch {
                    swapResult = CloseSwapResult.Failed;
                }
                if (address(swapDesc.fromToken) != ETHER_ADDRESS) swapDesc.fromToken.safeApprove(aggregatorAdaptor, 0);
            } catch {
                swapResult = CloseSwapResult.Failed;
            }
        }
        if (swapResult != CloseSwapResult.Success) {
            _safeTransferAsset(swapDesc.receiver, swapDesc.fromToken, swapDesc.amount);
        }
        emit CloseSwapCompleted(swapResult, fromChainId, fromSwapId);
        emit SwappedForUser(aggregatorAdaptor, swapDesc.fromToken, swapDesc.amount, swapDesc.toToken, toTokenAmountOut, swapDesc.receiver);
    }

    /* ========== RESTRICTED FUNCTIONS (SIGNATURE REQUIRED) ========== */

    /// @notice Claim the asset of a swap request on source chain after YPool worker `closeSwap` on target chain, by providing signatures of validators
    /// Claiming MUST be performed on source chain
    /// @dev Signatures from validators are first sent to SwapValidator contract on Settlement chain to validate a swap request. Then the signatures can be reused here to approve the claim
    /// @param _swapId Swap id of the swap request
    /// @param signatures Signatures of validators
    function claim(uint256 _swapId, bytes[] memory signatures) external whenNotPaused {
        require(startSwapId <= _swapId && _swapId < swapId, "ERR_INVALID_SWAPID");
        require(swapRequests[_swapId].status != RequestStatus.Closed, "ERR_ALREADY_CLOSED");
        swapRequests[_swapId].status = RequestStatus.Closed;

        bytes32 sigId = keccak256(abi.encodePacked(supervisor.VALIDATE_SWAP_IDENTIFIER(), address(this), address(swapValidatorXYChain), chainId, _swapId));
        bytes32 sigIdHash = sigId.toEthSignedMessageHash();
        supervisor.checkSignatures(sigIdHash, signatures);

        SwapRequest memory request = swapRequests[_swapId];
        IYPoolVault yPoolVault = IYPoolVault(YPoolVaults[address(request.YPoolToken)]);
        uint256 value = (address(request.YPoolToken) == ETHER_ADDRESS) ? request.YPoolTokenAmount : 0;
        if (address(request.YPoolToken) != ETHER_ADDRESS) {
            request.YPoolToken.safeApprove(address(yPoolVault), request.YPoolTokenAmount);
        }
        yPoolVault.receiveAssetFromSwapper{value: value}(request.YPoolToken, request.YPoolTokenAmount, request.xyFee, request.gasFee);

        emit SwapCompleted(CompleteSwapType.Claimed, request);
    }

    /// @notice Claim the asset of multiple swap requests on source chain after YPool worker `closeSwap` on eacg target chain, by providing signatures of validators
    /// Claiming MUST be performed on source chain
    /// @dev YPool token of the swap request MUST be the same
    /// @dev Validators sign to the array of swap ids, which is different from signing for `claim`
    /// @param _swapIds Swap ids of the swap requests
    /// @param _YPoolToken Y Pool token
    /// @param signatures Signatures of validators
    function batchClaim(uint256[] calldata _swapIds, address _YPoolToken, bytes[] memory signatures) external whenNotPaused {
        require(YPoolSupportedToken[_YPoolToken], "ERR_INVALID_YPOOL_TOKEN");
        bytes32 sigId = keccak256(abi.encodePacked(supervisor.BATCH_CLAIM_IDENTIFIER(), address(this), address(swapValidatorXYChain), chainId, _swapIds));
        bytes32 sigIdHash = sigId.toEthSignedMessageHash();
        supervisor.checkSignatures(sigIdHash, signatures);

        IERC20 YPoolToken = IERC20(_YPoolToken);
        uint256 totalClaimedAmount;
        uint256 totalXYFee;
        uint256 totalGasFee;
        uint256 _startSwapId = startSwapId;
        for (uint256 i; i < _swapIds.length; i++) {
            uint256 _swapId = _swapIds[i];
            require(_startSwapId <= _swapId && _swapId < swapId, "ERR_INVALID_SWAPID");
            SwapRequest memory request = swapRequests[_swapId];
            require(request.status != RequestStatus.Closed, "ERR_ALREADY_CLOSED");
            require(request.YPoolToken == YPoolToken, "ERR_WRONG_YPOOL_TOKEN");
            totalClaimedAmount += request.YPoolTokenAmount;
            totalXYFee += request.xyFee;
            totalGasFee += request.gasFee;
            swapRequests[_swapId].status = RequestStatus.Closed;
            emit SwapCompleted(CompleteSwapType.FreeClaimed, request);
        }

        IYPoolVault yPoolVault = IYPoolVault(YPoolVaults[_YPoolToken]);
        uint256 value = (_YPoolToken == ETHER_ADDRESS) ? totalClaimedAmount : 0;
        if (_YPoolToken != ETHER_ADDRESS) {
            YPoolToken.safeApprove(address(yPoolVault), totalClaimedAmount);
        }
        yPoolVault.receiveAssetFromSwapper{value: value}(YPoolToken, totalClaimedAmount, totalXYFee, totalGasFee);
    }

    /// @notice Lock an expired swap request by providing signatures of validators
    /// Locking a swap MUST be performed on target chain to prevent YPool worker from closing an expired swap request
    /// @dev Signature collector collects signature from different validators off-chain and call this function
    /// @param fromChainId Source chain id of the swap request
    /// @param fromSwapId Swap id of the swap request
    /// @param signatures Signatures of validators
    function lockCloseSwap(uint32 fromChainId, uint256 fromSwapId, bytes[] memory signatures) external whenNotPaused {
        bytes32 universalSwapId = keccak256(abi.encodePacked(fromChainId, fromSwapId));
        require(!everClosed[universalSwapId], "ERR_ALREADY_CLOSED");
        bytes32 sigId = keccak256(abi.encodePacked(supervisor.LOCK_CLOSE_SWAP_AND_REFUND_IDENTIFIER(), address(this), fromChainId, fromSwapId));
        bytes32 sigIdHash = sigId.toEthSignedMessageHash();
        supervisor.checkSignatures(sigIdHash, signatures);

        everClosed[universalSwapId] = true;
        emit CloseSwapCompleted(CloseSwapResult.Locked, fromChainId, fromSwapId);
    }

    /// @notice Refund user if a swap request is expired or invalidated by providing signatures of validators
    /// A portion of refund will be taken away as gas fee compensation to execute the refund
    /// Refund MUST be performed on source chain
    /// @param _swapId Swap id of the swap request
    /// @param gasFeeReceiver Address that receives gas fees
    /// @param signatures Signatures of validators
    function refund(uint256 _swapId, address gasFeeReceiver, bytes[] memory signatures) external whenNotPaused {
        require(_swapId < swapId, "ERR_INVALID_SWAPID");
        require(swapRequests[_swapId].status != RequestStatus.Closed, "ERR_ALREADY_CLOSED");
        swapRequests[_swapId].status = RequestStatus.Closed;

        bytes32 sigId = keccak256(abi.encodePacked(supervisor.LOCK_CLOSE_SWAP_AND_REFUND_IDENTIFIER(), address(this), chainId, _swapId, gasFeeReceiver));
        bytes32 sigIdHash = sigId.toEthSignedMessageHash();
        supervisor.checkSignatures(sigIdHash, signatures);

        SwapRequest memory request = swapRequests[_swapId];
        (, uint256 refundGasFee) = _calculateFee(chainId, request.YPoolToken, request.YPoolTokenAmount);
        _safeTransferAsset(request.sender, request.YPoolToken, request.YPoolTokenAmount - refundGasFee);
        _safeTransferAsset(gasFeeReceiver, request.YPoolToken, refundGasFee);

        emit SwapCompleted(CompleteSwapType.Refunded, request);
    }

    /* ========== WRITE FUNCTIONS ========== */

    /// @notice This functions is called by user to initiate a swap. User swaps his/her token for YPool token on this chain and provide info for the swap on target chain. A swap request will be created for each swap.
    /// @dev swapDesc is the swap info for swapping on DEX on this chain, not the swap request
    /// @param aggregatorAdaptor The address of the adaptor of the specific dex aggregator
    /// @param swapDesc Description of the swap on DEX, see IDexAggregatorAdaptor.SwapDescription
    /// @param aggregatorData Raw data consists of instructions to swap user's token for YPool token
    /// @param toChainDesc Description of the swap on target chain, see ToChainDescription
    function swap(
        address aggregatorAdaptor,
        IDexAggregatorAdaptor.SwapDescription memory swapDesc,
        bytes memory aggregatorData,
        ToChainDescription calldata toChainDesc
    ) external payable acceptSwap whenNotPaused nonReentrant {
        require(swapIdIsSet, "ERR_SWAP_ID_NOT_SET");
        address receiver = swapDesc.receiver;
        IERC20 fromToken = swapDesc.fromToken;
        IERC20 YPoolToken = swapDesc.toToken;
        require(YPoolSupportedToken[address(YPoolToken)], "ERR_INVALID_YPOOL_TOKEN");

        uint256 fromTokenAmount = swapDesc.amount;
        uint256 yBalance;
        _safeTransferFromAsset(fromToken, msg.sender, fromTokenAmount);
        if (fromToken == YPoolToken) {
            yBalance = fromTokenAmount;
        } else {
            require(isWhitelistedAggregatorAdaptor[aggregatorAdaptor], "ERR_INVALID_AGGREGATOR_ADAPTOR");
            yBalance = getTokenBalance(YPoolToken, address(this));
            swapDesc.receiver = address(this);
            if (address(fromToken) != ETHER_ADDRESS) fromToken.safeApprove(aggregatorAdaptor, fromTokenAmount);
            IDexAggregatorAdaptor(aggregatorAdaptor).swap{value: msg.value}(swapDesc, aggregatorData);
            if (address(fromToken) != ETHER_ADDRESS) fromToken.safeApprove(aggregatorAdaptor, 0);
            yBalance = getTokenBalance(YPoolToken, address(this)) - yBalance;
        }
        require(_checkMinimumSwapAmount(toChainDesc.toChainId, YPoolToken, yBalance), "ERR_NOT_ENOUGH_SWAP_AMOUNT");
        require(yBalance <= maxYPoolTokenSwapAmount[address(YPoolToken)], "ERR_EXCEED_MAX_SWAP_AMOUNT");

        // Calculate XY fee and gas fee for closeSwap on toChain
        // NOTE: XY fee already includes gas fee and gas fee is computed here only for bookkeeping purpose
        (uint256 xyFee, uint256 closeSwapGasFee) = _calculateFee(toChainDesc.toChainId, YPoolToken, yBalance);
        SwapRequest memory request = SwapRequest(toChainDesc.toChainId, swapId, receiver, msg.sender, yBalance, xyFee, closeSwapGasFee, YPoolToken, RequestStatus.Open);
        swapRequests[swapId] = request;
        emit SwapRequested(swapId++, aggregatorAdaptor, toChainDesc, fromToken, YPoolToken, yBalance, receiver, xyFee, closeSwapGasFee);
    }

    /* ========== EVENTS ========== */

    // Owner events
    event StartSwapIdSet(uint256 _swapId);
    event FeeStructureSet(uint32 _toChainId, address _YPoolToken, uint256 _gas, uint256 _min, uint256 _max, uint256 _rate, uint256 _decimals);
    event YPoolVaultSet(address _supportedToken, address _vault, bool _isSet);
    event AggregatorAdaptorSet(address _aggregator, bool _isSet);
    event SwapValidatorXYChainSet(address _swapValidatorXYChain);
    event AcceptSwapRequestSet(bool _isSet);
    // Swap events
    event SwapRequested(uint256 _swapId, address indexed _aggregatorAdaptor, ToChainDescription _toChainDesc, IERC20 _fromToken, IERC20 indexed _YPoolToken, uint256 _YPoolTokenAmount, address _receiver, uint256 _xyFee, uint256 _gasFee);
    event SwapCompleted(CompleteSwapType _closeType, SwapRequest _swapRequest);
    event CloseSwapCompleted(CloseSwapResult _swapResult, uint32 _fromChainId, uint256 _fromSwapId);
    event SwappedForUser(address indexed _aggregatorAdaptor, IERC20 indexed _fromToken, uint256 _fromTokenAmount, IERC20 _toToken, uint256 _toTokenAmountOut, address _receiver);
}

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

/**
 * @dev Collection of functions related to the address type
 */
library Address {
    /**
     * @dev Returns true if `account` is a contract.
     *
     * [IMPORTANT]
     * ====
     * It is unsafe to assume that an address for which this function returns
     * false is an externally-owned account (EOA) and not a contract.
     *
     * Among others, `isContract` will return false for the following
     * types of addresses:
     *
     *  - an externally-owned account
     *  - a contract in construction
     *  - an address where a contract will be created
     *  - an address where a contract lived, but was destroyed
     * ====
     */
    function isContract(address account) internal view returns (bool) {
        // This method relies on extcodesize, which returns 0 for contracts in
        // construction, since the code is only stored at the end of the
        // constructor execution.

        uint256 size;
        assembly {
            size := extcodesize(account)
        }
        return size > 0;
    }

    /**
     * @dev Replacement for Solidity's `transfer`: sends `amount` wei to
     * `recipient`, forwarding all available gas and reverting on errors.
     *
     * https://eips.ethereum.org/EIPS/eip-1884[EIP1884] increases the gas cost
     * of certain opcodes, possibly making contracts go over the 2300 gas limit
     * imposed by `transfer`, making them unable to receive funds via
     * `transfer`. {sendValue} removes this limitation.
     *
     * https://diligence.consensys.net/posts/2019/09/stop-using-soliditys-transfer-now/[Learn more].
     *
     * IMPORTANT: because control is transferred to `recipient`, care must be
     * taken to not create reentrancy vulnerabilities. Consider using
     * {ReentrancyGuard} or the
     * https://solidity.readthedocs.io/en/v0.5.11/security-considerations.html#use-the-checks-effects-interactions-pattern[checks-effects-interactions pattern].
     */
    function sendValue(address payable recipient, uint256 amount) internal {
        require(address(this).balance >= amount, "Address: insufficient balance");

        (bool success, ) = recipient.call{value: amount}("");
        require(success, "Address: unable to send value, recipient may have reverted");
    }

    /**
     * @dev Performs a Solidity function call using a low level `call`. A
     * plain `call` is an unsafe replacement for a function call: use this
     * function instead.
     *
     * If `target` reverts with a revert reason, it is bubbled up by this
     * function (like regular Solidity function calls).
     *
     * Returns the raw returned data. To convert to the expected return value,
     * use https://solidity.readthedocs.io/en/latest/units-and-global-variables.html?highlight=abi.decode#abi-encoding-and-decoding-functions[`abi.decode`].
     *
     * Requirements:
     *
     * - `target` must be a contract.
     * - calling `target` with `data` must not revert.
     *
     * _Available since v3.1._
     */
    function functionCall(address target, bytes memory data) internal returns (bytes memory) {
        return functionCall(target, data, "Address: low-level call failed");
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-}[`functionCall`], but with
     * `errorMessage` as a fallback revert reason when `target` reverts.
     *
     * _Available since v3.1._
     */
    function functionCall(
        address target,
        bytes memory data,
        string memory errorMessage
    ) internal returns (bytes memory) {
        return functionCallWithValue(target, data, 0, errorMessage);
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-}[`functionCall`],
     * but also transferring `value` wei to `target`.
     *
     * Requirements:
     *
     * - the calling contract must have an ETH balance of at least `value`.
     * - the called Solidity function must be `payable`.
     *
     * _Available since v3.1._
     */
    function functionCallWithValue(
        address target,
        bytes memory data,
        uint256 value
    ) internal returns (bytes memory) {
        return functionCallWithValue(target, data, value, "Address: low-level call with value failed");
    }

    /**
     * @dev Same as {xref-Address-functionCallWithValue-address-bytes-uint256-}[`functionCallWithValue`], but
     * with `errorMessage` as a fallback revert reason when `target` reverts.
     *
     * _Available since v3.1._
     */
    function functionCallWithValue(
        address target,
        bytes memory data,
        uint256 value,
        string memory errorMessage
    ) internal returns (bytes memory) {
        require(address(this).balance >= value, "Address: insufficient balance for call");
        require(isContract(target), "Address: call to non-contract");

        (bool success, bytes memory returndata) = target.call{value: value}(data);
        return verifyCallResult(success, returndata, errorMessage);
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-}[`functionCall`],
     * but performing a static call.
     *
     * _Available since v3.3._
     */
    function functionStaticCall(address target, bytes memory data) internal view returns (bytes memory) {
        return functionStaticCall(target, data, "Address: low-level static call failed");
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-string-}[`functionCall`],
     * but performing a static call.
     *
     * _Available since v3.3._
     */
    function functionStaticCall(
        address target,
        bytes memory data,
        string memory errorMessage
    ) internal view returns (bytes memory) {
        require(isContract(target), "Address: static call to non-contract");

        (bool success, bytes memory returndata) = target.staticcall(data);
        return verifyCallResult(success, returndata, errorMessage);
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-}[`functionCall`],
     * but performing a delegate call.
     *
     * _Available since v3.4._
     */
    function functionDelegateCall(address target, bytes memory data) internal returns (bytes memory) {
        return functionDelegateCall(target, data, "Address: low-level delegate call failed");
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-string-}[`functionCall`],
     * but performing a delegate call.
     *
     * _Available since v3.4._
     */
    function functionDelegateCall(
        address target,
        bytes memory data,
        string memory errorMessage
    ) internal returns (bytes memory) {
        require(isContract(target), "Address: delegate call to non-contract");

        (bool success, bytes memory returndata) = target.delegatecall(data);
        return verifyCallResult(success, returndata, errorMessage);
    }

    /**
     * @dev Tool to verifies that a low level call was successful, and revert if it wasn't, either by bubbling the
     * revert reason using the provided one.
     *
     * _Available since v4.3._
     */
    function verifyCallResult(
        bool success,
        bytes memory returndata,
        string memory errorMessage
    ) internal pure returns (bytes memory) {
        if (success) {
            return returndata;
        } else {
            // Look for revert reason and bubble it up if present
            if (returndata.length > 0) {
                // The easiest way to bubble the revert reason is using memory via assembly

                assembly {
                    let returndata_size := mload(returndata)
                    revert(add(32, returndata), returndata_size)
                }
            } else {
                revert(errorMessage);
            }
        }
    }
}

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "IAccessControlUpgradeable.sol";
import "ContextUpgradeable.sol";
import "StringsUpgradeable.sol";
import "ERC165Upgradeable.sol";
import "Initializable.sol";

/**
 * @dev Contract module that allows children to implement role-based access
 * control mechanisms. This is a lightweight version that doesn't allow enumerating role
 * members except through off-chain means by accessing the contract event logs. Some
 * applications may benefit from on-chain enumerability, for those cases see
 * {AccessControlEnumerable}.
 *
 * Roles are referred to by their `bytes32` identifier. These should be exposed
 * in the external API and be unique. The best way to achieve this is by
 * using `public constant` hash digests:
 *
 * ```
 * bytes32 public constant MY_ROLE = keccak256("MY_ROLE");
 * ```
 *
 * Roles can be used to represent a set of permissions. To restrict access to a
 * function call, use {hasRole}:
 *
 * ```
 * function foo() public {
 *     require(hasRole(MY_ROLE, msg.sender));
 *     ...
 * }
 * ```
 *
 * Roles can be granted and revoked dynamically via the {grantRole} and
 * {revokeRole} functions. Each role has an associated admin role, and only
 * accounts that have a role's admin role can call {grantRole} and {revokeRole}.
 *
 * By default, the admin role for all roles is `DEFAULT_ADMIN_ROLE`, which means
 * that only accounts with this role will be able to grant or revoke other
 * roles. More complex role relationships can be created by using
 * {_setRoleAdmin}.
 *
 * WARNING: The `DEFAULT_ADMIN_ROLE` is also its own admin: it has permission to
 * grant and revoke this role. Extra precautions should be taken to secure
 * accounts that have been granted it.
 */
abstract contract AccessControlUpgradeable is Initializable, ContextUpgradeable, IAccessControlUpgradeable, ERC165Upgradeable {
    function __AccessControl_init() internal initializer {
        __Context_init_unchained();
        __ERC165_init_unchained();
        __AccessControl_init_unchained();
    }

    function __AccessControl_init_unchained() internal initializer {
    }
    struct RoleData {
        mapping(address => bool) members;
        bytes32 adminRole;
    }

    mapping(bytes32 => RoleData) private _roles;

    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;

    /**
     * @dev Modifier that checks that an account has a specific role. Reverts
     * with a standardized message including the required role.
     *
     * The format of the revert reason is given by the following regular expression:
     *
     *  /^AccessControl: account (0x[0-9a-f]{40}) is missing role (0x[0-9a-f]{64})$/
     *
     * _Available since v4.1._
     */
    modifier onlyRole(bytes32 role) {
        _checkRole(role, _msgSender());
        _;
    }

    /**
     * @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IAccessControlUpgradeable).interfaceId || super.supportsInterface(interfaceId);
    }

    /**
     * @dev Returns `true` if `account` has been granted `role`.
     */
    function hasRole(bytes32 role, address account) public view override returns (bool) {
        return _roles[role].members[account];
    }

    /**
     * @dev Revert with a standard message if `account` is missing `role`.
     *
     * The format of the revert reason is given by the following regular expression:
     *
     *  /^AccessControl: account (0x[0-9a-f]{40}) is missing role (0x[0-9a-f]{64})$/
     */
    function _checkRole(bytes32 role, address account) internal view {
        if (!hasRole(role, account)) {
            revert(
                string(
                    abi.encodePacked(
                        "AccessControl: account ",
                        StringsUpgradeable.toHexString(uint160(account), 20),
                        " is missing role ",
                        StringsUpgradeable.toHexString(uint256(role), 32)
                    )
                )
            );
        }
    }

    /**
     * @dev Returns the admin role that controls `role`. See {grantRole} and
     * {revokeRole}.
     *
     * To change a role's admin, use {_setRoleAdmin}.
     */
    function getRoleAdmin(bytes32 role) public view override returns (bytes32) {
        return _roles[role].adminRole;
    }

    /**
     * @dev Grants `role` to `account`.
     *
     * If `account` had not been already granted `role`, emits a {RoleGranted}
     * event.
     *
     * Requirements:
     *
     * - the caller must have ``role``'s admin role.
     */
    function grantRole(bytes32 role, address account) public virtual override onlyRole(getRoleAdmin(role)) {
        _grantRole(role, account);
    }

    /**
     * @dev Revokes `role` from `account`.
     *
     * If `account` had been granted `role`, emits a {RoleRevoked} event.
     *
     * Requirements:
     *
     * - the caller must have ``role``'s admin role.
     */
    function revokeRole(bytes32 role, address account) public virtual override onlyRole(getRoleAdmin(role)) {
        _revokeRole(role, account);
    }

    /**
     * @dev Revokes `role` from the calling account.
     *
     * Roles are often managed via {grantRole} and {revokeRole}: this function's
     * purpose is to provide a mechanism for accounts to lose their privileges
     * if they are compromised (such as when a trusted device is misplaced).
     *
     * If the calling account had been granted `role`, emits a {RoleRevoked}
     * event.
     *
     * Requirements:
     *
     * - the caller must be `account`.
     */
    function renounceRole(bytes32 role, address account) public virtual override {
        require(account == _msgSender(), "AccessControl: can only renounce roles for self");

        _revokeRole(role, account);
    }

    /**
     * @dev Grants `role` to `account`.
     *
     * If `account` had not been already granted `role`, emits a {RoleGranted}
     * event. Note that unlike {grantRole}, this function doesn't perform any
     * checks on the calling account.
     *
     * [WARNING]
     * ====
     * This function should only be called from the constructor when setting
     * up the initial roles for the system.
     *
     * Using this function in any other way is effectively circumventing the admin
     * system imposed by {AccessControl}.
     * ====
     */
    function _setupRole(bytes32 role, address account) internal virtual {
        _grantRole(role, account);
    }

    /**
     * @dev Sets `adminRole` as ``role``'s admin role.
     *
     * Emits a {RoleAdminChanged} event.
     */
    function _setRoleAdmin(bytes32 role, bytes32 adminRole) internal virtual {
        bytes32 previousAdminRole = getRoleAdmin(role);
        _roles[role].adminRole = adminRole;
        emit RoleAdminChanged(role, previousAdminRole, adminRole);
    }

    function _grantRole(bytes32 role, address account) private {
        if (!hasRole(role, account)) {
            _roles[role].members[account] = true;
            emit RoleGranted(role, account, _msgSender());
        }
    }

    function _revokeRole(bytes32 role, address account) private {
        if (hasRole(role, account)) {
            _roles[role].members[account] = false;
            emit RoleRevoked(role, account, _msgSender());
        }
    }
    uint256[49] private __gap;
}

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

/**
 * @dev External interface of AccessControl declared to support ERC165 detection.
 */
interface IAccessControlUpgradeable {
    /**
     * @dev Emitted when `newAdminRole` is set as ``role``'s admin role, replacing `previousAdminRole`
     *
     * `DEFAULT_ADMIN_ROLE` is the starting admin for all roles, despite
     * {RoleAdminChanged} not being emitted signaling this.
     *
     * _Available since v3.1._
     */
    event RoleAdminChanged(bytes32 indexed role, bytes32 indexed previousAdminRole, bytes32 indexed newAdminRole);

    /**
     * @dev Emitted when `account` is granted `role`.
     *
     * `sender` is the account that originated the contract call, an admin role
     * bearer except when using {AccessControl-_setupRole}.
     */
    event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender);

    /**
     * @dev Emitted when `account` is revoked `role`.
     *
     * `sender` is the account that originated the contract call:
     *   - if using `revokeRole`, it is the admin role bearer
     *   - if using `renounceRole`, it is the role bearer (i.e. `account`)
     */
    event RoleRevoked(bytes32 indexed role, address indexed account, address indexed sender);

    /**
     * @dev Returns `true` if `account` has been granted `role`.
     */
    function hasRole(bytes32 role, address account) external view returns (bool);

    /**
     * @dev Returns the admin role that controls `role`. See {grantRole} and
     * {revokeRole}.
     *
     * To change a role's admin, use {AccessControl-_setRoleAdmin}.
     */
    function getRoleAdmin(bytes32 role) external view returns (bytes32);

    /**
     * @dev Grants `role` to `account`.
     *
     * If `account` had not been already granted `role`, emits a {RoleGranted}
     * event.
     *
     * Requirements:
     *
     * - the caller must have ``role``'s admin role.
     */
    function grantRole(bytes32 role, address account) external;

    /**
     * @dev Revokes `role` from `account`.
     *
     * If `account` had been granted `role`, emits a {RoleRevoked} event.
     *
     * Requirements:
     *
     * - the caller must have ``role``'s admin role.
     */
    function revokeRole(bytes32 role, address account) external;

    /**
     * @dev Revokes `role` from the calling account.
     *
     * Roles are often managed via {grantRole} and {revokeRole}: this function's
     * purpose is to provide a mechanism for accounts to lose their privileges
     * if they are compromised (such as when a trusted device is misplaced).
     *
     * If the calling account had been granted `role`, emits a {RoleRevoked}
     * event.
     *
     * Requirements:
     *
     * - the caller must be `account`.
     */
    function renounceRole(bytes32 role, address account) external;
}

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;
import "Initializable.sol";

/**
 * @dev Provides information about the current execution context, including the
 * sender of the transaction and its data. While these are generally available
 * via msg.sender and msg.data, they should not be accessed in such a direct
 * manner, since when dealing with meta-transactions the account sending and
 * paying for execution may not be the actual sender (as far as an application
 * is concerned).
 *
 * This contract is only required for intermediate, library-like contracts.
 */
abstract contract ContextUpgradeable is Initializable {
    function __Context_init() internal initializer {
        __Context_init_unchained();
    }

    function __Context_init_unchained() internal initializer {
    }
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }

    function _msgData() internal view virtual returns (bytes calldata) {
        return msg.data;
    }
    uint256[50] private __gap;
}

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

/**
 * @dev This is a base contract to aid in writing upgradeable contracts, or any kind of contract that will be deployed
 * behind a proxy. Since a proxied contract can't have a constructor, it's common to move constructor logic to an
 * external initializer function, usually called `initialize`. It then becomes necessary to protect this initializer
 * function so it can only be called once. The {initializer} modifier provided by this contract will have this effect.
 *
 * TIP: To avoid leaving the proxy in an uninitialized state, the initializer function should be called as early as
 * possible by providing the encoded function call as the `_data` argument to {ERC1967Proxy-constructor}.
 *
 * CAUTION: When used with inheritance, manual care must be taken to not invoke a parent initializer twice, or to ensure
 * that all initializers are idempotent. This is not verified automatically as constructors are by Solidity.
 */
abstract contract Initializable {
    /**
     * @dev Indicates that the contract has been initialized.
     */
    bool private _initialized;

    /**
     * @dev Indicates that the contract is in the process of being initialized.
     */
    bool private _initializing;

    /**
     * @dev Modifier to protect an initializer function from being invoked twice.
     */
    modifier initializer() {
        require(_initializing || !_initialized, "Initializable: contract is already initialized");

        bool isTopLevelCall = !_initializing;
        if (isTopLevelCall) {
            _initializing = true;
            _initialized = true;
        }

        _;

        if (isTopLevelCall) {
            _initializing = false;
        }
    }
}

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

/**
 * @dev String operations.
 */
library StringsUpgradeable {
    bytes16 private constant _HEX_SYMBOLS = "0123456789abcdef";

    /**
     * @dev Converts a `uint256` to its ASCII `string` decimal representation.
     */
    function toString(uint256 value) internal pure returns (string memory) {
        // Inspired by OraclizeAPI's implementation - MIT licence
        // https://github.com/oraclize/ethereum-api/blob/b42146b063c7d6ee1358846c198246239e9360e8/oraclizeAPI_0.4.25.sol

        if (value == 0) {
            return "0";
        }
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }

    /**
     * @dev Converts a `uint256` to its ASCII `string` hexadecimal representation.
     */
    function toHexString(uint256 value) internal pure returns (string memory) {
        if (value == 0) {
            return "0x00";
        }
        uint256 temp = value;
        uint256 length = 0;
        while (temp != 0) {
            length++;
            temp >>= 8;
        }
        return toHexString(value, length);
    }

    /**
     * @dev Converts a `uint256` to its ASCII `string` hexadecimal representation with fixed length.
     */
    function toHexString(uint256 value, uint256 length) internal pure returns (string memory) {
        bytes memory buffer = new bytes(2 * length + 2);
        buffer[0] = "0";
        buffer[1] = "x";
        for (uint256 i = 2 * length + 1; i > 1; --i) {
            buffer[i] = _HEX_SYMBOLS[value & 0xf];
            value >>= 4;
        }
        require(value == 0, "Strings: hex length insufficient");
        return string(buffer);
    }
}

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "IERC165Upgradeable.sol";
import "Initializable.sol";

/**
 * @dev Implementation of the {IERC165} interface.
 *
 * Contracts that want to implement ERC165 should inherit from this contract and override {supportsInterface} to check
 * for the additional interface id that will be supported. For example:
 *
 * ```solidity
 * function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
 *     return interfaceId == type(MyInterface).interfaceId || super.supportsInterface(interfaceId);
 * }
 * ```
 *
 * Alternatively, {ERC165Storage} provides an easier to use but more expensive implementation.
 */
abstract contract ERC165Upgradeable is Initializable, IERC165Upgradeable {
    function __ERC165_init() internal initializer {
        __ERC165_init_unchained();
    }

    function __ERC165_init_unchained() internal initializer {
    }
    /**
     * @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IERC165Upgradeable).interfaceId;
    }
    uint256[50] private __gap;
}

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

/**
 * @dev Interface of the ERC165 standard, as defined in the
 * https://eips.ethereum.org/EIPS/eip-165[EIP].
 *
 * Implementers can declare support of contract interfaces, which can then be
 * queried by others ({ERC165Checker}).
 *
 * For an implementation, see {ERC165}.
 */
interface IERC165Upgradeable {
    /**
     * @dev Returns true if this contract implements the interface defined by
     * `interfaceId`. See the corresponding
     * https://eips.ethereum.org/EIPS/eip-165#how-interfaces-are-identified[EIP section]
     * to learn more about how these ids are created.
     *
     * This function call must use less than 30 000 gas.
     */
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "ERC1967UpgradeUpgradeable.sol";
import "Initializable.sol";

/**
 * @dev An upgradeability mechanism designed for UUPS proxies. The functions included here can perform an upgrade of an
 * {ERC1967Proxy}, when this contract is set as the implementation behind such a proxy.
 *
 * A security mechanism ensures that an upgrade does not turn off upgradeability accidentally, although this risk is
 * reinstated if the upgrade retains upgradeability but removes the security mechanism, e.g. by replacing
 * `UUPSUpgradeable` with a custom implementation of upgrades.
 *
 * The {_authorizeUpgrade} function must be overridden to include access restriction to the upgrade mechanism.
 *
 * _Available since v4.1._
 */
abstract contract UUPSUpgradeable is Initializable, ERC1967UpgradeUpgradeable {
    function __UUPSUpgradeable_init() internal initializer {
        __ERC1967Upgrade_init_unchained();
        __UUPSUpgradeable_init_unchained();
    }

    function __UUPSUpgradeable_init_unchained() internal initializer {
    }
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable state-variable-assignment
    address private immutable __self = address(this);

    /**
     * @dev Check that the execution is being performed through a delegatecall call and that the execution context is
     * a proxy contract with an implementation (as defined in ERC1967) pointing to self. This should only be the case
     * for UUPS and transparent proxies that are using the current contract as their implementation. Execution of a
     * function through ERC1167 minimal proxies (clones) would not normally pass this test, but is not guaranteed to
     * fail.
     */
    modifier onlyProxy() {
        require(address(this) != __self, "Function must be called through delegatecall");
        require(_getImplementation() == __self, "Function must be called through active proxy");
        _;
    }

    /**
     * @dev Upgrade the implementation of the proxy to `newImplementation`.
     *
     * Calls {_authorizeUpgrade}.
     *
     * Emits an {Upgraded} event.
     */
    function upgradeTo(address newImplementation) external virtual onlyProxy {
        _authorizeUpgrade(newImplementation);
        _upgradeToAndCallSecure(newImplementation, new bytes(0), false);
    }

    /**
     * @dev Upgrade the implementation of the proxy to `newImplementation`, and subsequently execute the function call
     * encoded in `data`.
     *
     * Calls {_authorizeUpgrade}.
     *
     * Emits an {Upgraded} event.
     */
    function upgradeToAndCall(address newImplementation, bytes memory data) external payable virtual onlyProxy {
        _authorizeUpgrade(newImplementation);
        _upgradeToAndCallSecure(newImplementation, data, true);
    }

    /**
     * @dev Function that should revert when `msg.sender` is not authorized to upgrade the contract. Called by
     * {upgradeTo} and {upgradeToAndCall}.
     *
     * Normally, this function will use an xref:access.adoc[access control] modifier such as {Ownable-onlyOwner}.
     *
     * ```solidity
     * function _authorizeUpgrade(address) internal override onlyOwner {}
     * ```
     */
    function _authorizeUpgrade(address newImplementation) internal virtual;
    uint256[50] private __gap;
}

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.2;

import "IBeaconUpgradeable.sol";
import "AddressUpgradeable.sol";
import "StorageSlotUpgradeable.sol";
import "Initializable.sol";

/**
 * @dev This abstract contract provides getters and event emitting update functions for
 * https://eips.ethereum.org/EIPS/eip-1967[EIP1967] slots.
 *
 * _Available since v4.1._
 *
 * @custom:oz-upgrades-unsafe-allow delegatecall
 */
abstract contract ERC1967UpgradeUpgradeable is Initializable {
    function __ERC1967Upgrade_init() internal initializer {
        __ERC1967Upgrade_init_unchained();
    }

    function __ERC1967Upgrade_init_unchained() internal initializer {
    }
    // This is the keccak-256 hash of "eip1967.proxy.rollback" subtracted by 1
    bytes32 private constant _ROLLBACK_SLOT = 0x4910fdfa16fed3260ed0e7147f7cc6da11a60208b5b9406d12a635614ffd9143;

    /**
     * @dev Storage slot with the address of the current implementation.
     * This is the keccak-256 hash of "eip1967.proxy.implementation" subtracted by 1, and is
     * validated in the constructor.
     */
    bytes32 internal constant _IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    /**
     * @dev Emitted when the implementation is upgraded.
     */
    event Upgraded(address indexed implementation);

    /**
     * @dev Returns the current implementation address.
     */
    function _getImplementation() internal view returns (address) {
        return StorageSlotUpgradeable.getAddressSlot(_IMPLEMENTATION_SLOT).value;
    }

    /**
     * @dev Stores a new address in the EIP1967 implementation slot.
     */
    function _setImplementation(address newImplementation) private {
        require(AddressUpgradeable.isContract(newImplementation), "ERC1967: new implementation is not a contract");
        StorageSlotUpgradeable.getAddressSlot(_IMPLEMENTATION_SLOT).value = newImplementation;
    }

    /**
     * @dev Perform implementation upgrade
     *
     * Emits an {Upgraded} event.
     */
    function _upgradeTo(address newImplementation) internal {
        _setImplementation(newImplementation);
        emit Upgraded(newImplementation);
    }

    /**
     * @dev Perform implementation upgrade with additional setup call.
     *
     * Emits an {Upgraded} event.
     */
    function _upgradeToAndCall(
        address newImplementation,
        bytes memory data,
        bool forceCall
    ) internal {
        _upgradeTo(newImplementation);
        if (data.length > 0 || forceCall) {
            _functionDelegateCall(newImplementation, data);
        }
    }

    /**
     * @dev Perform implementation upgrade with security checks for UUPS proxies, and additional setup call.
     *
     * Emits an {Upgraded} event.
     */
    function _upgradeToAndCallSecure(
        address newImplementation,
        bytes memory data,
        bool forceCall
    ) internal {
        address oldImplementation = _getImplementation();

        // Initial upgrade and setup call
        _setImplementation(newImplementation);
        if (data.length > 0 || forceCall) {
            _functionDelegateCall(newImplementation, data);
        }

        // Perform rollback test if not already in progress
        StorageSlotUpgradeable.BooleanSlot storage rollbackTesting = StorageSlotUpgradeable.getBooleanSlot(_ROLLBACK_SLOT);
        if (!rollbackTesting.value) {
            // Trigger rollback using upgradeTo from the new implementation
            rollbackTesting.value = true;
            _functionDelegateCall(
                newImplementation,
                abi.encodeWithSignature("upgradeTo(address)", oldImplementation)
            );
            rollbackTesting.value = false;
            // Check rollback was effective
            require(oldImplementation == _getImplementation(), "ERC1967Upgrade: upgrade breaks further upgrades");
            // Finally reset to the new implementation and log the upgrade
            _upgradeTo(newImplementation);
        }
    }

    /**
     * @dev Storage slot with the admin of the contract.
     * This is the keccak-256 hash of "eip1967.proxy.admin" subtracted by 1, and is
     * validated in the constructor.
     */
    bytes32 internal constant _ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    /**
     * @dev Emitted when the admin account has changed.
     */
    event AdminChanged(address previousAdmin, address newAdmin);

    /**
     * @dev Returns the current admin.
     */
    function _getAdmin() internal view returns (address) {
        return StorageSlotUpgradeable.getAddressSlot(_ADMIN_SLOT).value;
    }

    /**
     * @dev Stores a new address in the EIP1967 admin slot.
     */
    function _setAdmin(address newAdmin) private {
        require(newAdmin != address(0), "ERC1967: new admin is the zero address");
        StorageSlotUpgradeable.getAddressSlot(_ADMIN_SLOT).value = newAdmin;
    }

    /**
     * @dev Changes the admin of the proxy.
     *
     * Emits an {AdminChanged} event.
     */
    function _changeAdmin(address newAdmin) internal {
        emit AdminChanged(_getAdmin(), newAdmin);
        _setAdmin(newAdmin);
    }

    /**
     * @dev The storage slot of the UpgradeableBeacon contract which defines the implementation for this proxy.
     * This is bytes32(uint256(keccak256('eip1967.proxy.beacon')) - 1)) and is validated in the constructor.
     */
    bytes32 internal constant _BEACON_SLOT = 0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50;

    /**
     * @dev Emitted when the beacon is upgraded.
     */
    event BeaconUpgraded(address indexed beacon);

    /**
     * @dev Returns the current beacon.
     */
    function _getBeacon() internal view returns (address) {
        return StorageSlotUpgradeable.getAddressSlot(_BEACON_SLOT).value;
    }

    /**
     * @dev Stores a new beacon in the EIP1967 beacon slot.
     */
    function _setBeacon(address newBeacon) private {
        require(AddressUpgradeable.isContract(newBeacon), "ERC1967: new beacon is not a contract");
        require(
            AddressUpgradeable.isContract(IBeaconUpgradeable(newBeacon).implementation()),
            "ERC1967: beacon implementation is not a contract"
        );
        StorageSlotUpgradeable.getAddressSlot(_BEACON_SLOT).value = newBeacon;
    }

    /**
     * @dev Perform beacon upgrade with additional setup call. Note: This upgrades the address of the beacon, it does
     * not upgrade the implementation contained in the beacon (see {UpgradeableBeacon-_setImplementation} for that).
     *
     * Emits a {BeaconUpgraded} event.
     */
    function _upgradeBeaconToAndCall(
        address newBeacon,
        bytes memory data,
        bool forceCall
    ) internal {
        _setBeacon(newBeacon);
        emit BeaconUpgraded(newBeacon);
        if (data.length > 0 || forceCall) {
            _functionDelegateCall(IBeaconUpgradeable(newBeacon).implementation(), data);
        }
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-string-}[`functionCall`],
     * but performing a delegate call.
     *
     * _Available since v3.4._
     */
    function _functionDelegateCall(address target, bytes memory data) private returns (bytes memory) {
        require(AddressUpgradeable.isContract(target), "Address: delegate call to non-contract");

        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory returndata) = target.delegatecall(data);
        return AddressUpgradeable.verifyCallResult(success, returndata, "Address: low-level delegate call failed");
    }
    uint256[50] private __gap;
}

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

/**
 * @dev This is the interface that {BeaconProxy} expects of its beacon.
 */
interface IBeaconUpgradeable {
    /**
     * @dev Must return an address that can be used as a delegate call target.
     *
     * {BeaconProxy} will check that this address is a contract.
     */
    function implementation() external view returns (address);
}

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

/**
 * @dev Collection of functions related to the address type
 */
library AddressUpgradeable {
    /**
     * @dev Returns true if `account` is a contract.
     *
     * [IMPORTANT]
     * ====
     * It is unsafe to assume that an address for which this function returns
     * false is an externally-owned account (EOA) and not a contract.
     *
     * Among others, `isContract` will return false for the following
     * types of addresses:
     *
     *  - an externally-owned account
     *  - a contract in construction
     *  - an address where a contract will be created
     *  - an address where a contract lived, but was destroyed
     * ====
     */
    function isContract(address account) internal view returns (bool) {
        // This method relies on extcodesize, which returns 0 for contracts in
        // construction, since the code is only stored at the end of the
        // constructor execution.

        uint256 size;
        assembly {
            size := extcodesize(account)
        }
        return size > 0;
    }

    /**
     * @dev Replacement for Solidity's `transfer`: sends `amount` wei to
     * `recipient`, forwarding all available gas and reverting on errors.
     *
     * https://eips.ethereum.org/EIPS/eip-1884[EIP1884] increases the gas cost
     * of certain opcodes, possibly making contracts go over the 2300 gas limit
     * imposed by `transfer`, making them unable to receive funds via
     * `transfer`. {sendValue} removes this limitation.
     *
     * https://diligence.consensys.net/posts/2019/09/stop-using-soliditys-transfer-now/[Learn more].
     *
     * IMPORTANT: because control is transferred to `recipient`, care must be
     * taken to not create reentrancy vulnerabilities. Consider using
     * {ReentrancyGuard} or the
     * https://solidity.readthedocs.io/en/v0.5.11/security-considerations.html#use-the-checks-effects-interactions-pattern[checks-effects-interactions pattern].
     */
    function sendValue(address payable recipient, uint256 amount) internal {
        require(address(this).balance >= amount, "Address: insufficient balance");

        (bool success, ) = recipient.call{value: amount}("");
        require(success, "Address: unable to send value, recipient may have reverted");
    }

    /**
     * @dev Performs a Solidity function call using a low level `call`. A
     * plain `call` is an unsafe replacement for a function call: use this
     * function instead.
     *
     * If `target` reverts with a revert reason, it is bubbled up by this
     * function (like regular Solidity function calls).
     *
     * Returns the raw returned data. To convert to the expected return value,
     * use https://solidity.readthedocs.io/en/latest/units-and-global-variables.html?highlight=abi.decode#abi-encoding-and-decoding-functions[`abi.decode`].
     *
     * Requirements:
     *
     * - `target` must be a contract.
     * - calling `target` with `data` must not revert.
     *
     * _Available since v3.1._
     */
    function functionCall(address target, bytes memory data) internal returns (bytes memory) {
        return functionCall(target, data, "Address: low-level call failed");
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-}[`functionCall`], but with
     * `errorMessage` as a fallback revert reason when `target` reverts.
     *
     * _Available since v3.1._
     */
    function functionCall(
        address target,
        bytes memory data,
        string memory errorMessage
    ) internal returns (bytes memory) {
        return functionCallWithValue(target, data, 0, errorMessage);
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-}[`functionCall`],
     * but also transferring `value` wei to `target`.
     *
     * Requirements:
     *
     * - the calling contract must have an ETH balance of at least `value`.
     * - the called Solidity function must be `payable`.
     *
     * _Available since v3.1._
     */
    function functionCallWithValue(
        address target,
        bytes memory data,
        uint256 value
    ) internal returns (bytes memory) {
        return functionCallWithValue(target, data, value, "Address: low-level call with value failed");
    }

    /**
     * @dev Same as {xref-Address-functionCallWithValue-address-bytes-uint256-}[`functionCallWithValue`], but
     * with `errorMessage` as a fallback revert reason when `target` reverts.
     *
     * _Available since v3.1._
     */
    function functionCallWithValue(
        address target,
        bytes memory data,
        uint256 value,
        string memory errorMessage
    ) internal returns (bytes memory) {
        require(address(this).balance >= value, "Address: insufficient balance for call");
        require(isContract(target), "Address: call to non-contract");

        (bool success, bytes memory returndata) = target.call{value: value}(data);
        return verifyCallResult(success, returndata, errorMessage);
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-}[`functionCall`],
     * but performing a static call.
     *
     * _Available since v3.3._
     */
    function functionStaticCall(address target, bytes memory data) internal view returns (bytes memory) {
        return functionStaticCall(target, data, "Address: low-level static call failed");
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-string-}[`functionCall`],
     * but performing a static call.
     *
     * _Available since v3.3._
     */
    function functionStaticCall(
        address target,
        bytes memory data,
        string memory errorMessage
    ) internal view returns (bytes memory) {
        require(isContract(target), "Address: static call to non-contract");

        (bool success, bytes memory returndata) = target.staticcall(data);
        return verifyCallResult(success, returndata, errorMessage);
    }

    /**
     * @dev Tool to verifies that a low level call was successful, and revert if it wasn't, either by bubbling the
     * revert reason using the provided one.
     *
     * _Available since v4.3._
     */
    function verifyCallResult(
        bool success,
        bytes memory returndata,
        string memory errorMessage
    ) internal pure returns (bytes memory) {
        if (success) {
            return returndata;
        } else {
            // Look for revert reason and bubble it up if present
            if (returndata.length > 0) {
                // The easiest way to bubble the revert reason is using memory via assembly

                assembly {
                    let returndata_size := mload(returndata)
                    revert(add(32, returndata), returndata_size)
                }
            } else {
                revert(errorMessage);
            }
        }
    }
}

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

/**
 * @dev Library for reading and writing primitive types to specific storage slots.
 *
 * Storage slots are often used to avoid storage conflict when dealing with upgradeable contracts.
 * This library helps with reading and writing to such slots without the need for inline assembly.
 *
 * The functions in this library return Slot structs that contain a `value` member that can be used to read or write.
 *
 * Example usage to set ERC1967 implementation slot:
 * ```
 * contract ERC1967 {
 *     bytes32 internal constant _IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
 *
 *     function _getImplementation() internal view returns (address) {
 *         return StorageSlot.getAddressSlot(_IMPLEMENTATION_SLOT).value;
 *     }
 *
 *     function _setImplementation(address newImplementation) internal {
 *         require(Address.isContract(newImplementation), "ERC1967: new implementation is not a contract");
 *         StorageSlot.getAddressSlot(_IMPLEMENTATION_SLOT).value = newImplementation;
 *     }
 * }
 * ```
 *
 * _Available since v4.1 for `address`, `bool`, `bytes32`, and `uint256`._
 */
library StorageSlotUpgradeable {
    struct AddressSlot {
        address value;
    }

    struct BooleanSlot {
        bool value;
    }

    struct Bytes32Slot {
        bytes32 value;
    }

    struct Uint256Slot {
        uint256 value;
    }

    /**
     * @dev Returns an `AddressSlot` with member `value` located at `slot`.
     */
    function getAddressSlot(bytes32 slot) internal pure returns (AddressSlot storage r) {
        assembly {
            r.slot := slot
        }
    }

    /**
     * @dev Returns an `BooleanSlot` with member `value` located at `slot`.
     */
    function getBooleanSlot(bytes32 slot) internal pure returns (BooleanSlot storage r) {
        assembly {
            r.slot := slot
        }
    }

    /**
     * @dev Returns an `Bytes32Slot` with member `value` located at `slot`.
     */
    function getBytes32Slot(bytes32 slot) internal pure returns (Bytes32Slot storage r) {
        assembly {
            r.slot := slot
        }
    }

    /**
     * @dev Returns an `Uint256Slot` with member `value` located at `slot`.
     */
    function getUint256Slot(bytes32 slot) internal pure returns (Uint256Slot storage r) {
        assembly {
            r.slot := slot
        }
    }
}

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "ContextUpgradeable.sol";
import "Initializable.sol";

/**
 * @dev Contract module which allows children to implement an emergency stop
 * mechanism that can be triggered by an authorized account.
 *
 * This module is used through inheritance. It will make available the
 * modifiers `whenNotPaused` and `whenPaused`, which can be applied to
 * the functions of your contract. Note that they will not be pausable by
 * simply including this module, only once the modifiers are put in place.
 */
abstract contract PausableUpgradeable is Initializable, ContextUpgradeable {
    /**
     * @dev Emitted when the pause is triggered by `account`.
     */
    event Paused(address account);

    /**
     * @dev Emitted when the pause is lifted by `account`.
     */
    event Unpaused(address account);

    bool private _paused;

    /**
     * @dev Initializes the contract in unpaused state.
     */
    function __Pausable_init() internal initializer {
        __Context_init_unchained();
        __Pausable_init_unchained();
    }

    function __Pausable_init_unchained() internal initializer {
        _paused = false;
    }

    /**
     * @dev Returns true if the contract is paused, and false otherwise.
     */
    function paused() public view virtual returns (bool) {
        return _paused;
    }

    /**
     * @dev Modifier to make a function callable only when the contract is not paused.
     *
     * Requirements:
     *
     * - The contract must not be paused.
     */
    modifier whenNotPaused() {
        require(!paused(), "Pausable: paused");
        _;
    }

    /**
     * @dev Modifier to make a function callable only when the contract is paused.
     *
     * Requirements:
     *
     * - The contract must be paused.
     */
    modifier whenPaused() {
        require(paused(), "Pausable: not paused");
        _;
    }

    /**
     * @dev Triggers stopped state.
     *
     * Requirements:
     *
     * - The contract must not be paused.
     */
    function _pause() internal virtual whenNotPaused {
        _paused = true;
        emit Paused(_msgSender());
    }

    /**
     * @dev Returns to normal state.
     *
     * Requirements:
     *
     * - The contract must be paused.
     */
    function _unpause() internal virtual whenPaused {
        _paused = false;
        emit Unpaused(_msgSender());
    }
    uint256[49] private __gap;
}

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "IERC20.sol";
import "IERC20Metadata.sol";
import "Context.sol";

/**
 * @dev Implementation of the {IERC20} interface.
 *
 * This implementation is agnostic to the way tokens are created. This means
 * that a supply mechanism has to be added in a derived contract using {_mint}.
 * For a generic mechanism see {ERC20PresetMinterPauser}.
 *
 * TIP: For a detailed writeup see our guide
 * https://forum.zeppelin.solutions/t/how-to-implement-erc20-supply-mechanisms/226[How
 * to implement supply mechanisms].
 *
 * We have followed general OpenZeppelin Contracts guidelines: functions revert
 * instead returning `false` on failure. This behavior is nonetheless
 * conventional and does not conflict with the expectations of ERC20
 * applications.
 *
 * Additionally, an {Approval} event is emitted on calls to {transferFrom}.
 * This allows applications to reconstruct the allowance for all accounts just
 * by listening to said events. Other implementations of the EIP may not emit
 * these events, as it isn't required by the specification.
 *
 * Finally, the non-standard {decreaseAllowance} and {increaseAllowance}
 * functions have been added to mitigate the well-known issues around setting
 * allowances. See {IERC20-approve}.
 */
contract ERC20 is Context, IERC20, IERC20Metadata {
    mapping(address => uint256) private _balances;

    mapping(address => mapping(address => uint256)) private _allowances;

    uint256 private _totalSupply;

    string private _name;
    string private _symbol;

    /**
     * @dev Sets the values for {name} and {symbol}.
     *
     * The default value of {decimals} is 18. To select a different value for
     * {decimals} you should overload it.
     *
     * All two of these values are immutable: they can only be set once during
     * construction.
     */
    constructor(string memory name_, string memory symbol_) {
        _name = name_;
        _symbol = symbol_;
    }

    /**
     * @dev Returns the name of the token.
     */
    function name() public view virtual override returns (string memory) {
        return _name;
    }

    /**
     * @dev Returns the symbol of the token, usually a shorter version of the
     * name.
     */
    function symbol() public view virtual override returns (string memory) {
        return _symbol;
    }

    /**
     * @dev Returns the number of decimals used to get its user representation.
     * For example, if `decimals` equals `2`, a balance of `505` tokens should
     * be displayed to a user as `5.05` (`505 / 10 ** 2`).
     *
     * Tokens usually opt for a value of 18, imitating the relationship between
     * Ether and Wei. This is the value {ERC20} uses, unless this function is
     * overridden;
     *
     * NOTE: This information is only used for _display_ purposes: it in
     * no way affects any of the arithmetic of the contract, including
     * {IERC20-balanceOf} and {IERC20-transfer}.
     */
    function decimals() public view virtual override returns (uint8) {
        return 18;
    }

    /**
     * @dev See {IERC20-totalSupply}.
     */
    function totalSupply() public view virtual override returns (uint256) {
        return _totalSupply;
    }

    /**
     * @dev See {IERC20-balanceOf}.
     */
    function balanceOf(address account) public view virtual override returns (uint256) {
        return _balances[account];
    }

    /**
     * @dev See {IERC20-transfer}.
     *
     * Requirements:
     *
     * - `recipient` cannot be the zero address.
     * - the caller must have a balance of at least `amount`.
     */
    function transfer(address recipient, uint256 amount) public virtual override returns (bool) {
        _transfer(_msgSender(), recipient, amount);
        return true;
    }

    /**
     * @dev See {IERC20-allowance}.
     */
    function allowance(address owner, address spender) public view virtual override returns (uint256) {
        return _allowances[owner][spender];
    }

    /**
     * @dev See {IERC20-approve}.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     */
    function approve(address spender, uint256 amount) public virtual override returns (bool) {
        _approve(_msgSender(), spender, amount);
        return true;
    }

    /**
     * @dev See {IERC20-transferFrom}.
     *
     * Emits an {Approval} event indicating the updated allowance. This is not
     * required by the EIP. See the note at the beginning of {ERC20}.
     *
     * Requirements:
     *
     * - `sender` and `recipient` cannot be the zero address.
     * - `sender` must have a balance of at least `amount`.
     * - the caller must have allowance for ``sender``'s tokens of at least
     * `amount`.
     */
    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) public virtual override returns (bool) {
        _transfer(sender, recipient, amount);

        uint256 currentAllowance = _allowances[sender][_msgSender()];
        require(currentAllowance >= amount, "ERC20: transfer amount exceeds allowance");
        unchecked {
            _approve(sender, _msgSender(), currentAllowance - amount);
        }

        return true;
    }

    /**
     * @dev Atomically increases the allowance granted to `spender` by the caller.
     *
     * This is an alternative to {approve} that can be used as a mitigation for
     * problems described in {IERC20-approve}.
     *
     * Emits an {Approval} event indicating the updated allowance.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     */
    function increaseAllowance(address spender, uint256 addedValue) public virtual returns (bool) {
        _approve(_msgSender(), spender, _allowances[_msgSender()][spender] + addedValue);
        return true;
    }

    /**
     * @dev Atomically decreases the allowance granted to `spender` by the caller.
     *
     * This is an alternative to {approve} that can be used as a mitigation for
     * problems described in {IERC20-approve}.
     *
     * Emits an {Approval} event indicating the updated allowance.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     * - `spender` must have allowance for the caller of at least
     * `subtractedValue`.
     */
    function decreaseAllowance(address spender, uint256 subtractedValue) public virtual returns (bool) {
        uint256 currentAllowance = _allowances[_msgSender()][spender];
        require(currentAllowance >= subtractedValue, "ERC20: decreased allowance below zero");
        unchecked {
            _approve(_msgSender(), spender, currentAllowance - subtractedValue);
        }

        return true;
    }

    /**
     * @dev Moves `amount` of tokens from `sender` to `recipient`.
     *
     * This internal function is equivalent to {transfer}, and can be used to
     * e.g. implement automatic token fees, slashing mechanisms, etc.
     *
     * Emits a {Transfer} event.
     *
     * Requirements:
     *
     * - `sender` cannot be the zero address.
     * - `recipient` cannot be the zero address.
     * - `sender` must have a balance of at least `amount`.
     */
    function _transfer(
        address sender,
        address recipient,
        uint256 amount
    ) internal virtual {
        require(sender != address(0), "ERC20: transfer from the zero address");
        require(recipient != address(0), "ERC20: transfer to the zero address");

        _beforeTokenTransfer(sender, recipient, amount);

        uint256 senderBalance = _balances[sender];
        require(senderBalance >= amount, "ERC20: transfer amount exceeds balance");
        unchecked {
            _balances[sender] = senderBalance - amount;
        }
        _balances[recipient] += amount;

        emit Transfer(sender, recipient, amount);

        _afterTokenTransfer(sender, recipient, amount);
    }

    /** @dev Creates `amount` tokens and assigns them to `account`, increasing
     * the total supply.
     *
     * Emits a {Transfer} event with `from` set to the zero address.
     *
     * Requirements:
     *
     * - `account` cannot be the zero address.
     */
    function _mint(address account, uint256 amount) internal virtual {
        require(account != address(0), "ERC20: mint to the zero address");

        _beforeTokenTransfer(address(0), account, amount);

        _totalSupply += amount;
        _balances[account] += amount;
        emit Transfer(address(0), account, amount);

        _afterTokenTransfer(address(0), account, amount);
    }

    /**
     * @dev Destroys `amount` tokens from `account`, reducing the
     * total supply.
     *
     * Emits a {Transfer} event with `to` set to the zero address.
     *
     * Requirements:
     *
     * - `account` cannot be the zero address.
     * - `account` must have at least `amount` tokens.
     */
    function _burn(address account, uint256 amount) internal virtual {
        require(account != address(0), "ERC20: burn from the zero address");

        _beforeTokenTransfer(account, address(0), amount);

        uint256 accountBalance = _balances[account];
        require(accountBalance >= amount, "ERC20: burn amount exceeds balance");
        unchecked {
            _balances[account] = accountBalance - amount;
        }
        _totalSupply -= amount;

        emit Transfer(account, address(0), amount);

        _afterTokenTransfer(account, address(0), amount);
    }

    /**
     * @dev Sets `amount` as the allowance of `spender` over the `owner` s tokens.
     *
     * This internal function is equivalent to `approve`, and can be used to
     * e.g. set automatic allowances for certain subsystems, etc.
     *
     * Emits an {Approval} event.
     *
     * Requirements:
     *
     * - `owner` cannot be the zero address.
     * - `spender` cannot be the zero address.
     */
    function _approve(
        address owner,
        address spender,
        uint256 amount
    ) internal virtual {
        require(owner != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");

        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    /**
     * @dev Hook that is called before any transfer of tokens. This includes
     * minting and burning.
     *
     * Calling conditions:
     *
     * - when `from` and `to` are both non-zero, `amount` of ``from``'s tokens
     * will be transferred to `to`.
     * - when `from` is zero, `amount` tokens will be minted for `to`.
     * - when `to` is zero, `amount` of ``from``'s tokens will be burned.
     * - `from` and `to` are never both zero.
     *
     * To learn more about hooks, head to xref:ROOT:extending-contracts.adoc#using-hooks[Using Hooks].
     */
    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal virtual {}

    /**
     * @dev Hook that is called after any transfer of tokens. This includes
     * minting and burning.
     *
     * Calling conditions:
     *
     * - when `from` and `to` are both non-zero, `amount` of ``from``'s tokens
     * has been transferred to `to`.
     * - when `from` is zero, `amount` tokens have been minted for `to`.
     * - when `to` is zero, `amount` of ``from``'s tokens have been burned.
     * - `from` and `to` are never both zero.
     *
     * To learn more about hooks, head to xref:ROOT:extending-contracts.adoc#using-hooks[Using Hooks].
     */
    function _afterTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal virtual {}
}

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

/**
 * @dev Interface of the ERC20 standard as defined in the EIP.
 */
interface IERC20 {
    /**
     * @dev Returns the amount of tokens in existence.
     */
    function totalSupply() external view returns (uint256);

    /**
     * @dev Returns the amount of tokens owned by `account`.
     */
    function balanceOf(address account) external view returns (uint256);

    /**
     * @dev Moves `amount` tokens from the caller's account to `recipient`.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transfer(address recipient, uint256 amount) external returns (bool);

    /**
     * @dev Returns the remaining number of tokens that `spender` will be
     * allowed to spend on behalf of `owner` through {transferFrom}. This is
     * zero by default.
     *
     * This value changes when {approve} or {transferFrom} are called.
     */
    function allowance(address owner, address spender) external view returns (uint256);

    /**
     * @dev Sets `amount` as the allowance of `spender` over the caller's tokens.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * IMPORTANT: Beware that changing an allowance with this method brings the risk
     * that someone may use both the old and the new allowance by unfortunate
     * transaction ordering. One possible solution to mitigate this race
     * condition is to first reduce the spender's allowance to 0 and set the
     * desired value afterwards:
     * https://github.com/ethereum/EIPs/issues/20#issuecomment-263524729
     *
     * Emits an {Approval} event.
     */
    function approve(address spender, uint256 amount) external returns (bool);

    /**
     * @dev Moves `amount` tokens from `sender` to `recipient` using the
     * allowance mechanism. `amount` is then deducted from the caller's
     * allowance.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) external returns (bool);

    /**
     * @dev Emitted when `value` tokens are moved from one account (`from`) to
     * another (`to`).
     *
     * Note that `value` may be zero.
     */
    event Transfer(address indexed from, address indexed to, uint256 value);

    /**
     * @dev Emitted when the allowance of a `spender` for an `owner` is set by
     * a call to {approve}. `value` is the new allowance.
     */
    event Approval(address indexed owner, address indexed spender, uint256 value);
}

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "IERC20.sol";

/**
 * @dev Interface for the optional metadata functions from the ERC20 standard.
 *
 * _Available since v4.1._
 */
interface IERC20Metadata is IERC20 {
    /**
     * @dev Returns the name of the token.
     */
    function name() external view returns (string memory);

    /**
     * @dev Returns the symbol of the token.
     */
    function symbol() external view returns (string memory);

    /**
     * @dev Returns the decimals places of the token.
     */
    function decimals() external view returns (uint8);
}

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

/**
 * @dev Provides information about the current execution context, including the
 * sender of the transaction and its data. While these are generally available
 * via msg.sender and msg.data, they should not be accessed in such a direct
 * manner, since when dealing with meta-transactions the account sending and
 * paying for execution may not be the actual sender (as far as an application
 * is concerned).
 *
 * This contract is only required for intermediate, library-like contracts.
 */
abstract contract Context {
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }

    function _msgData() internal view virtual returns (bytes calldata) {
        return msg.data;
    }
}

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

/**
 * @dev Elliptic Curve Digital Signature Algorithm (ECDSA) operations.
 *
 * These functions can be used to verify that a message was signed by the holder
 * of the private keys of a given address.
 */
library ECDSA {
    enum RecoverError {
        NoError,
        InvalidSignature,
        InvalidSignatureLength,
        InvalidSignatureS,
        InvalidSignatureV
    }

    function _throwError(RecoverError error) private pure {
        if (error == RecoverError.NoError) {
            return; // no error: do nothing
        } else if (error == RecoverError.InvalidSignature) {
            revert("ECDSA: invalid signature");
        } else if (error == RecoverError.InvalidSignatureLength) {
            revert("ECDSA: invalid signature length");
        } else if (error == RecoverError.InvalidSignatureS) {
            revert("ECDSA: invalid signature 's' value");
        } else if (error == RecoverError.InvalidSignatureV) {
            revert("ECDSA: invalid signature 'v' value");
        }
    }

    /**
     * @dev Returns the address that signed a hashed message (`hash`) with
     * `signature` or error string. This address can then be used for verification purposes.
     *
     * The `ecrecover` EVM opcode allows for malleable (non-unique) signatures:
     * this function rejects them by requiring the `s` value to be in the lower
     * half order, and the `v` value to be either 27 or 28.
     *
     * IMPORTANT: `hash` _must_ be the result of a hash operation for the
     * verification to be secure: it is possible to craft signatures that
     * recover to arbitrary addresses for non-hashed data. A safe way to ensure
     * this is by receiving a hash of the original message (which may otherwise
     * be too long), and then calling {toEthSignedMessageHash} on it.
     *
     * Documentation for signature generation:
     * - with https://web3js.readthedocs.io/en/v1.3.4/web3-eth-accounts.html#sign[Web3.js]
     * - with https://docs.ethers.io/v5/api/signer/#Signer-signMessage[ethers]
     *
     * _Available since v4.3._
     */
    function tryRecover(bytes32 hash, bytes memory signature) internal pure returns (address, RecoverError) {
        // Check the signature length
        // - case 65: r,s,v signature (standard)
        // - case 64: r,vs signature (cf https://eips.ethereum.org/EIPS/eip-2098) _Available since v4.1._
        if (signature.length == 65) {
            bytes32 r;
            bytes32 s;
            uint8 v;
            // ecrecover takes the signature parameters, and the only way to get them
            // currently is to use assembly.
            assembly {
                r := mload(add(signature, 0x20))
                s := mload(add(signature, 0x40))
                v := byte(0, mload(add(signature, 0x60)))
            }
            return tryRecover(hash, v, r, s);
        } else if (signature.length == 64) {
            bytes32 r;
            bytes32 vs;
            // ecrecover takes the signature parameters, and the only way to get them
            // currently is to use assembly.
            assembly {
                r := mload(add(signature, 0x20))
                vs := mload(add(signature, 0x40))
            }
            return tryRecover(hash, r, vs);
        } else {
            return (address(0), RecoverError.InvalidSignatureLength);
        }
    }

    /**
     * @dev Returns the address that signed a hashed message (`hash`) with
     * `signature`. This address can then be used for verification purposes.
     *
     * The `ecrecover` EVM opcode allows for malleable (non-unique) signatures:
     * this function rejects them by requiring the `s` value to be in the lower
     * half order, and the `v` value to be either 27 or 28.
     *
     * IMPORTANT: `hash` _must_ be the result of a hash operation for the
     * verification to be secure: it is possible to craft signatures that
     * recover to arbitrary addresses for non-hashed data. A safe way to ensure
     * this is by receiving a hash of the original message (which may otherwise
     * be too long), and then calling {toEthSignedMessageHash} on it.
     */
    function recover(bytes32 hash, bytes memory signature) internal pure returns (address) {
        (address recovered, RecoverError error) = tryRecover(hash, signature);
        _throwError(error);
        return recovered;
    }

    /**
     * @dev Overload of {ECDSA-tryRecover} that receives the `r` and `vs` short-signature fields separately.
     *
     * See https://eips.ethereum.org/EIPS/eip-2098[EIP-2098 short signatures]
     *
     * _Available since v4.3._
     */
    function tryRecover(
        bytes32 hash,
        bytes32 r,
        bytes32 vs
    ) internal pure returns (address, RecoverError) {
        bytes32 s;
        uint8 v;
        assembly {
            s := and(vs, 0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff)
            v := add(shr(255, vs), 27)
        }
        return tryRecover(hash, v, r, s);
    }

    /**
     * @dev Overload of {ECDSA-recover} that receives the `r and `vs` short-signature fields separately.
     *
     * _Available since v4.2._
     */
    function recover(
        bytes32 hash,
        bytes32 r,
        bytes32 vs
    ) internal pure returns (address) {
        (address recovered, RecoverError error) = tryRecover(hash, r, vs);
        _throwError(error);
        return recovered;
    }

    /**
     * @dev Overload of {ECDSA-tryRecover} that receives the `v`,
     * `r` and `s` signature fields separately.
     *
     * _Available since v4.3._
     */
    function tryRecover(
        bytes32 hash,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) internal pure returns (address, RecoverError) {
        // EIP-2 still allows signature malleability for ecrecover(). Remove this possibility and make the signature
        // unique. Appendix F in the Ethereum Yellow paper (https://ethereum.github.io/yellowpaper/paper.pdf), defines
        // the valid range for s in (301): 0 < s < secp256k1n ÷ 2 + 1, and for v in (302): v ∈ {27, 28}. Most
        // signatures from current libraries generate a unique signature with an s-value in the lower half order.
        //
        // If your library generates malleable signatures, such as s-values in the upper range, calculate a new s-value
        // with 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141 - s1 and flip v from 27 to 28 or
        // vice versa. If your library also generates signatures with 0/1 for v instead 27/28, add 27 to v to accept
        // these malleable signatures as well.
        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) {
            return (address(0), RecoverError.InvalidSignatureS);
        }
        if (v != 27 && v != 28) {
            return (address(0), RecoverError.InvalidSignatureV);
        }

        // If the signature is valid (and not malleable), return the signer address
        address signer = ecrecover(hash, v, r, s);
        if (signer == address(0)) {
            return (address(0), RecoverError.InvalidSignature);
        }

        return (signer, RecoverError.NoError);
    }

    /**
     * @dev Overload of {ECDSA-recover} that receives the `v`,
     * `r` and `s` signature fields separately.
     */
    function recover(
        bytes32 hash,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) internal pure returns (address) {
        (address recovered, RecoverError error) = tryRecover(hash, v, r, s);
        _throwError(error);
        return recovered;
    }

    /**
     * @dev Returns an Ethereum Signed Message, created from a `hash`. This
     * produces hash corresponding to the one signed with the
     * https://eth.wiki/json-rpc/API#eth_sign[`eth_sign`]
     * JSON-RPC method as part of EIP-191.
     *
     * See {recover}.
     */
    function toEthSignedMessageHash(bytes32 hash) internal pure returns (bytes32) {
        // 32 is the length in bytes of hash,
        // enforced by the type signature above
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash));
    }

    /**
     * @dev Returns an Ethereum Signed Typed Data, created from a
     * `domainSeparator` and a `structHash`. This produces hash corresponding
     * to the one signed with the
     * https://eips.ethereum.org/EIPS/eip-712[`eth_signTypedData`]
     * JSON-RPC method as part of EIP-712.
     *
     * See {recover}.
     */
    function toTypedDataHash(bytes32 domainSeparator, bytes32 structHash) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }
}

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "IERC20.sol";
import "Address.sol";

/**
 * @title SafeERC20
 * @dev Wrappers around ERC20 operations that throw on failure (when the token
 * contract returns false). Tokens that return no value (and instead revert or
 * throw on failure) are also supported, non-reverting calls are assumed to be
 * successful.
 * To use this library you can add a `using SafeERC20 for IERC20;` statement to your contract,
 * which allows you to call the safe operations as `token.safeTransfer(...)`, etc.
 */
library SafeERC20 {
    using Address for address;

    function safeTransfer(
        IERC20 token,
        address to,
        uint256 value
    ) internal {
        _callOptionalReturn(token, abi.encodeWithSelector(token.transfer.selector, to, value));
    }

    function safeTransferFrom(
        IERC20 token,
        address from,
        address to,
        uint256 value
    ) internal {
        _callOptionalReturn(token, abi.encodeWithSelector(token.transferFrom.selector, from, to, value));
    }

    /**
     * @dev Deprecated. This function has issues similar to the ones found in
     * {IERC20-approve}, and its usage is discouraged.
     *
     * Whenever possible, use {safeIncreaseAllowance} and
     * {safeDecreaseAllowance} instead.
     */
    function safeApprove(
        IERC20 token,
        address spender,
        uint256 value
    ) internal {
        // safeApprove should only be called when setting an initial allowance,
        // or when resetting it to zero. To increase and decrease it, use
        // 'safeIncreaseAllowance' and 'safeDecreaseAllowance'
        require(
            (value == 0) || (token.allowance(address(this), spender) == 0),
            "SafeERC20: approve from non-zero to non-zero allowance"
        );
        _callOptionalReturn(token, abi.encodeWithSelector(token.approve.selector, spender, value));
    }

    function safeIncreaseAllowance(
        IERC20 token,
        address spender,
        uint256 value
    ) internal {
        uint256 newAllowance = token.allowance(address(this), spender) + value;
        _callOptionalReturn(token, abi.encodeWithSelector(token.approve.selector, spender, newAllowance));
    }

    function safeDecreaseAllowance(
        IERC20 token,
        address spender,
        uint256 value
    ) internal {
        unchecked {
            uint256 oldAllowance = token.allowance(address(this), spender);
            require(oldAllowance >= value, "SafeERC20: decreased allowance below zero");
            uint256 newAllowance = oldAllowance - value;
            _callOptionalReturn(token, abi.encodeWithSelector(token.approve.selector, spender, newAllowance));
        }
    }

    /**
     * @dev Imitates a Solidity high-level call (i.e. a regular function call to a contract), relaxing the requirement
     * on the return value: the return value is optional (but if data is returned, it must not be false).
     * @param token The token targeted by the call.
     * @param data The call data (encoded using abi.encode or one of its variants).
     */
    function _callOptionalReturn(IERC20 token, bytes memory data) private {
        // We need to perform a low level call here, to bypass Solidity's return data size checking mechanism, since
        // we're implementing it ourselves. We use {Address.functionCall} to perform this call, which verifies that
        // the target address contains contract code and also asserts for success in the low-level call.

        bytes memory returndata = address(token).functionCall(data, "SafeERC20: low-level call failed");
        if (returndata.length > 0) {
            // Return data is optional
            require(abi.decode(returndata, (bool)), "SafeERC20: ERC20 operation did not succeed");
        }
    }
}

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

/**
 * @dev Contract module that helps prevent reentrant calls to a function.
 *
 * Inheriting from `ReentrancyGuard` will make the {nonReentrant} modifier
 * available, which can be applied to functions to make sure there are no nested
 * (reentrant) calls to them.
 *
 * Note that because there is a single `nonReentrant` guard, functions marked as
 * `nonReentrant` may not call one another. This can be worked around by making
 * those functions `private`, and then adding `external` `nonReentrant` entry
 * points to them.
 *
 * TIP: If you would like to learn more about reentrancy and alternative ways
 * to protect against it, check out our blog post
 * https://blog.openzeppelin.com/reentrancy-after-istanbul/[Reentrancy After Istanbul].
 */
abstract contract ReentrancyGuard {
    // Booleans are more expensive than uint256 or any type that takes up a full
    // word because each write operation emits an extra SLOAD to first read the
    // slot's contents, replace the bits taken up by the boolean, and then write
    // back. This is the compiler's defense against contract upgrades and
    // pointer aliasing, and it cannot be disabled.

    // The values being non-zero value makes deployment a bit more expensive,
    // but in exchange the refund on every call to nonReentrant will be lower in
    // amount. Since refunds are capped to a percentage of the total
    // transaction's gas, it is best to keep them low in cases like this one, to
    // increase the likelihood of the full refund coming into effect.
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    uint256 private _status;

    constructor() {
        _status = _NOT_ENTERED;
    }

    /**
     * @dev Prevents a contract from calling itself, directly or indirectly.
     * Calling a `nonReentrant` function from another `nonReentrant`
     * function is not supported. It is possible to prevent this from happening
     * by making the `nonReentrant` function external, and make it call a
     * `private` function that does the actual work.
     */
    modifier nonReentrant() {
        // On the first call to nonReentrant, _notEntered will be true
        require(_status != _ENTERED, "ReentrancyGuard: reentrant call");

        // Any calls to nonReentrant after this point will fail
        _status = _ENTERED;

        _;

        // By storing the original value once again, a refund is triggered (see
        // https://eips.ethereum.org/EIPS/eip-2200)
        _status = _NOT_ENTERED;
    }
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.2;

import "ECDSA.sol";

/// @title Supervisor is the guardian of YPool. It requires multiple validators to valid
/// the requests from users and workers and sign on them if valid.
contract Supervisor {
    using ECDSA for bytes32;

    /* ========== STATE VARIABLES ========== */

    bytes32 public constant CLAIM_IDENTIFIER = 'SWAPPER_CLAIM';
    bytes32 public constant SET_THRESHOLD_IDENTIFIER = 'SET_THRESHOLD';
    bytes32 public constant SET_VALIDATOR_IDENTIFIER = 'SET_VALIDATOR';
    bytes32 public constant LOCK_CLOSE_SWAP_AND_REFUND_IDENTIFIER = 'LOCK_CLOSE_SWAP_AND_REFUND';
    bytes32 public constant BATCH_CLAIM_IDENTIFIER = 'BATCH_CLAIM';
    bytes32 public constant VALIDATE_SWAP_IDENTIFIER = 'VALIDATE_SWAP_IDENTIFIER';
    bytes32 public constant VALIDATE_XY_CROSS_CHAIN_IDENTIFIER = 'VALIDATE_XY_XCHAIN_IDENTIFIER';

    // the chain ID contract located at
    uint32 public chainId;
    // check if the address is one of the validators
    mapping (address => bool) public validators;
    // number of validators
    uint256 private validatorsNum;
    // threshold to pass the signature validation
    uint256 public threshold;
    // current nonce for write functions
    uint256 public nonce;

    /// @dev Constuctor with chainId / validators / threshold
    /// @param _chainId The chain ID located with
    /// @param _validators Initial validator addresses
    /// @param _threshold Initial threshold to pass the request validation
    constructor(uint32 _chainId, address [] memory _validators, uint256 _threshold) {
        chainId = _chainId;

        for (uint256 i; i < _validators.length; i++) {
            validators[_validators[i]] = true;
        }
        validatorsNum = _validators.length;
        require(_threshold <= validatorsNum, "ERR_INVALID_THRESHOLD");
        threshold = _threshold;
    }

    /* ========== VIEW FUNCTIONS ========== */

    /// @notice Check if there are enough signed signatures to the signature hash
    /// @param sigIdHash The signature hash to be signed
    /// @param signatures Signed signatures by different validators
    function checkSignatures(bytes32 sigIdHash, bytes[] memory signatures) public view {
        require(signatures.length >= threshold, "ERR_NOT_ENOUGH_SIGNATURES");
        address prevAddress = address(0);
        for (uint i; i < threshold; i++) {
            address recovered = sigIdHash.recover(signatures[i]);
            require(validators[recovered], "ERR_NOT_VALIDATOR");
            require(recovered > prevAddress, "ERR_WRONG_SIGNER_ORDER");
            prevAddress = recovered;
        }
    }

    /* ========== WRITE FUNCTIONS ========== */

    /// @notice Change `threshold` by providing a correct nonce and enough signatures from validators
    /// @param _threshold New `threshold`
    /// @param _nonce The nonce to be processed
    /// @param signatures Signed signatures by validators
    function setThreshold(uint256 _threshold, uint256 _nonce, bytes[] memory signatures) external {
        require(signatures.length >= threshold, "ERR_NOT_ENOUGH_SIGNATURES");
        require(_nonce == nonce, "ERR_INVALID_NONCE");
        require(_threshold > 0, "ERR_INVALID_THRESHOLD");
        require(_threshold <= validatorsNum, "ERR_INVALID_THRESHOLD");

        bytes32 sigId = keccak256(abi.encodePacked(SET_THRESHOLD_IDENTIFIER, address(this), chainId, _threshold, _nonce));
        bytes32 sigIdHash = sigId.toEthSignedMessageHash();
        checkSignatures(sigIdHash, signatures);

        threshold = _threshold;
        nonce++;
    }

    /// @notice Set / remove the validator address to be part of signatures committee
    /// @param _validator The address to add or remove
    /// @param flag `true` to add, `false` to remove
    /// @param _nonce The nonce to be processed
    /// @param signatures Signed signatures by validators
    function setValidator(address _validator, bool flag, uint256 _nonce, bytes[] memory signatures) external {
        require(_validator != address(0), "ERR_INVALID_VALIDATOR");
        require(signatures.length >= threshold, "ERR_NOT_ENOUGH_SIGNATURES");
        require(_nonce == nonce, "ERR_INVALID_NONCE");
        require(flag != validators[_validator], "ERR_OPERATION_TO_VALIDATOR");

        bytes32 sigId = keccak256(abi.encodePacked(SET_VALIDATOR_IDENTIFIER, address(this), chainId, _validator, flag, _nonce));
        bytes32 sigIdHash = sigId.toEthSignedMessageHash();
        checkSignatures(sigIdHash, signatures);

        if (validators[_validator]) {
            validatorsNum--;
            validators[_validator] = false;
            if (validatorsNum < threshold) threshold--;
        } else {
            validatorsNum++;
            validators[_validator] = true;
        }
        nonce++;
    }
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.2;
pragma experimental ABIEncoderV2;

import { IERC20 } from "ERC20.sol";

interface IDexAggregatorAdaptor {
    struct SwapDescription {
        IERC20 fromToken;
        IERC20 toToken;
        address receiver;
        uint256 amount;
        uint256 minReturnAmount;
    }
    // spec:
    //    (revert if any of the following steps fails)
    //    1. IDexAggregatorAdaptor receives `amountIn` `fromToken` where `amountIn >= amount`.
    //    2. IDexAggregatorAdaptor receives `amountOut` `toToken` where `amountOut >= minReturnAmount`.
    //    3. `receiver` receives `amountOut` `toToken`.
    function swap(SwapDescription calldata desc, bytes calldata data) external payable returns (uint256 returnAmount);
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.2;

import { IERC20 } from "ERC20.sol";

interface IYPoolVault {
    function transferToSwapper(IERC20 token, uint256 amount) external;
    function receiveAssetFromSwapper(IERC20 token, uint256 amount, uint256 xyFeeAmount, uint256 gasFeeAmount) external payable;
}