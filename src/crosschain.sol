pragma solidity ^0.8.16;

import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {OwnerIsCreator} from "@chainlink/contracts-ccip/src/v0.8/shared/access/OwnerIsCreator.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {CCIPReceiver} from "@chainlink/contracts-ccip/src/v0.8/ccip/applications/CCIPReceiver.sol";
import {IERC20} from "@chainlink/contracts-ccip/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@chainlink/contracts-ccip/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/utils/SafeERC20.sol";
import {EnumerableMap} from "@chainlink/contracts-ccip/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/utils/structs/EnumerableMap.sol";


import {IWETH} from "./market/interface/IWETH.sol";
import {IAsk} from "./market/interface/IAsk.sol";

struct FillAskOrder {
    address tokenContract;
    uint256 tokenId;
    address token;
    uint256 amount;
    address buyer;
}




contract MarketDelegateTransfer is CCIPReceiver, OwnerIsCreator{
    using EnumerableMap for EnumerableMap.Bytes32ToUintMap;
    using SafeERC20 for IERC20;


    error NotEnoughBalance(uint256 currentBalance, uint256 calculatedFees); // Used to make sure contract has enough balance to cover the fees.
    error NothingToWithdraw(); // Used when trying to withdraw Ether but there's nothing to withdraw.
    error FailedToWithdrawEth(address owner, address target, uint256 value); // Used when the withdrawal of Ether fails.
    error DestinationChainNotAllowed(uint64 destinationChainSelector); // Used when the destination chain has not been allowlisted by the contract owner.
    error SourceChainNotAllowed(uint64 sourceChainSelector); // Used when the source chain has not been allowlisted by the contract owner.
    error SenderNotAllowed(address sender); // Used when the sender has not been allowlisted by the contract owner.
    error InvalidReceiverAddress();  

    enum ErrorCode {
        // RESOLVED is first so that the default value is resolved.
        RESOLVED,
        // Could have any number of error codes here.
        FAILED
    }

    struct FailedMessage {
        bytes32 messageId;
        ErrorCode errorCode;
    }



    event MessageSent(
        bytes32 indexed messageId,
        uint64 indexed destinationChainSelector, // The chain selector of the destination chain.
        address receiver, // The address of the receiver on the destination chain.
        bytes32 payload, 
        address token, // The token address that was transferred.
        uint256 tokenAmount, // The token amount that was transferred.
        address feeToken, // the token address used to pay CCIP fees.
        uint256 fees // The fees paid for sending the message.
    );


     event MessageReceived(
        bytes32 indexed messageId, // The unique ID of the CCIP message.
        uint64 indexed sourceChainSelector, // The chain selector of the source chain.
        address sender, // The address of the sender from the source chain.
        FillAskOrder data, // The data that was received.
        address token, // The token address that was transferred.
        uint256 tokenAmount // The token amount that was transferred.
    );


    event MessageFailed(bytes32 indexed messageId, bytes reason);
    event MessageRecovered(bytes32 indexed messageId);


    bytes32 private s_lastReceivedMessageId; // Store the last received messageId.
    address private s_lastReceivedTokenAddress; // Store the last received token address.
    uint256 private s_lastReceivedTokenAmount; // Store the last received amount.
    FillAskOrder private s_lastReceivedOrder; // Store the last received text.

    // DYNAMIC CONFIG
    address private s_wrappedNative;
    address private askMarket;




    // Mapping to keep track of allowlisted destination chains.
    mapping(uint64 => bool) public allowlistedDestinationChains;

    // Mapping to keep track of allowlisted source chains.
    mapping(uint64 => bool) public allowlistedSourceChains;

    // Mapping to keep track of allowlisted senders.
    mapping(address => bool) public allowlistedSenders;


    IERC20 private s_linkToken;


    mapping(bytes32 => Client.Any2EVMMessage) public s_messageContents;

    // Contains failed messages and their state.
    EnumerableMap.Bytes32ToUintMap internal s_failedMessages;

    

    constructor(address _router, address _link, address wrappedNative) CCIPReceiver(_router) {
        s_linkToken = IERC20(_link);
        s_wrappedNative = wrappedNative;
       
    }



    modifier onlyAllowlistedDestinationChain(uint64 _destinationChainSelector) {
        if (!allowlistedDestinationChains[_destinationChainSelector])
            revert DestinationChainNotAllowed(_destinationChainSelector);
        _;
    }


    modifier validateReceiver(address _receiver) {
        if (_receiver == address(0)) revert InvalidReceiverAddress();
        _;
    }


    modifier onlyAllowlisted(uint64 _sourceChainSelector, address _sender) {
        if (!allowlistedSourceChains[_sourceChainSelector])
            revert SourceChainNotAllowed(_sourceChainSelector);
        if (!allowlistedSenders[_sender]) revert SenderNotAllowed(_sender);
        _;
    }

   
   function allowlistDestinationChain(uint64 _destinationChainSelector, bool allowed) external onlyOwner{
     allowlistedDestinationChains[_destinationChainSelector] = allowed;
   }

   function allowlistSourceChain(uint64 _sourceChainSelector, bool allowed) external onlyOwner {
    allowlistedSourceChains[_sourceChainSelector] = allowed;
   }


   function allowlistSender(address _sender, bool allowed) external onlyOwner {
        allowlistedSenders[_sender] = allowed;
    }


    function getWrappedNative() external view returns (address) {
    return s_wrappedNative;
    }

 
    function setWrappedNative(address wrappedNative) external onlyOwner {
    s_wrappedNative = wrappedNative;
    }


    function getAskMarket() external view returns (address) {
    return askMarket;
    }

 
    function setAskMarket(address _askMarket) external onlyOwner {
    askMarket = _askMarket;
    }


    function getLastReceivedMessageDetails()
        public
        view
        returns (
            bytes32 messageId,
            FillAskOrder memory data,
            address tokenAddress,
            uint256 tokenAmount
        )
    {
        return (
            s_lastReceivedMessageId,
            s_lastReceivedOrder,
            s_lastReceivedTokenAddress,
            s_lastReceivedTokenAmount
        );
    }


    
    function sendBuyMessageByNative(uint64 _destinationChainSelector, 
        address _receiver, FillAskOrder calldata order) external payable onlyAllowlistedDestinationChain(_destinationChainSelector) validateReceiver(_receiver) 
        returns (bytes32 messageId) {

            require(msg.value > order.amount, "msg value less than expected amount");
            
            bytes memory payload = abi.encode(order);
             Client.EVM2AnyMessage memory evm2AnyMessage = _buildCCIPMessage(
                _receiver,
                payload,
                order.token,
                order.amount,
                address(0)
            );
            

            IWETH(s_wrappedNative).deposit{value: order.amount}();

            uint256 total = msg.value;
            IRouterClient router = IRouterClient(this.getRouter());
            uint256 fees = router.getFee(_destinationChainSelector, evm2AnyMessage);
            uint256 payedAmount =total - order.amount;

            if (fees > payedAmount) 
                   revert NotEnoughBalance(payedAmount, fees);


            IERC20(order.token).approve(address(router), order.amount);
            
            messageId = router.ccipSend{value: fees}(_destinationChainSelector, evm2AnyMessage);

            emit MessageSent(
            messageId,
            _destinationChainSelector,
            _receiver,
            keccak256(payload),
            order.token,
            order.amount,
            address(0),
            fees
        );

        return messageId;
        }

    

    function _buildCCIPMessage(address _receiver, bytes memory _payload, address _token, uint256 _amount, address _feeTokenAddress) private pure returns (Client.EVM2AnyMessage memory){
        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({
            token: _token,
            amount: _amount
        });

        return Client.EVM2AnyMessage({
                receiver: abi.encode(_receiver), // ABI-encoded receiver address
                data: _payload, 
                tokenAmounts: tokenAmounts, // The amount and type of token being transferred
                extraArgs: Client._argsToBytes(
                    // Additional arguments, setting gas limit
                    Client.EVMExtraArgsV1({gasLimit: 80_0000})
                ),
                // Set the feeToken to a feeTokenAddress, indicating specific asset will be used for fees
                feeToken: _feeTokenAddress
            });

    }    


    receive() external payable {}


    function ccipReceive(Client.Any2EVMMessage calldata any2EvmMessage) external override onlyRouter onlyAllowlisted(
            any2EvmMessage.sourceChainSelector,
            abi.decode(any2EvmMessage.sender, (address))
        ){

      

       try  this.buyNFTNative(any2EvmMessage)
       {}catch (bytes memory err) {
       
         s_failedMessages.set(
                any2EvmMessage.messageId,
                uint256(ErrorCode.FAILED)
            );
            s_messageContents[any2EvmMessage.messageId] = any2EvmMessage;
            // Don't revert so CCIP doesn't revert. Emit event instead.
            // The message can be retried later without having to do manual execution of CCIP.
            emit MessageFailed(any2EvmMessage.messageId, err);
            return;
       }
    }

    function _ccipReceive(Client.Any2EVMMessage memory any2EvmMessage) internal override {

        s_lastReceivedMessageId = any2EvmMessage.messageId; // fetch the messageId
        s_lastReceivedOrder = abi.decode(any2EvmMessage.data, (FillAskOrder)); // abi-decoding of the sent paylod
        // Expect one token to be transferred at once, but you can transfer several tokens.
        s_lastReceivedTokenAddress = any2EvmMessage.destTokenAmounts[0].token;
        s_lastReceivedTokenAmount = any2EvmMessage.destTokenAmounts[0].amount;


        emit MessageReceived(
            any2EvmMessage.messageId,
            any2EvmMessage.sourceChainSelector, // fetch the source chain identifier (aka selector)
            abi.decode(any2EvmMessage.sender, (address)), // abi-decoding of the sender address,
            abi.decode(any2EvmMessage.data, (FillAskOrder)),
            any2EvmMessage.destTokenAmounts[0].token,
            any2EvmMessage.destTokenAmounts[0].amount
        );



    }

    function buyNFTNative(Client.Any2EVMMessage calldata any2EvmMessage) external payable{

        require(msg.sender == address(this), "buyNFTNative only self callable");
        
        _ccipReceive(any2EvmMessage);
        
        require(IERC20(s_wrappedNative).balanceOf(address(this)) >= s_lastReceivedOrder.amount, "insufficient amount");
        IWETH(s_wrappedNative).withdraw(s_lastReceivedOrder.amount);
        IAsk(askMarket).delegateFillAsk{value: s_lastReceivedOrder.amount}(s_lastReceivedOrder.tokenContract, s_lastReceivedOrder.tokenId, address(0), s_lastReceivedOrder.amount, s_lastReceivedOrder.buyer);
    }

    function withdraw(address _to) public onlyOwner {
         
        uint256 amount = address(this).balance;

        if (amount == 0) revert NothingToWithdraw();

        (bool sent, ) = _to.call{value: amount}("");

        if (!sent) revert FailedToWithdrawEth(msg.sender, _to, amount);
    }


    function withdrawToken(
        address _to,
        address _token
    ) public onlyOwner {
        // Retrieve the balance of this contract
        uint256 amount = IERC20(_token).balanceOf(address(this));

        // Revert if there is nothing to withdraw
        if (amount == 0) revert NothingToWithdraw();

        IERC20(_token).safeTransfer(_to, amount);
    }
    




}