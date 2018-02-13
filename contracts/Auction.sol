pragma solidity 0.4.19;

import "./ERC223.sol";
import "./ERC223ReceivingContract.sol";
import "./oraclize/usingOraclize.sol";
import "zeppelin-solidity/contracts/ownership/Ownable.sol";


/**
 * @title Dutch auction of DGTX tokens. Sale of 100 000 000 DGTX.
 * @author SmartDec
 */
contract Auction is Ownable, usingOraclize, ERC223ReceivingContract {
    
    address public token;
    address public beneficiary;

    uint public constant START_TIMESTAMP = 1518703200; // 9am EST on February 15th, 2018
    uint public constant END_TIMESTAMP = START_TIMESTAMP + 30 days; 
    
    uint public constant TOTAL_TOKENS = 100000000 * uint(10) ** 18; // 100 000 000 DGTX
    uint public constant DOLLAR_DECIMALS_MULTIPLIER = 100;
    uint public constant TOKEN_DECIMALS_MULTIPLIER = uint(10) ** 18;

    uint public constant START_PRICE_IN_CENTS = 25; 
    uint public constant MIN_PRICE_IN_CENTS = 1; 
    uint public constant TRANSACTION_MIN_IN_ETH = 0.01 ether; 
    uint public constant ADDRESS_MAX_BID_IN_CENTS = 10000 * DOLLAR_DECIMALS_MULTIPLIER; // 10 000 USD
    uint public constant START_ETH_TO_CENTS = 83800; 

    uint public ethToCents = START_ETH_TO_CENTS;
    uint public finalDgtxToCents = 1;
    
    uint public totalTokens = 0;
    uint public totalCentsCollected = 0;
    address[] public participants;
    mapping (address => uint) public centsReceived; // Participants' bid in USD cents
    mapping (address => bool) public withdrawn; // Participants who received their tokens

    bool public updateEthToCentsRateCycleStarted = false;
    
    event NewOraclizeQuery(string description);
    event EthToCentsUpdated(uint _rate);
    event Bid(address indexed _from, uint256 _valueCents);
    event TokensWithdraw(address indexed _whom, uint256 _value);

    /**
     * @notice Constructor for contract. Sets token and beneficiary addresses.
     * @dev Also requests oracle for new ethToCents (starts updating cycle)
     * @param _token token address - supposed to be DGTX address
     * @param _beneficiary recipient of received ethers
     */
    function Auction(address _token, address _beneficiary) public payable Ownable() {
        require(_token != address(0));
        require(_beneficiary != address(0));
        token = _token;
        beneficiary = _beneficiary;
    }

    /**
     * @notice Fallback function.
     * During the auction receives and remembers participants bids.
     * After sale is finished, withdraws tokens to participants.
     */
    function () public payable {
        require(now >= START_TIMESTAMP);
        require(!isContract(msg.sender));

        if (!hasEnded()) {
            require(msg.value >= TRANSACTION_MIN_IN_ETH);
            bid(msg.sender, msg.value);
        } else {
            require(!withdrawn[msg.sender]);
            withdrawTokens(msg.sender);
        }
    }

    /**
     * @notice Anyone can call this function to start update cycle
     */
    function updateEthToCentsRate() public {
        require(!updateEthToCentsRateCycleStarted);
        updateEthToCentsRateCycleStarted = true;
        updateEthToCentsRate(0);
    }

    /**
     * @notice Function to receive ERC223 tokens (only from token, only once, only TOTAL_TOKENS)
     * @param _value number of tokens to receive
     */
    function tokenFallback(address, uint _value, bytes) public {
        require(msg.sender == token);
        require(totalTokens == 0);
        require(_value == TOTAL_TOKENS);
        totalTokens = TOTAL_TOKENS;
    }

    /**
     * @notice Get current price: dgtx to cents
     * 25 cents in the beginning and linearly decreases by 1 cent every hour until it reaches 1 cent.
     * @return current token to cents price
     */
    function getPrice() public view returns (uint) {
        if (now < START_TIMESTAMP) {
            return START_PRICE_IN_CENTS;
        }
        uint passedHours = (now - START_TIMESTAMP) / 1 hours;
        return (passedHours >= 24) ? MIN_PRICE_IN_CENTS : (25 - passedHours);
    }

    /**
     * @notice Checks if auction has ended
     * @return true if auction has ended
     */
    function hasEnded() public view returns (bool) {
        return now > END_TIMESTAMP || areTokensSold();
    }

    /**
     * @notice Сhecks if sufficient funds are received:
     * amount of USD cents received is more or equal to the current valuation of the tokens offered
     * (that is current auction token price multiplied by total amount of tokens offered)
     * @dev Sets final token price
     * @return true if all tokens are sold
     */
    function areTokensSold() public view returns (bool) {
        return totalCentsCollected >= getPrice() * totalTokens / TOKEN_DECIMALS_MULTIPLIER;
    }

    /**
     * @notice Function to receive transaction from oracle with new ETH rate
     * @dev Calls updateEthToCentsRate in one hour (starts update cycle)
     * @param result string with new rate
     */
    function __callback(bytes32, string result) public {
        require(msg.sender == oraclize_cbAddress());
        uint newEthToCents = parseInt(result, 2); // convert string to cents
        if (newEthToCents > 0) {
            ethToCents = newEthToCents;
            EthToCentsUpdated(ethToCents);
        } 
        if (!hasEnded()) {
            updateEthToCentsRate(1 hours);
        }
    }

    /**
     * @notice Function to transfer tokens to participants in range [_from, _to)
     * @param _from Begin index of participant range to withdraw
     * @param _to Index after the last withdrawn participant
     */
    function distributeTokensRange(uint _from, uint _to) public {
        require(hasEnded());
        require(_from < _to && _to <= participants.length);

        address recipient;
        for (uint i = _from; i < _to; ++i) {
            recipient = participants[i];
            if (!withdrawn[recipient]) {
                withdrawTokens(recipient);
            }
        }
    }

    /**
     * @notice Lets the owner withdraw extra tokens, which were not sold during the auction
     * @param _recipient Address to transfer tokens
     */
    function withdrawExtraTokens(address _recipient) public onlyOwner {
        require(now > END_TIMESTAMP && !areTokensSold());
        assert(totalCentsCollected < totalTokens * MIN_PRICE_IN_CENTS / TOKEN_DECIMALS_MULTIPLIER);
        uint gap = totalTokens - totalCentsCollected * TOKEN_DECIMALS_MULTIPLIER / MIN_PRICE_IN_CENTS;
        ERC223(token).transfer(_recipient, gap);
    }

    /**
     * @dev Function which records bids
     * @param _bidder is address, who bids
     * @param _valueETH is value of bid in ether
     */
    function bid(address _bidder, uint _valueETH) internal {
        uint price = getPrice();
        uint bidInCents = _valueETH * ethToCents / 1 ether;

        uint centsToAccept = bidInCents;
        uint ethToAccept = _valueETH;
        
        // Refund any ether above address bid limit
        if (centsReceived[_bidder] + centsToAccept > ADDRESS_MAX_BID_IN_CENTS) {
            centsToAccept = ADDRESS_MAX_BID_IN_CENTS - centsReceived[_bidder];
            ethToAccept = centsToAccept * 1 ether / ethToCents;
        }

        // Refund bid part which more than total tokens cost
        if (totalCentsCollected + centsToAccept > price * totalTokens / TOKEN_DECIMALS_MULTIPLIER) {
            centsToAccept = price * totalTokens / TOKEN_DECIMALS_MULTIPLIER - totalCentsCollected;
            ethToAccept = centsToAccept * 1 ether / ethToCents;
        }

        require(centsToAccept > 0 && ethToAccept > 0);

        if (centsReceived[_bidder] == 0) {
            participants.push(_bidder);
        }

        centsReceived[_bidder] += centsToAccept;
        totalCentsCollected += centsToAccept;
        Bid(_bidder, centsToAccept);

        if (ethToAccept < _valueETH) {
            _bidder.transfer(_valueETH - ethToAccept);
        }
        beneficiary.transfer(ethToAccept);
    }

    /**
     * @dev Internal function to withdraw tokens by final price
     * @param _recipient participant to withdraw
     */
    function withdrawTokens(address _recipient) internal {
        uint256 tokens = 0;
        if (totalCentsCollected < totalTokens * MIN_PRICE_IN_CENTS / TOKEN_DECIMALS_MULTIPLIER) {
            tokens = centsReceived[_recipient] * TOKEN_DECIMALS_MULTIPLIER / MIN_PRICE_IN_CENTS;
        } else {
            tokens = centsReceived[_recipient] * totalTokens / totalCentsCollected;
        }
        withdrawn[_recipient] = true;
        ERC223(token).transfer(_recipient, tokens);
        TokensWithdraw(_recipient, tokens);
    }

    /**
     * @dev assemble the given address bytecode. If bytecode exists then the _addr is a contract.
     * @return true if _addr is contract
     */
    function isContract(address _addr) internal view returns (bool) {
        // retrieve the size of the code on target address, this needs assembly
        uint length;
        assembly { length := extcodesize(_addr) }
        return length > 0;
    }

    /**
     * @dev internal function to make an oraclize query for rate update with given delay in seconds
     * @param _delay Delay for query in seconds
     */
    function updateEthToCentsRate(uint _delay) private {
        NewOraclizeQuery("Update of ETH to USD cents price requested");
        oraclize_query(
            _delay,
            "URL",
            "json(https://api.etherscan.io/api?module=stats&action=ethprice&apikey=YourApiKeyToken).result.ethusd");
    }

}