//SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.15;
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "solutils/contracts/utils/Strings2.sol";

contract Flowers is ERC721Enumerable, Ownable {

    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.UintSet;
    using Counters for Counters.Counter;
    using Strings2 for string;

    constructor(
        IMetadata metadata_,
        IERC20 lumen_
    ) ERC721("Flowers", "FLWS") {
        lumen = lumen_;
        metadata = metadata_;
    }

    IMetadata public metadata;
    IERC20 public lumen;
    Counters.Counter private _rNonce;

    struct Metadata {
        string key;
        string value;
    }

    struct MetadataYieldRateBoost {
        Metadata metadata;
        uint yieldRateBoost;
    }

    struct Location {
        address cAddr;
        uint tokenId;
    }

    struct LocationData {
        bool inLocation;
        Location location;
    }

    struct Apartment {
        EnumerableSet.UintSet flowers;
    }

    struct ApartmentData {
        uint maxPerApartment;
        MetadataYieldRateBoost[] metadataYieldRateBoosts;
        mapping(uint => Apartment) apartments;
    }

    struct Flower {
        LocationData locationData;

        bool uncloneable;

        uint baseYieldRate;
        uint lastClaimed;

        uint waterLevel;
        uint lastWatered;
    }

    mapping(uint => Flower) private _flowers;
    mapping(address => ApartmentData) private _apartmentData;

    uint[] public baseYieldRates;

    uint public defaultWater;
    uint public waterEffect;

    uint public waterCooldown;

    uint public price;
    uint public stock;

    uint public clonePrice;

    function setPrice(uint price_) external onlyOwner {
        price = price_;
    }

    function setClonePrice(uint price_) external onlyOwner {
        clonePrice = price_;
    }

    function increaseStock(uint stock_) external onlyOwner {
        stock += stock_;
    }

    function decreaseStock(uint stock_) external onlyOwner {
        stock -= stock_;
    }

    function setMaxPerApartment(address cAddr, uint max) external onlyOwner {
        _apartmentData[cAddr].maxPerApartment = max;
    }

    function getMaxPerApartment(address cAddr) external view returns(uint) {
        return _apartmentData[cAddr].maxPerApartment;
    }

    function setMetaDataYieldRateBoosts(address cAddr, MetadataYieldRateBoost[] calldata boosts) external onlyOwner {
        MetadataYieldRateBoost[] storage metadataYieldRateBoosts = _apartmentData[cAddr].metadataYieldRateBoosts;
        delete _apartmentData[cAddr].metadataYieldRateBoosts;
        uint length = boosts.length;
        for(uint i; i < length; i ++) {
            MetadataYieldRateBoost calldata boost = boosts[i];
            metadataYieldRateBoosts.push(boost);
        }
    }
    
    function getMetaDataYieldRateBoosts(address cAddr) external view returns(MetadataYieldRateBoost[] memory) {
       return _apartmentData[cAddr].metadataYieldRateBoosts;
    }

    function setBaseYieldRates(uint[] calldata baseYieldRates_) external onlyOwner {
        baseYieldRates = baseYieldRates_;
    }

    function getBaseYieldRates() external view returns(uint[] memory) {
        return baseYieldRates;
    }

    function setDefaultWater(uint defaultWater_) external onlyOwner {
        defaultWater = defaultWater_;
    }

    function setWaterEffect(uint waterEffect_) external onlyOwner {
        waterEffect = waterEffect_;
    }

    function setWaterCooldown(uint waterCooldown_) external onlyOwner {
        waterCooldown = waterCooldown_;
    }

    function getWaterLevel(uint tokenId) public view returns(uint) {
        Flower storage flower = _flowers[tokenId];

        if(!flower.locationData.inLocation) return flower.waterLevel;

        uint lost = block.timestamp - flower.lastWatered;
        return lost > flower.waterLevel ? 0 : flower.waterLevel - lost;
    }

    function getYieldRate(uint tokenId) public view returns(uint) {
        uint waterLevel = getWaterLevel(tokenId);
        Flower storage flower = _flowers[tokenId];
        if(
            !flower.locationData.inLocation ||
            waterLevel == 0
        ) return 0;
        return flower.baseYieldRate + _getMetadataYieldRateBoost(flower.locationData.location);
    }

    function getClaimable(uint tokenId) public view returns(uint) {
        Flower storage flower = _flowers[tokenId];
        uint yieldRate = getYieldRate(tokenId);
        uint yieldingFor = block.timestamp - flower.lastClaimed;
        return yieldingFor * yieldRate;
    }

    function isCloneable(uint tokenId) external view returns(bool) {
        return !_flowers[tokenId].uncloneable;
    }

    function isInLocation(uint tokenId) external view returns(bool) {
        return _flowers[tokenId].locationData.inLocation;
    }

    function getLocation(uint tokenId) external view returns(Location memory) {
        LocationData storage locationData = _flowers[tokenId].locationData;
        require(locationData.inLocation, "Flower is not in an apartment.");
        return locationData.location;
    }

    function purchase() external returns(uint) {
        lumen.safeTransferFrom(msg.sender, address(this), price);
        return _mintOneWithBaseYieldRate(msg.sender);
    }

    function mint(address to) external onlyOwner returns(uint) {
        return _mintOneWithBaseYieldRate(to);
    }

    function clone(uint tokenId) external returns(uint cloneTokenId) {
        lumen.safeTransferFrom(msg.sender, address(this), clonePrice);

        Flower storage flower = _flowers[tokenId];
        require(!flower.uncloneable, "Already cloned.");

        flower.uncloneable = true;

        cloneTokenId = _mintOne(msg.sender);
        Flower storage cloneFlower = _flowers[cloneTokenId];
        cloneFlower.baseYieldRate = flower.baseYieldRate;
        cloneFlower.uncloneable = true;
    }

    function water(uint tokenId) external {
        require(msg.sender == ownerOf(tokenId), "Can only water your own flower.");
        Flower storage flower = _flowers[tokenId];
        require(block.timestamp >= flower.lastWatered + waterCooldown);
        uint waterLevel = getWaterLevel(tokenId);
        flower.waterLevel = waterLevel + waterEffect;
        if(waterLevel == 0) flower.lastClaimed = block.timestamp;
        flower.lastWatered = block.timestamp;
    }

    function claim(uint tokenId) external {
        require(msg.sender == ownerOf(tokenId), "Can only claim for your own flower.");
        Flower storage flower = _flowers[tokenId];

        uint claimable = getClaimable(tokenId);
        lumen.safeTransfer(msg.sender, claimable);

        flower.lastClaimed = block.timestamp;
    }

    function enterApartment(Location calldata location, uint tokenId) external {
        require(msg.sender == ownerOf(tokenId), "Can only enter your own flower.");
        ApartmentData storage apartmentData = _apartmentData[location.cAddr];
        Apartment storage apartment = apartmentData.apartments[location.tokenId];
        require(apartment.flowers.length() < apartmentData.maxPerApartment);
        require(apartment.flowers.add(tokenId), "Flower already contained in apartment.");

        Flower storage flower = _flowers[tokenId];

        flower.lastClaimed = block.timestamp;
        flower.lastWatered = block.timestamp;

        LocationData storage locationData = flower.locationData;
        require(!locationData.inLocation, "Flower already in an apartment.");
        locationData.location = location;
        locationData.inLocation = true;
    }

    function exitApartment(uint tokenId) external {
        LocationData storage locationData = _flowers[tokenId].locationData;
        require(locationData.inLocation, "Flower is not in a location.");

        Location storage location = locationData.location;
        require(msg.sender == ownerOf(tokenId) || msg.sender == IERC721(location.cAddr).ownerOf(location.tokenId));

        EnumerableSet.UintSet storage flowers = _apartmentData[location.cAddr].apartments[location.tokenId].flowers;
        flowers.remove(tokenId);

        Flower storage flower = _flowers[tokenId];
        flower.waterLevel = getWaterLevel(tokenId);

        locationData.inLocation = false;
    }

    function withdraw(uint value) external onlyOwner {
        lumen.safeTransfer(msg.sender, value);
    }

    function _mintOneWithBaseYieldRate(address to) private returns(uint tokenId) {
        tokenId = _mintOne(to);

        uint length = baseYieldRates.length;
        require(length > 0, "Dev has not set the base yield rates.");
        uint index = _getRandom(length);
        uint yieldRate = baseYieldRates[index];
        
        Flower storage flower = _flowers[tokenId];

        flower.baseYieldRate = yieldRate;

        flower.waterLevel = defaultWater;
    }

    function _mintOne(address to) private returns(uint tokenId) {
        tokenId = totalSupply();
        _mint(to, tokenId);
    }

    function _beforeTokenTransfer(address, uint, uint tokenId) internal view {
        require(_flowers[tokenId].locationData.inLocation, "Please remove flower from apartment before making this action.");
    }

    function _getMetadataYieldRateBoost(Location storage location) internal view returns(uint boost) {
        MetadataYieldRateBoost[] storage metadataYieldRateBoosts = _apartmentData[location.cAddr].metadataYieldRateBoosts;
        uint length = metadataYieldRateBoosts.length;
        for(uint i; i < length; i ++) {
            MetadataYieldRateBoost storage metadataYieldRateBoost = metadataYieldRateBoosts[i];
            Metadata storage boostedMetadata = metadataYieldRateBoost.metadata;
            string memory value = metadata.attributes(location.cAddr, location.tokenId, boostedMetadata.key);
            if(value.equals(boostedMetadata.value)) boost += metadataYieldRateBoost.yieldRateBoost;
        }   
    }

    function _getRandom(uint d) private returns(uint) {
        uint rNonce = _getRNonce();
        bytes32 rHash = sha256(abi.encode(rNonce));
        uint rNumber = uint(rHash);
        return rNumber % d;

    }

    function _getRNonce() private returns(uint rNonce) {
        rNonce = _rNonce.current();
        _rNonce.increment();
    }

}


interface IMetadata {

    struct AttributeInput {
        string attribute;
        string value;
    }

    struct MetadataInput{
        address nftAddress;
        uint tokenId;
        AttributeInput[] attributes;
    }

    function METADATA_ROLE() external view returns(bytes32);

    function attributes(address nftAddress, uint tokenId, string memory attribute) external view returns(string memory);

    function setMetadata(MetadataInput[] memory metadatas) external;

}
