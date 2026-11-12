// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {TapeCodeStaking} from "../src/TapeCodeStaking.sol";

/// @notice TapeCodeStaking against the real TapeCode-Test1 NFT, on an X Layer fork.
///   XLAYER_FORK_URL=http://127.0.0.1:8548 forge test --match-contract ForkTapeCode -vv
contract ForkTapeCodeTest is Test {
    IERC721 constant NFT = IERC721(0x0e91460D6823C711643e650A9a4C0cc21DE41614);
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 constant DEAD_ID = 5000; // one of the 3,000 NFTs held by 0xdEaD: free test stock on the fork

    TapeCodeStaking staking;
    address holder;
    bool forked;

    function setUp() public {
        string memory url = vm.envOr("XLAYER_FORK_URL", string(""));
        if (bytes(url).length == 0) return;
        vm.createSelectFork(url);
        forked = true;
        staking = new TapeCodeStaking(address(NFT));
        holder = makeAddr("xlayer-holder");
        vm.prank(DEAD);
        NFT.transferFrom(DEAD, holder, DEAD_ID);
        vm.prank(holder);
        NFT.setApprovalForAll(address(staking), true);
    }

    function _ids(uint256 a) internal pure returns (uint256[] memory x) {
        x = new uint256[](1);
        x[0] = a;
    }

    function test_fork_realNft_stakesAndComesBack() public {
        if (!forked) return;
        vm.prank(holder);
        staking.stake(_ids(DEAD_ID));
        assertEq(NFT.ownerOf(DEAD_ID), address(staking));
        assertEq(NFT.balanceOf(address(staking)), 1);
        skip(1000);
        assertEq(staking.pointsOf(holder), 1000);

        address thief = makeAddr("thief");
        vm.prank(thief);
        vm.expectRevert(TapeCodeStaking.NotStaker.selector);
        staking.unstake(_ids(DEAD_ID));

        vm.prank(holder);
        staking.unstake(_ids(DEAD_ID));
        assertEq(NFT.ownerOf(DEAD_ID), holder);
        assertEq(NFT.balanceOf(address(staking)), 0);
        assertEq(staking.pointsOf(holder), 1000);
    }

    function test_fork_realNft_someoneElsesNftCannotBeStaked() public {
        if (!forked) return;
        address thief = makeAddr("thief");
        vm.prank(thief);
        vm.expectRevert(TapeCodeStaking.NotOwner.selector);
        staking.stake(_ids(DEAD_ID));
        assertEq(NFT.ownerOf(DEAD_ID), holder);
    }

    function test_fork_realNft_needsApproval() public {
        if (!forked) return;
        vm.prank(holder);
        NFT.setApprovalForAll(address(staking), false);
        vm.prank(holder);
        vm.expectRevert();
        staking.stake(_ids(DEAD_ID));
    }

    function test_fork_realNft_safeTransferIsRefused() public {
        if (!forked) return;
        vm.prank(holder);
        vm.expectRevert();
        NFT.safeTransferFrom(holder, address(staking), DEAD_ID);
        assertEq(NFT.ownerOf(DEAD_ID), holder);
    }

    /// The largest real holder has 121 NFTs: staking them all in one transaction must fit a block.
    function test_fork_realNft_largeBatchFitsABlock() public {
        if (!forked) return;
        uint256[] memory ids = new uint256[](121);
        uint256 found;
        for (uint256 id = 4712; found < 121; ++id) {
            if (NFT.ownerOf(id) == DEAD) ids[found++] = id;
        }
        vm.startPrank(DEAD);
        NFT.setApprovalForAll(address(staking), true);
        uint256 before = gasleft();
        staking.stake(ids);
        uint256 usedStake = before - gasleft();
        before = gasleft();
        staking.unstake(ids);
        uint256 usedUnstake = before - gasleft();
        vm.stopPrank();
        emit log_named_uint("gas to stake 121", usedStake);
        emit log_named_uint("gas to unstake 121", usedUnstake);
        assertLt(usedStake, block.gaslimit / 2);
        assertLt(usedUnstake, block.gaslimit / 2);
    }
}
