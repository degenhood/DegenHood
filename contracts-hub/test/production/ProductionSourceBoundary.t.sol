// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {DegenHoodTokenV5Deployer} from "../../src/deployers/DegenHoodTokenV5Deployer.sol";
import {DegenSpyV3Module} from "../../src/launchhub-spy-v3/DegenSpyV3Module.sol";
import {DegenV3Module} from "../../src/launchhub-v3/DegenV3Module.sol";
import {DegenSpyModule} from "../../src/production/ProductionDegenSpyModule.sol";
import {DegenWethModule} from "../../src/production/ProductionDegenWethModule.sol";
import {DegenHoodTokenV5} from "../../src/token/DegenHoodTokenV5.sol";

contract ProductionSourceBoundaryTest is Test {
    function testReviewedStagingCreationCodeRemainsPinned() public pure {
        assertEq(
            keccak256(type(DegenHoodTokenV5).creationCode),
            0x4dc305ad58939bf40e9f01de793aafe5b884a099746c78231f8c2348bc604cef
        );
        assertEq(
            keccak256(type(DegenHoodTokenV5Deployer).creationCode),
            0xb51977d09434a84e1be64e237dfbd66bdba387b88b61a3284d626cb3444b6187
        );
        assertEq(
            keccak256(type(DegenV3Module).creationCode),
            0xb30b3c9cf8939a1092a130b28d4b6eac72b5d44b5874becee93a97f57c4774d4
        );
        assertEq(
            keccak256(type(DegenSpyV3Module).creationCode),
            0xc638d8b0f9c85e3588f797f992e6170ba873a24fcb7a40b05bd073a01736d03a
        );
    }

    function testProductionModuleCreationCodeRemainsPinned() public pure {
        assertEq(
            keccak256(type(DegenWethModule).creationCode),
            0x7ed4cfbebd555ae270172e644ae82f1aa8235b832acf9a7b5139595a1e4fcc63
        );
        assertEq(
            keccak256(type(DegenSpyModule).creationCode),
            0xe78d3ec332cfa694a54b0c421e4f7da9671605884dbd74a63e4de842e72254f1
        );
    }
}
