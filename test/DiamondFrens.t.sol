// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";

import {DiamondFrens} from "../src/DiamondFrens.sol";

contract SampleContractTest is Test {
    DiamondFrens diamondFrens;

    function setUp() public {
        diamondFrens = new DiamondFrens();
    }
}
