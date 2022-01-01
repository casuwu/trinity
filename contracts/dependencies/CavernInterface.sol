interface CavernInterface {
    function maxSupply() external view returns (uint256);
    function getPriorVotes(address account, uint blockNumber) external view returns (uint96);
}