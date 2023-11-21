// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;


interface BukMarket {
    function endSale(uint256 itemId) external;

    function getTokenToItem(uint256 token)
        external
        view
        returns (uint256 itemId);
}

contract Buk is ERC1155, IERC1155Receiver, Ownable, ReentrancyGuard {
    using Counters for Counters.Counter;
    Counters.Counter tokenCount; // NFT Id counter for each booking
    Counters.Counter hotelCount; // Hotel Ids

    mapping(uint256 => string) public _uri; // NFT Metadata
    mapping(uint256 => uint256) public nftToHotel; // returns hotel id of a particular Nft
    mapping(uint256 => bool) public transferBlocked; // checks if transfer has been blocked (after Pre Check In)
    mapping(address => bool) public allowedToTransfer; // address allowed to transfer Nfts
    mapping(uint256 => Hotel) public idToHotel; // return hotel details when hotel id is entered
    mapping(uint256 => Booking) public bookingDetails; // returns booking details when nft id is entered
    mapping(uint256 => address) public idToMinter; // returns minter of an Nft

    address public treasury; // platform treasury to receive platform fee
    address public signer; // signer wallet that signs the message we decrypt in function calls
    uint256 public platformFee = 500; // Buk Platform Fee
    //    uint256 public cancellationFeeHotel =500; // Cancellation fee when bookings are cancelled, received by the hotel
    //    uint256 public cancellationFeeBuk = 2000;// Cancellation fee when bookings are cancelled, received by the platform treasury
    uint256 public hotelTaxes = 8600; // hotel taxes
    address public currency; // currency used for transactions (e.g -usdc)
    uint256 public checkInTime = 172800;
    // Time before booking time when check in window opens (e.g - 48 hours before)
    uint256 public checkOutTime = 86400;
    // Time after booking time when check out window opens (e.g - 24 hours after)
    address public checkOutBot; //address that calls checkOut function automatically after 24 hours of check out
    address public marketplaceContract; // Buk Nft Marketplace
    mapping(string => bool) public usedNonce; // checks if nonce has been used or not
    mapping(uint256 => bool) public checkedOut; // mapping to check if booking has been checked out
    mapping(uint256 => bool) public burnt; // checks if nft has been burnt
    mapping(uint256 => bool) public nftCheckedOut; // checks if nft has been nftCheckedOut
    mapping(address => bool) public isWhitelistedManager; // returns if a wallet can register hotel or not

    // Hotel Details Structure
    struct Hotel {
        string hotelId; // database of of hotel
        string hotelUri; // hotel uri
        address hotelManager; // To manage operational activities
        address hotelTreasury; // To receive booking funds
        uint256 index; // unique hotel Id
    }

    // Booking Details Structure
    struct Booking {
        string nftUri; // nft Uri
        string bookingId; // database booking id
        uint256 price; // Total Price after taxespaid by the user
        uint256 _baseprice; //base price of Hotel Room on which taxes are caluculated to get total price
        uint256 discount; //discount on platformFee in absolute Amount
        uint256 hotelId; // hotel Id of the room booked
        uint256 buk_cancellationFee; //cancellation fee of the bukprotocol in absolute Amount
        uint256 Hotel_cancellationFee; //cancellationFee of the Hotel in which room was booked in absolute Amount
        uint256 time; //Booking Time(start time of the stay)
    }

    event Minted(uint256 indexed id, address indexed minter);
    event Booked(
        address indexed user,
        uint256 indexed hotel,
        uint256 indexed nftId
    );
    event HotelRegistered(Hotel hotelDetails);
    event CheckedIn(
        uint256 indexed id,
        address indexed user,
        uint256 indexed hotelId
    );
    event CheckedOut(
        uint256 indexed id,
        address indexed user,
        uint256 indexed hotelId
    );
    event MarketplaceContractUpdated(address indexed market);
    event HotelDetailsUpdated(uint256 indexed hotelId);
    event TreasuryUpdated(address indexed treasury);
    event SignerUpdated(address indexed signer);
    event PlatformFeeUpdated(uint256 platformFee);
    //    event CancellationFeeUpdated(uint256 cancellationFeeHotel, uint256 cancellationFeeBuk);
    event CurrencyAddressUpdated(address currency);
    event CheckinTimeUpdated(uint256 time);
    event CheckoutTimeUpdated(uint256 time);
    event CheckoutBotupdated(address bot);
    event UriUpdated(uint256 indexed id, string uri);
    event TransferAllowanceUpdated(address indexed user, bool isAllowed);
    event BookingCancelled(
        address user,
        uint256 indexed id,
        uint256 indexed hotelId
    );
    event ManagerWhitelistUpdated(address manager, bool isWhitelisted);
    event HotelTaxesUpdated(uint256 tax);

    constructor(
        string memory NAME,
        address _treasury,
        address _signer,
        address _currency,
        address bot
    ) ERC1155(NAME) {
        treasury = _treasury;
        signer = _signer;
        checkOutBot = bot;
        currency = _currency;
        allowedToTransfer[address(this)] = true;
    }

    receive() external payable {}

    fallback() external payable {}

    function withdrawFunds(address wallet) external onlyOwner {
        uint256 balanceOfContract = address(this).balance;
        payable(wallet).transfer(balanceOfContract);
    }

    function withdrawTokens(
        address token,
        address wallet,
        uint256 amount
    ) external onlyOwner {
        IERC20(token).transfer(wallet, amount);
    }

    //Function to set Buk Marketplace Contract
    function setMarketplace(address _bukMarket) external onlyOwner {
        marketplaceContract = _bukMarket;
        allowedToTransfer[_bukMarket] = true;
        emit MarketplaceContractUpdated(_bukMarket);
    }

    // Function to set signer wallet Address
    function setSigner(address _signer) external onlyOwner {
        signer = _signer;
        emit SignerUpdated(_signer);
    }

    // Function to set treasury address
    function setTreasury(address _treasury) external onlyOwner {
        treasury = payable(_treasury);
        emit TreasuryUpdated(_treasury);
    }

    // Function to update Hotel details
    function updateHotelDetails(Hotel memory hotel) external {
        require(
            msg.sender == owner() ||
                msg.sender == idToHotel[hotel.index].hotelManager,
            "Access Denied"
        );
        idToHotel[hotel.index] = hotel;
        emit HotelDetailsUpdated(hotel.index);
    }

    // Function to update manager whitelist
    function updateManagerWhitelist(address manager, bool isWhitelisted)
        external
        onlyOwner
    {
        isWhitelistedManager[manager] = isWhitelisted;
        emit ManagerWhitelistUpdated(manager, isWhitelisted);
    }

    // Function to update transfer allowance
    function updateAllowedToTransfer(address user, bool allowed)
        external
        onlyOwner
    {
        allowedToTransfer[user] = allowed;
        emit TransferAllowanceUpdated(user, allowed);
    }

    // Function to update Platform Fee
    function updatedPlatformFee(uint256 fee) external onlyOwner {
        platformFee = fee;
        emit PlatformFeeUpdated(fee);
    }

    // Function to update Cancellation Fee
    function updateCancellationFee(uint256 feeHotel, uint256 feeBuk) external onlyOwner{
        cancellationFeeHotel = feeHotel;
        cancellationFeeBuk = feeBuk;
        emit CancellationFeeUpdated(feeHotel, feeBuk);
    }

    // Function to update Currency
    function updateCurrency(address _currency) external onlyOwner {
        currency = _currency;
        emit CurrencyAddressUpdated(_currency);
    }

    // Function to update Checkin window time;
    function updateCheckinTime(uint256 time) external onlyOwner {
        checkInTime = time;
        emit CheckinTimeUpdated(time);
    }

    // Function to update Checkout window time;
    function updateCheckoutTime(uint256 time) external onlyOwner {
        checkOutTime = time;
        emit CheckoutTimeUpdated(time);
    }

    // Function to update Checkout bot address;
    function updateCheckoutBot(address bot) external onlyOwner {
        checkOutBot = bot;
        emit CheckoutBotupdated(bot);
    }

    // Function to update token Uri
    function updateUri(uint256 tokenId, string memory tokenUri) external {
        require(
            msg.sender == owner() ||
                msg.sender ==
                idToHotel[bookingDetails[tokenId].hotelId].hotelManager,
            "Access Denied"
        );
        _uri[tokenId] = tokenUri;
        emit UriUpdated(tokenId, tokenUri);
    }

    // Function to register hotels
    function registerHotel(
        Hotel memory hotelDetails,
        string memory nonce,
        bytes memory signature
    ) external {
        require(isWhitelistedManager[msg.sender], "Manager not whitelisted");
        require(!usedNonce[nonce], "Nonce used");
        require(
            matchSigner(
                hashHotelRegistrationTransaction(hotelDetails.hotelId, nonce),
                signature
            ),
            "Not allowed to lock"
        );
        usedNonce[nonce] = true;
        hotelCount.increment();
        uint256 count = hotelCount.current();
        idToHotel[count] = Hotel({
            hotelId: hotelDetails.hotelId,
            hotelUri: hotelDetails.hotelUri,
            hotelManager: hotelDetails.hotelManager,
            hotelTreasury: hotelDetails.hotelTreasury,
            index: count
        });
        emit HotelRegistered(idToHotel[count]);
    }

    // Function to book room
    function bookRoom(
        Booking[] memory booking,
        address user,
        bytes memory signature,
        string memory nonce
    ) external {
        require(!usedNonce[nonce], "Nonce used");
        require(
            matchSigner(hashTransaction(user, nonce), signature),
            "Not allowed to lock"
        );
        usedNonce[nonce] = true;
        uint256 totalNfts = booking.length;
        for (uint256 i = 0; i < totalNfts; i++) {
            uint256 TotalAmount = booking[i].price;
            // uint256 bukFee  = (booking[i].base_price * _bukCommission / 10000);
            uint256 bukActualTotal = (
                ((booking[i]._baseprice * platformFee) / 10000)
            ) - booking[i].discount;
            uint256 HotelAmount = TotalAmount - bukActualTotal;
            IERC20(currency).transferFrom(msg.sender, treasury, bukActualTotal);
            IERC20(currency).transferFrom(
                msg.sender,
                address(this),
                HotelAmount
            );
            uint256 id = mintNft(user, booking[i].nftUri, booking[i].hotelId);
            bookingDetails[id] = booking[i];
            emit Booked(user, booking[i].hotelId, id);
        }
    }

    // Function to cancel booking
    function cancelBookingUser(
        uint256 id,
        address user,
        string memory nonce,
        bytes memory signature
    ) external {
        //In case of cancellation, we need actual price that is being is being paid to Hotel
        uint256 TotalPaidAmount = bookingDetails[id].price; //final price paid by the user
        uint256 bukComm = (
            ((bookingDetails[id]._baseprice * platformFee) / 10000)
        ) - bookingDetails[id].discount; // bukFee and discounts deducted from Total paid amount
        uint256 ActualAmount = TotalPaidAmount - bukComm; // Actual Amount went to Hotel that user paid
        require(!usedNonce[nonce], "Nonce used");
        require(
            matchSigner(
                hashCancelTransaction(user, id, nonce, ActualAmount),
                signature
            ),
            "Not allowed to lock"
        );
        usedNonce[nonce] = true;
        require(
            (balanceOf(msg.sender, id) > 0 && user == msg.sender) ||
                owner() == msg.sender ||
                msg.sender ==
                idToHotel[bookingDetails[id].hotelId].hotelManager,
            "Access Denied"
        );
        uint256 itemId = BukMarket(marketplaceContract).getTokenToItem(id);
        if (itemId != 0) {
            BukMarket(marketplaceContract).endSale(itemId);
        }
        nftCheckedOut[id] = true;
        _burn(user, id, 1);
        burnt[id] = true;
        if (
            owner() == msg.sender ||
            msg.sender == idToHotel[bookingDetails[id].hotelId].hotelManager
        ) {
            IERC20(currency).transfer(user, ActualAmount);
        } else {
            if (block.timestamp < bookingDetails[id].time - checkInTime) {
                uint256 feeHotel = bookingDetails[id].Hotel_cancellationFee;
                uint256 feeBuk = bookingDetails[id].buk_cancellationFee;
                address HotelTreasury = idToHotel[bookingDetails[id].hotelId]
                    .hotelTreasury;
                uint256 userAmount = ActualAmount - (feeHotel + feeBuk);
                IERC20(currency).transfer(treasury, feeBuk);
                IERC20(currency).transfer(HotelTreasury, feeHotel);
                IERC20(currency).transfer(user, userAmount);
            }
        }
        emit BookingCancelled(user, id, bookingDetails[id].hotelId);
    }

    // Function to perform pre check in, stop transfer of nfts and end active Sale
    function preCheckIn(
        uint256 id,
        string memory nonce,
        bytes memory signature
    ) external {
        require(
            balanceOf(msg.sender, id) > 0 || owner() == msg.sender,
            "Access Denied,Only Nft Owner or Contract owner"
        );
        require(!usedNonce[nonce], "Nonce used");
        require(
            matchSigner(
                hashCheckInTransaction(msg.sender, id, nonce),
                signature
            ),
            "Not allowed to lock"
        );
        usedNonce[nonce] = true;
        transferBlocked[id] = true;
        uint256 itemId = BukMarket(marketplaceContract).getTokenToItem(id);
        if (itemId != 0) {
            BukMarket(marketplaceContract).endSale(itemId);
        }
        emit CheckedIn(id, msg.sender, bookingDetails[id].hotelId);
    }

    // Function to check out
    function checkOut(uint256 id, address user) external {
        require(
            owner() == msg.sender || msg.sender == checkOutBot,
            "Access Denied"
        );
        require(
            block.timestamp > bookingDetails[id].time + 79200 + checkOutTime,
            "CheckOut window is not Opened"
        );
        uint256 itemId = BukMarket(marketplaceContract).getTokenToItem(id);
        if (itemId != 0) {
            BukMarket(marketplaceContract).endSale(itemId);
        }
        nftCheckedOut[id] = true;
        uint256 TotalPaidAmount = bookingDetails[id].price; //final price paid by the user
        uint256 bukComm = (
            ((bookingDetails[id]._baseprice * platformFee) / 10000)
        ) - bookingDetails[id].discount; // bukFee and discounts deducted from Total paid amount
        uint256 ActualAmount = TotalPaidAmount - bukComm; // Actual Amount went to Hotel that user paid
        IERC20(currency).transfer(
            idToHotel[bookingDetails[id].hotelId].hotelTreasury,
            ActualAmount
        );
        checkedOut[id] = true;
        transferBlocked[id] = true;
        emit CheckedOut(id, user, bookingDetails[id].hotelId);
    }

    function getNFTsToCheckout() external view returns (uint256[] memory ids) {
        uint256 totalNfts = tokenCount.current();
        uint256 itemCount = 0;
        uint256 currentIndex = 0;

        for (uint256 i = 0; i < totalNfts; i++) {
            if (
                nftCheckedOut[i] == false &&
                block.timestamp > bookingDetails[i].time + 79200 + checkOutTime
            ) {
                itemCount = itemCount + 1;
            }
        }
        uint256[] memory items = new uint256[](itemCount);
        for (uint256 i = 0; i < totalNfts; i++) {
            if (
                nftCheckedOut[i] == false &&
                block.timestamp > bookingDetails[i].time + 79200 + checkOutTime
            ) {
                items[currentIndex] = i;
                currentIndex = currentIndex + 1;
            }
        }
        return items;
    }

    // returns the total amount of NFTs minted
    function getTokenCounter() external view returns (uint256 tracker) {
        return (tokenCount.current());
    }

    // Function to get hotel treasury address
    function getHotelTreasury(uint256 tokenId)
        external
        view
        returns (address hotel)
    {
        return (idToHotel[bookingDetails[tokenId].hotelId].hotelTreasury);
    }

    function onERC1155Received(
        address,
        address,
        uint256,
        uint256,
        bytes memory
    ) public virtual returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address,
        address,
        uint256[] memory,
        uint256[] memory,
        bytes memory
    ) public virtual returns (bytes4) {
        return this.onERC1155BatchReceived.selector;
    }

    // Returns token uri
    function uri(uint256 id)
        public
        view
        virtual
        override
        returns (string memory)
    {
        return _uri[id];
    }

    // Hash Cancel Transaction
    function hashCancelTransaction(
        address user,
        uint256 nft,
        string memory nonce,
        uint256 price
    ) public pure returns (bytes32) {
        bytes32 hash = keccak256(abi.encodePacked(user, nft, nonce, price));
        return hash;
    }

    // Hash CheckIn/ CheckOut transactions
    function hashCheckInTransaction(
        address user,
        uint256 nft,
        string memory nonce
    ) public pure returns (bytes32) {
        bytes32 hash = keccak256(abi.encodePacked(user, nft, nonce));
        return hash;
    }

    function hashTransaction(address user, string memory nonce)
        public
        pure
        returns (bytes32)
    {
        bytes32 hash = keccak256(abi.encodePacked(user, nonce));
        return hash;
    }

    function hashHotelRegistrationTransaction(
        string memory hotelId,
        string memory nonce
    ) public pure returns (bytes32) {
        bytes32 hash = keccak256(abi.encodePacked(hotelId, nonce));
        return hash;
    }

    function matchSigner(bytes32 hash, bytes memory signature)
        public
        view
        returns (bool)
    {
        return signer == ECDSA.recover(hash, signature);
    }

    function getAddress(bytes32 hash, bytes memory signature)
        public
        pure
        returns (address)
    {
        return ECDSA.recover(hash, signature);
    }

    function safeTransferFrom(
        address from,
        address to,
        uint256 id,
        uint256 amount,
        bytes calldata data
    ) public virtual override {
        require(
            block.timestamp < bookingDetails[id].time - checkInTime,
            "Transfer has been blocked"
        );
        require(transferBlocked[id] == false, "Transfer has been stopped");
        require(
            from == _msgSender() || isApprovedForAll(from, _msgSender()),
            "ERC1155: caller is not owner nor approved"
        );
        require(allowedToTransfer[msg.sender], "Access Denied");
        _safeTransferFrom(from, to, id, amount, data);
    }

    function safeBatchTransferFrom(
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory amounts,
        bytes memory data
    ) public virtual override {
        require(
            from == _msgSender() || isApprovedForAll(from, _msgSender()),
            "ERC1155: transfer caller is not owner nor approved"
        );

        require(allowedToTransfer[msg.sender], "Access Denied");
        uint256 total = ids.length;
        for (uint256 i = 0; i < total; i++) {
            require(
                block.timestamp < bookingDetails[ids[i]].time - checkInTime,
                "Transfer has been blocked"
            );
            require(
                transferBlocked[ids[i]] == false,
                "Transfer has been stopped"
            );
            _safeTransferFrom(from, to, ids[i], amounts[i], data);
        }
    }

    // Function to mint Nft
    function mintNft(
        address creator,
        string memory roomUri,
        uint256 hotel
    ) private returns (uint256 id) {
        tokenCount.increment();
        uint256 nftId = tokenCount.current();
        _uri[nftId] = roomUri;
        _mint(creator, nftId, 1, "");
        nftToHotel[nftId] = hotel;
        idToMinter[nftId] = creator;
        emit Minted(nftId, creator);
        return (nftId);
    }
}