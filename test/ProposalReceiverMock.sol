contract ProposalReceiverMock {
    event MockFunctionCalled();

    function mockRecieverFunction() public payable returns (string memory) {
        emit MockFunctionCalled();
        return "0x1234";
    }

}
