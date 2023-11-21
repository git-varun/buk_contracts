// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;


// Buk Minting Contract interface
interface Buk{
    function idToMinter(uint256 tokenId) external returns(address minter);

    function getHotelTreasury(uint256 tokenId) external view returns(address hotel);
}

 contract BukMarket is IERC1155Receiver, Ownable, ReentrancyGuard{
    using Counters for Counters.Counter;
    Counters.Counter private _itemIds;     //count of sale items
    Counters.Counter private _itemsSold;  //count of sold items
    Counters.Counter private _itemsinActive; // count of inActive items

    address public mintingContract; // buk minting contract
    address public currency; // currecy used for transactions
    uint256 public treasuryRoyalty = 100; // platform royalty  percentage on every sale
    uint256 public hotelRoyalty = 50; // hotel royalty percentage on every sale
    uint256 public minterRoyalty = 50; // minter royalty percentage on every sale
    address public treasury; // platform treasury wallet
    address public signer; // signer wallet that signs the message we decrypt in function calls
    mapping(string => bool) public usedNonce; // checks if nonce has been used or not
    mapping(uint256 => MarketItem) public idToMarketItem; // returns market details when unique id is passed
    //struct for each market item
    struct MarketItem {
        uint itemId;
        uint256 tokenId;
        address seller;
        address owner;
        uint256 price;
        bool sold;
        bool isActive;
    }


    event saleCreated (
        uint indexed itemId,
        uint256 indexed tokenId,
        address seller,
        address owner,
        uint256 price,
        bool sold,
        bool isActive
    );

    event ItemBought(
        uint indexed itemId,
        uint256 indexed tokenId,
        address buyer,
        uint256 price,
        bool sold,
        bool isActive
    );

    event ListingEdited(uint256 indexed itemId, uint256 price);
    event SaleEnded(uint256 indexed itemId);
    event TreasuryUpdated(address treasury);
    event SignerUpdated(address signer);
    event RoyaltyUpdated(uint256 platformFee, uint256 hotelFee, uint256 minterFee);
    event CurrencyAddressUpdated(address currency);

    constructor(address _treasury, address _signer, address minting, address _currency) {
       treasury = _treasury;
       signer = _signer;
       mintingContract = (minting);
       currency = _currency;
    }


    receive() external payable {}


    fallback() external payable {}


    // Function to update Royalty
    function updateRoyalty(uint256 _platformFee, uint256 _hotelFee, uint256 _minterFee) external onlyOwner{
        treasuryRoyalty = _platformFee;
        hotelRoyalty = _hotelFee;
        minterRoyalty = _minterFee;
        emit RoyaltyUpdated(_platformFee, _hotelFee, _minterFee);
    }

    // Function to update Signer
    function setSigner(address _signer) external onlyOwner{
        signer = _signer;
        emit SignerUpdated(_signer);
    }

    // Function to set Treasury
    function setTreasury(address _treasury) external onlyOwner {
        treasury = payable(_treasury);
        emit TreasuryUpdated(_treasury);
    }

    // Function to update currency
    function updateCurrency(address _currency) external onlyOwner{
        currency = _currency;
        emit CurrencyAddressUpdated(_currency);
    }


    // Function to create sale
    function createSale(
        uint256 tokenId,
        uint256 price, bytes memory signature, string memory nonce
    ) external  nonReentrant {
        require(price > 0, "Price must be at least 1 wei");
        require(IERC1155(mintingContract).isApprovedForAll(msg.sender, address(this)),
        "Caller must be approved or owner for token id");
        require(IERC1155(mintingContract).balanceOf(msg.sender, tokenId)>0,"Balance 0");
        uint256 item = getTokenToItem(tokenId);
        require(item == 0, "Item already on Sale");
        require(!usedNonce[nonce], "Nonce used");
        require(
            matchSigner(
                hashSaleTransaction(msg.sender, tokenId, price, nonce),
                signature
            ),
            "Not allowed to lock"
        );
        usedNonce[nonce] = true;

        _itemIds.increment();
        uint256 itemId = _itemIds.current();
        idToMarketItem[itemId] =  MarketItem(
            itemId,
            tokenId,
            (msg.sender),
            (treasury),
            price,
            false,
            true
        );
        emit saleCreated(
            itemId,
            tokenId,
            msg.sender,
            treasury,
            price,
            false,
            true
        );
    }


    // Function to update price of an existing sale
    function editListing(uint256 itemId, string memory nonce, bytes memory signature, uint256 newPrice)
    external {
        require(msg.sender == idToMarketItem[itemId].seller, "Only seller can edit");
        require(!usedNonce[nonce], "Nonce used");
        require(
            matchSigner(
                hashSaleTransaction(msg.sender, itemId, newPrice, nonce),
                signature
            ),
            "Not allowed to lock"
        );
        usedNonce[nonce] = true;
        idToMarketItem[itemId].price = newPrice;
        emit ListingEdited(itemId, newPrice);
    }

    // Function to buy item from sale
    function buyItem(uint256 itemId, string memory nonce, bytes memory signature
        ) external nonReentrant   {
        require(itemId <= _itemIds.current(), " Enter a valid Id");
        require( idToMarketItem[itemId].isActive==true,"the sale is not active");
        require(msg.sender!= idToMarketItem[itemId].seller,"seller cannot buy");

        uint price = idToMarketItem[itemId].price;
        uint tokenId = idToMarketItem[itemId].tokenId;

        require(!usedNonce[nonce], "Nonce used");
        require(
            matchSigner(
                hashSaleTransaction(msg.sender, itemId, price, nonce),
                signature
            ),
            "Not allowed to lock"
        );
        usedNonce[nonce] = true;

        require( idToMarketItem[itemId].sold == false,"Already Sold");
        address minterAddress = Buk(mintingContract).idToMinter(tokenId);
        address hotelAddress = Buk(mintingContract).getHotelTreasury(tokenId);

        uint256 amountToadmin = ((price)*((treasuryRoyalty)))/(10000) ;
        uint256 amountToHotel = ((price)*((hotelRoyalty)))/(10000) ;
        uint256 amountTominter = ((price)*((minterRoyalty)))/(10000) ;
        uint256 amountToSeller = (price)-(amountTominter + amountToHotel + amountToadmin);
        IERC20(currency).transferFrom(msg.sender, treasury,
        amountToadmin);
        IERC20(currency).transferFrom(msg.sender, hotelAddress,
        amountToHotel);
        IERC20(currency).transferFrom(msg.sender, minterAddress,
        amountTominter);
        IERC20(currency).transferFrom(msg.sender, idToMarketItem[itemId].seller,
        amountToSeller);
        IERC1155(mintingContract).safeTransferFrom(idToMarketItem[itemId].seller, msg.sender, tokenId,1,"");

        idToMarketItem[itemId].owner = (msg.sender);
        idToMarketItem[itemId].sold = true;
        idToMarketItem[itemId].isActive = false;
        _itemsSold.increment();
        _itemsinActive.increment();

        emit ItemBought(
            itemId,
            tokenId,
            msg.sender,
            price,
            true,
            false
        );

    }

    // Function to end Sale
    function endSale(uint256 itemId) external nonReentrant {
        require(itemId <= _itemIds.current(), " Enter a valid Id");
        require((msg.sender==idToMarketItem[itemId].seller || msg.sender == mintingContract)
        && idToMarketItem[itemId].sold == false && idToMarketItem[itemId].isActive == true,"Cannot End Sale" );
        idToMarketItem[itemId].isActive = false;
        _itemsinActive.increment();
        emit SaleEnded(itemId);
    }


    // matches signer to authenticate the transactions
    function matchSigner(bytes32 hash, bytes memory signature)
        public
        view
        returns (bool)
    {
        return signer == ECDSA.recover(hash, signature);
    }


    function hashSaleTransaction(
        address user,
        uint256 tokenId,
        uint256 price,
        string memory nonce
    ) public pure returns (bytes32) {
        bytes32 hash = keccak256(abi.encodePacked(user , tokenId, price, nonce));
        return hash;
    }


    // Gets active sale id of an nft
    function getTokenToItem(uint256 token) public view returns(uint256 itemId){
        uint itemCount = _itemIds.current();
        uint256 saleId;
        for (uint i = 0; i < itemCount; i++) {
            if ( idToMarketItem[i+(1)].isActive ==true &&
                idToMarketItem[i+(1)].tokenId == token)
            {
                saleId = i+1;
            }
        }
        return(saleId);
    }

    /* Returns all unsold market items */
    function fetchMarketItems() public view returns (MarketItem[] memory) {
        uint itemCount = _itemIds.current();
        uint unsoldItemCount = _itemIds.current()-(_itemsinActive.current());
        uint currentIndex = 0;

        MarketItem[] memory items = new MarketItem[](unsoldItemCount);
        for (uint i = 0; i < itemCount; i++) {
            if ( idToMarketItem[i+(1)].isActive ==true )
            {
                uint currentId = i+(1);
                MarketItem storage currentItem = idToMarketItem[currentId];
                items[currentIndex] = currentItem;
                currentIndex = currentIndex+(1);
            }
        }
        return items;
    }

    /* Returns  items that a user has purchased */
    function fetchMyNFTs() public view returns (MarketItem[] memory) {
        uint totalItemCount = _itemIds.current();
        uint itemCount = 0;
        uint currentIndex = 0;

        for (uint i = 0; i < totalItemCount; i++) {
            if (idToMarketItem[i+(1)].owner == msg.sender) {
                itemCount = itemCount+(1) ;
            }
        }

        MarketItem[] memory items = new MarketItem[](itemCount);
        for (uint i = 0; i < totalItemCount; i++) {
            if (idToMarketItem[i+(1)].owner == msg.sender) {
                uint currentId = i+(1);
                MarketItem storage currentItem = idToMarketItem[currentId];
                items[currentIndex] = currentItem;
                currentIndex = currentIndex+(1);
            }
        }
        return items;
    }


    /* Returns only items a user has created */
    function fetchItemsCreated() public view returns (MarketItem[] memory) {
        uint totalItemCount = _itemIds.current();
        uint itemCount = 0;
        uint currentIndex = 0;

        for (uint i = 0; i < totalItemCount; i++) {
            if (idToMarketItem[i+(1)].seller == msg.sender) {
                itemCount = itemCount+(1);
            }
        }
        MarketItem[] memory items = new MarketItem[](itemCount);
        for (uint i = 0; i < totalItemCount; i++) {
            if (idToMarketItem[i+(1)].seller == msg.sender) {
                uint currentId = i+(1);
                MarketItem storage currentItem = idToMarketItem[currentId];
                items[currentIndex] = currentItem;
                currentIndex = currentIndex+(1) ;
            }
        }
        return items;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes memory) public virtual returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] memory, uint256[] memory, bytes memory) public virtual returns (bytes4) {
        return this.onERC1155BatchReceived.selector;
    }

    function hashCheckInTransaction(
        address user,
        string memory nonce) public pure returns (bytes32)
    {
        bytes32 hash = keccak256(abi.encodePacked(user , nonce,"User Check In"));
        return hash;
    }

}