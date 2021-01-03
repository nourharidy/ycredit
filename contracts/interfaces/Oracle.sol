// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface Oracle {
    function getPriceUSD(address reserve) external view returns (uint);
}