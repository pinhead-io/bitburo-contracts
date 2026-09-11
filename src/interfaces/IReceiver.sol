// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title IReceiver - ontvangt Chainlink CRE-rapporten via de KeystoneForwarder.
/// @notice Bron: docs.chain.link/cre/guides/workflow/using-evm-client/onchain-write/building-consumer-contracts
interface IReceiver is IERC165 {
    /// @param metadata abi.encodePacked(bytes32 workflowId, bytes10 workflowName, address workflowOwner, bytes2 reportId)
    /// @param report   Het door de DON ondertekende rapport, ABI-gecodeerd door de workflow.
    function onReport(bytes calldata metadata, bytes calldata report) external;
}
