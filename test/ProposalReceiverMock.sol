// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.10;

contract ProposalReceiverMock {
  event MockFunctionCalled();

  function mockRecieverFunction() public payable returns (string memory) {
    emit MockFunctionCalled();
    return "0x1234";
  }
}
