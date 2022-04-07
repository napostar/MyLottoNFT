// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/utils/Counters.sol";

//interface for interacting with lotto entries nft contract
interface MyLottoNFT {
    function ownerOf(uint256 tokenId) external view returns (address owner);
    function getApproved(uint256 tokenId) external view returns (address operator);
    function isApprovedForAll(address owner, address operator) external view returns (bool);
    function tokenLottoNums(uint256 tokenId) external view returns (uint8[] memory nums);
}

/**
 * The MyLotto Lottery Contract was designed with the following requirements/features:
 * -For simplicity and trust, player pay directly to the contract, and it holds the winner funds.
 * -Use the MyLottoNFT contract for entries. This ensures there can only be one winner since each nft's drawing numbers are unique
 * -Drawings happen on a reoccuring basis, with only one open at a time.
 * -Contract states/phases: Not Started -> Entries Open -> Entries Closed -> VRF Drawn -> Winner Withdraw -> Not Started -> ...
 * -No entries can be submitted when a lotto hasn't been started
 * -Enteries must be submitted (and paid) before the drawing's entry period ends, following the commit then reveal pattern
 * -Use Chainlink VRF to make the drawing fair
 * -Winners have a constant number of days after a drawing to withdraw funds
 * -A new drawing can't be started until after the winner withdraw period, so the grand prize value can't change while a drawing is open
 * -60% of all ticket proceeds go directly to the Grand Prize, the rest can be withdrawn by the contract owner to pay for ongoing expenses
 * -Contract is Pausable, making it so we can pause new entries, prevent starting new drawings, but not prevent a winner's ability to withdraw
 */

contract MyLotto is Pausable, Ownable {
    using Counters for Counters.Counter;

    //entry fee for lotto
    uint public entryFee;

    //keep track of the amount within this contract set aside for the grand prize
    uint public grandPrize;

    //contigurable period of time for open entries for a given drawing
    uint public entryPeriod = 3 minutes; //3 days;

    //the contract for entry NFTs
    MyLottoNFT public entryContract;

    //indicator that enteries are open
    bool public started;

    //the block.timestamp of when entries are closed
    uint public entriesCloseAt;
    uint public winnerWithdrawBy;

    //counter for incrementing each drawing, to be a unique identifer
    Counters.Counter private _lottoId;

    //mapping nftId to lottoId - indicates which lotto the entry is currently enrolled in.
    mapping (uint => uint) private _entries;
    
    //mapping lottoId to entryCount - count of how many entries there were for the given lottoId (used to manage 0 entry drawnings)
    mapping (uint => uint) private _entriesCount;

    //mapping lottoId to winning numbers
    mapping (uint => uint8[]) private _lottoResults;

    //contract events
    event LottoStarted(uint indexed lottoId);
    event LottoEnded(uint indexed lottoId);
    event EntrySubmitted(uint indexed lottoId, uint tokenId);
    event WinnerHasWithdrawn(uint indexed lottoId, uint tokenId, address spender);
    event LottoResults(uint indexed lottoId, uint8[4] numbers);

    constructor() {
        entryContract = MyLottoNFT(0xd9145CCE52D386f254917e481eB44e9943F39138);
    }

    /**
     * start a lotto session, while open users can enter their NFTs into the drawing
     * anyone can start it assuming we are in a state in which it can be started.
     * Can't start session if contract is paused
     */
    function start() public whenNotPaused() {
        //validate we can start
        require(!started, "Lotto already started");

        //validate that the winner Withdraw period is closed
        require(!canWinnerWithdraw(), "Winner withdraw window still open");

        //TODO: validate there is enough balance for chainlink VRF

        //update when the entries period ends
        entriesCloseAt = block.timestamp + entryPeriod;

        //increment counter for lotto ID 
        _lottoId.increment();
        started = true;

        //emit lotto started event
        emit LottoStarted(_lottoId.current());
    }

    //end the lotto session and kick off the VRF calculation to determine winner
    //anyone can call this function (incentivize needed?), it will validate if it can execute
    function runDrawing() public whenNotPaused() {
        //time when the entries period can end
        //add 10min so that there is enough blockchain blocks between when entries can be submitted before drawing begins.
        uint currentTime = block.timestamp;// + 10 minutes;

        //validate that there is an active entries session
        require(started, "No active lotto to end");

        //validate that it's time to end + period of time after entries have ended
        require(currentTime > entriesCloseAt, "Entry period for drawing still open");
        
        //close lotto
        started = false;

        //emit lotto ended event
        emit LottoEnded(getCurrentLottoId());

        //check that there was at least one entry
        uint currentLottoId = getCurrentLottoId();
        if(_entriesCount[currentLottoId] > 0) {
            //TODO send VRF request 
            _lottoResults[getCurrentLottoId()] = [1,2,3,4];

            winnerWithdrawBy = block.timestamp + 3 minutes; // + 3 days;
        }
        else {
            //there were no entries, so no possibility of winners.
            //set the winner withdraw window to zero so we can start a new drawing
            winnerWithdrawBy = block.timestamp;
        }
    }

    //function to be called by chainlink VRF 
    function vrfResult(uint randomNumber) public {
        //validate this can only be called by chainlink
        //take hash and convert into four random numbers for lotto
        bytes32 hash = keccak256(abi.encodePacked(randomNumber));
        uint8[4] memory result;

        for(uint i=0; i < 4; i++){
           
            result[i]= uint8(hash[i]) % 100;
        }
        _lottoResults[getCurrentLottoId()] = result;
    }

    //helper function to get the current lottoId
    function getCurrentLottoId() public view returns (uint) {
        return _lottoId.current();
    }

    //helper function to determine if we are still within the winner withdraw window
    function canWinnerWithdraw() public view returns (bool) {
        return block.timestamp < winnerWithdrawBy;
    }

    //helper function to determine if the entry submission window is open
    function canSubmitEntries() public view returns (bool) {
        return started && (block.timestamp < entriesCloseAt);
    }

    //helper function to retrieve winning numbers from mapping
    function getWinningNumbers(uint lottoId) public view returns(uint8[] memory){
        return _lottoResults[lottoId];
    }

    //pay to put entry into current open drawing
    function enterLotto(uint tokenId) public payable whenNotPaused() {
        uint256 providedFee = msg.value;
        //validate enteries are currently open
        require(canSubmitEntries(), "Entry window closed");

        //require entry fee has been paid
        require(providedFee >= entryFee, "Insufficient entry fee provided");

        //validate tokenId exists (anyone can enter an NFT but only owner can withdraw)
        require(entryContract.ownerOf(tokenId) != address(0), "Token doesn't exist");

        //validate if entry for tokenId already exists
        require(_entries[tokenId] != getCurrentLottoId(), "Entry for tokenId already submitted");

        _entriesCount[getCurrentLottoId()]++;
        _entries[tokenId] = getCurrentLottoId();

        //60% entry fee goes to grand prize
        uint prizePortion = providedFee * 6 / 10 ;
        grandPrize += prizePortion;

        //emit entry event
        emit EntrySubmitted(getCurrentLottoId(), tokenId);
    }

    //how the winner can claim the grand prize
    //dont want to make this function pauseable, since that would prevent winner from getting funds
    function winnerWithdraw(uint lottoId, uint tokenId, address payable to) public {
        //validate tokenId exists (calling ownerOf will revert if tokenId doesn't exist)
        address tokenOwner = entryContract.ownerOf(tokenId);
        address spender = msg.sender;

        //validate token is a winner
        uint8[] storage winningNums = _lottoResults[lottoId];
        uint8[] memory ticketNums = entryContract.tokenLottoNums(tokenId);
        
        for(uint i=0 ; i < winningNums.length ; i++) {
            require(winningNums[i] == ticketNums[i], "Not the winning entry");
        }
        
        //validate sender is the winner (via tokenId owner or approved operator)
        //require(tokenOwner == msg.sender, "Only owner of winning ticket can withdraw grand prize");
        if(spender != tokenOwner && entryContract.getApproved(tokenId) != spender && !entryContract.isApprovedForAll(tokenOwner, spender)) {
            //not allowed to withdraw grand prize
            revert("Must be entry owner or approved to withdraw grand prize");
        }

        //ensure there is something to withdraw
        require(grandPrize > 0, "No funds to claim");

        //validate withdraw window is still open
        require(canWinnerWithdraw(), "Time window to claim grand prize has closed");

        //validate winner hasn't already withdrawn funds (by setting grandPrize to zero)
        //transfer grand prize to supplied address
        uint transferAmt = grandPrize;
        grandPrize = 0;
        to.transfer(transferAmt);
    }

    //owner withdraw non grand prize funds for bills
    function ownerWithdraw(address payable to) public onlyOwner {
        uint currentBalance = address(this).balance;
        require(currentBalance > grandPrize, "No funds can be withdrawn");

        //transfer
        currentBalance -= grandPrize; 
        to.transfer(currentBalance);
    }

    //be able to pause new entries and withdrawls
    function pause() public onlyOwner {
        _pause();
    }

    function unpause() public onlyOwner {
        _unpause();
    }

}