    pragma solidity ^0.8.6;

    contract CavernDomain {

    bytes32 public DOMAIN_SEPARATOR;
    bytes32 public DOMAIN_TYPEHASH = keccak256("EIP712Domain(string name,uint256 chainId,address verifyingContract)");
    string private EIP191_PREFIX = "\x19\x01";

    ///////////////////////////////////////////////////////
    //////////////////////  PRIVATE  //////////////////////
    ///////////////////////////////////////////////////////

    function _getDigest(
        bytes32 hash
            ) internal view returns (bytes32 digest) {
                digest = keccak256(abi.encodePacked(EIP191_PREFIX, DOMAIN_SEPARATOR, hash));
    }

    function _getChainId(
        ) internal view returns (uint) {
            uint256 chainId;
            assembly { chainId := chainid() }
            return chainId;
    }

    function version(
        ) public pure virtual returns(string memory){
            return "1"; 
    }
}