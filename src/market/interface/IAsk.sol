pragma solidity ^0.8.16;

interface IAsk {
    function delegateFillAsk(address _tokenContract, uint256 _tokenId, address _fillCurrency, uint256 _fillAmount, address _receiver) external payable;
    
}