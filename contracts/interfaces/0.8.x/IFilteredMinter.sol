// SPDX-License-Identifier: LGPL-3.0-only
// Created By: Art Blocks Inc.

pragma solidity ^0.8.0;

interface IFilteredMinter {
    /// togglePurchaseToDisabled updated
    event PurchaseToDisabledUpdated(
        uint256 _projectId,
        bool _purchaseToDisabled
    );

    // getter function of public variable
    function minterType() external view returns (string memory);

    // Triggers a purchase of a token from the desired project, to the
    // TX-sending address.
    function purchase(uint256 _projectId)
        external
        payable
        returns (uint256 tokenId);

    // Triggers a purchase of a token from the desired project, to the specified
    // receiving address.
    function purchaseTo(address _to, uint256 _projectId)
        external
        payable
        returns (uint256 tokenId);

    // Toggles the ability for `purchaseTo` to be called directly with a
    // specified receiving address that differs from the TX-sending address.
    function togglePurchaseToDisabled(uint256 _projectId) external;

    // Called to make the minter contract aware of the max invocations for a
    // given project.
    function setProjectMaxInvocations(uint256 _projectId) external;

    // Gets current price of minting a token, assuming this is project's minter
    function getPrice(uint256 _projectId) external returns (uint256);
}
