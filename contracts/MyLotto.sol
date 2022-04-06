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
 * Lottery Contract that pays directly from this contract, for simplicity and trust. 
 * -Drawings happen on a reoccuring basis
 * -Winners have a constant number of days after a drawing to withdraw funds
 * -Entries use the MyLottoNFT contract for entries. This ensures there can only be one winner since each nft is unique
 * -Enteries must be submitted (and paid) before the drawing's entry period ends
 * -60% of all ticket proceeds go directly to the Grand Prize, the rest can be withdrawn by the contract owner to pay for ongoing expenses
 */
contract MyLotto is Pausable, Ownable {
    using Counters for Counters.Counter;

    //entry fee for lotto
    uint public entryFee;

    //keep track of the amount within this contract set aside for the grand prize
    uint public grandPrize;

    //the contract for entry NFTs
    MyLottoNFT public entryContract;

    //indicator that enteries are open
    bool public started;

    //replace with counter
    Counters.Counter private _lottoId;
    
    //the block.timestamp of when entries are closed
    uint public entriesCloseAt;
    uint public winnerWithdrawBy;


    //lottery states: not running, entries open, entries closed, winnerDecided
    //when not running, no entries can be placed, no winners can withdraw
    //when entries open, entries can be added to current lotto
    //when entries closed, enters can no longer be added, winner not chosen yet. waiting.
    //when winnerDecided, no entries, but winner can withdraw funds.

    //this maps nftId to lottoId - indicates which lotto the entry is currently enrolled in.
    mapping (uint => uint) private _entries;
    
    //count of how many entries there were for the given lottoId
    mapping (uint => uint) private _entriesCount;

    //declare events that will be used in this contract
    event LottoStarted(uint indexed lottoId);
    event LottoEnded(uint indexed lottoId);
    event EntrySubmitted(uint indexed lottoId, uint tokenId);

    //start a lotto session, while running, users can enter their NFTs into the drawing
    //anyone can start it assuming we are in a state in which it can be started.
    function start() public whenNotPaused() {
        //validate we can start
        require(!started, "Lotto already started");

        //validate that the winner Withdraw period is closed
        require(!canWinnerWithdraw(), "Winner withdraw window still open");

        //TODO: validate there is enough balance for chainlink VRF

        //update when the entries period ends
        entriesCloseAt = block.timestamp + 3 days;
        //increment counter for lotto ID 
        _lottoId.increment();
        started = true;

        //emit lotto started event
        emit LottoStarted(_lottoId.current());
    }

    //helper function to get the current lottoId
    function getCurrentLottoId() public view returns (uint) {
        return _lottoId.current();
    }

    //end the lotto session and kick off the VRF calculation to determine winner
    //anyone can call this function (incentivize needed?), it will validate if it can execute
    function end() public whenNotPaused() {
        //time when the entries period can end
        uint endTime = block.timestamp + 10 minutes;

        //validate that there is an active entries session
        require(started, "No active lotto to end");

        //validate that it's time to end + period of time after entries have ended
        require(entriesCloseAt > endTime, "Not time to close entries yet");
        
        //close lotto
        started = false;

        //emit lotto ended event
        emit LottoEnded(getCurrentLottoId());

        //check that there was at least one entry
        uint currentLottoId = getCurrentLottoId();
        if(_entriesCount[currentLottoId] > 0) {
            //TODO send VRF request 
            winnerWithdrawBy = block.timestamp + 3 days;
        }
        else {
            //there were no entries, so no possibility of winners.
        }
    }

    //helper function to determine if we are still within the winner withdraw window
    function canWinnerWithdraw() public view returns (bool) {
        return block.timestamp < winnerWithdrawBy;
    }

    //helper function to determine if the entry submission window is open
    function canSubmitEntries() public view returns (bool) {
        return started & !
    }

    //pay to put entry into current open 
    function enterLotto(uint tokenId) public payable whenNotPaused() {
        uint256 currentLottoId = _lottoId.current();
        uint256 providedFee = msg.value;
        //validate enteries are currently open
        require(started && (block.timestamp < entriesCloseAt), "Entry window closed");

        //require entry fee has been paid
        require(providedFee >= entryFee, "Insufficient entry fee provided");

        //validate tokenId exists (anyone can enter an NFT but only owner can withdraw)
        require(entryContract.ownerOf(tokenId) != address(0), "TokenId doesn't exist");

        //validate if entry for tokenId already exists
        require(_entries[tokenId] != currentLottoId, "Entry for tokenId already submitted");

        _entriesCount[currentLottoId]++;
        _entries[tokenId] = currentLottoId;

        //60% entry fee goes to grand prize
        uint prizePortion = providedFee * 6 / 10 ;
        grandPrize += prizePortion;

        //emit entry event
        emit EntrySubmitted(getCurrentLottoId(), tokenId);
    }

    //how the winner can claim the grand prize
    //dont want to make this function pauseable, since that would prevent winner from getting funds
    function winnerWithdraw(uint tokenId, address payable to) public {
        //validate tokenId exists (calling ownerOf will revert if tokenId doesn't exist)
        address tokenOwner = entryContract.ownerOf(tokenId);
        address spender = msg.sender;
        
        //validate sender is the winner (via tokenId owner or approved operator)
        //require(tokenOwner == msg.sender, "Only owner of winning ticket can withdraw grand prize");
        if(spender != tokenOwner && entryContract.getApproved(tokenId) != spender && !entryContract.isApprovedForAll(tokenOwner, spender)) {
            //not allowed to withdraw grand prize
            revert("Must be entry owner or approved to withdraw grand prize");
        }

        //ensure there is something to withdraw
        require(grandPrize > 0, "Grand prize has already been claimed.");

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