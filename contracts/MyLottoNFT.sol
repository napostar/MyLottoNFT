// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Counters.sol";

/**
  * The purpose of this NFT is to create a representation of a lottery ticket. These tickets have the following properties:
  * -The combination of numbers is unique, no two tokens can have the same lottery numbers.
  * -The numbers for the ticket are stored on-chain and rendered dynamically onto the "ticket" to make the image.
  * -The lottery will work based on the number AND their order, pick 4 numbers 0-99 (inclusive), each "digit" pulled independently: (0,0,0,0) is a valid ticket.
  */
contract MyLottoNFT is ERC721, Ownable {
    using Counters for Counters.Counter;

    Counters.Counter private _tokenIdCounter;
    uint8 public constant LOTTO_NUM_LEN = 4; 
    uint256 public mintPrice = 1 ether;

    //mapping tokenID to lotto numbers
    mapping (uint256 => uint8[]) lottoNumbers;

    //mapping unique hash ID to exists
    mapping (uint256 => bool) lottoNumsExist;

    constructor() ERC721("My Lotto NFT", "LOTTO") {}

    /**
     * Validate numbers are within range and array size matches LOTTO_NUM_LEN
     */
    modifier validLottoNumbers(uint8[] calldata nums) {
        require(nums.length == LOTTO_NUM_LEN, "Invalid Array Length");
        for(uint8 i=0 ; i < LOTTO_NUM_LEN ; i++){
            require(nums[i] < 100, "Lotto number out of range");
        }
        _;
    }

    function tokenURI(uint256 tokenId)
        public
        view
        override(ERC721)
        returns (string memory)
    {
        //create dynamic URI JSON and Image
        return super.tokenURI(tokenId);
    }

    /**
     * Returns the lotto numbers for the given tokenId
     */
    function tokenLottoNums(uint256 tokenId) public view returns (uint8[] memory nums) {
        //validate tokenId exists
        require(_exists(tokenId), "ERC721Metadata: URI query for nonexistent token");

        return lottoNumbers[tokenId];
    }

    /**
     * Public mint function, called by front end to make a new unique lotto ticket
     */
    function mintTicket(uint8[] calldata nums, address to) public payable validLottoNumbers(nums){
        //validate numbers are within range and validate array size with "validLottoNumber" modifier
        //validate payment for mint
        require(msg.value >= mintPrice, "Insufficient payment");

        //validate numbers don't already exist on another ticket
        if(checkTicketExists(nums)){
            revert("Requested lotto numbers already exist");
        }

        //mint lotto ticket
        uint256 tokenId = _tokenIdCounter.current();
        uint256 hashId = getNumberHash(nums);
        _tokenIdCounter.increment();
        lottoNumsExist[hashId] = true;
        lottoNumbers[tokenId] = nums;
        _safeMint(to, tokenId);
    }

    /**
     * Helper function to check if the requested ticket numbers already exist on an existing lotto ticket
     */
    function checkTicketExists(uint8[] calldata nums) public view validLottoNumbers(nums) returns (bool exists) {
        //input validation done by function modifier validLottoNumbers
        return lottoNumsExist[getNumberHash(nums)];
    }

    /**
     * Helper function to calculate a unique hash ID from the provided lotto numbers
     */
    function getNumberHash(uint8[] calldata nums) private pure returns (uint256 hashId) {
        return uint256(keccak256(abi.encodePacked(nums)));
    }

    /**
     * Owner withdraw function to pay the bills
     */
    function withdraw(address payable to) public onlyOwner {
        uint funds = address(this).balance;
        to.transfer(funds);
    }
}