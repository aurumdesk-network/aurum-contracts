// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IDeskPotMintSink {
    function notifyMintBem(uint256 amount) external;
}

/// @title ChipSwap
/// @notice First step of minting a desk: pay 100,000 AURUM (burned) + 1 BEM (0.6 to the Desk Pot, 0.2 burned,
///         0.2 to the Protocol) and receive one set of circuit elements (4 NAND + 2 LATCH) from the project's stock.
///         The set is then taped out into a desk by DeskMinter.
///         The project mints the elements on its own TapeOut processor and transfers them here. Anyone may top up.
///         When the stock runs out, swaps revert until it is refilled.
///         BEM has no burn function, so its burned share goes to the dead address.
contract ChipSwap is ERC1155Holder, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant DESK_PER_SET = 100_000 ether;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    struct Element {
        address token; // ERC-1155 contract
        uint256 id;
        uint256 amount; // per set
    }

    ERC20Burnable public immutable desk;
    IERC20 public immutable bem;
    address public immutable pot;
    uint256 public immutable bemPerSet; // 1 BEM in its own decimals
    uint256 public immutable bemToPot; // 0.6 BEM
    uint256 public immutable bemToBurn; // 0.2 BEM
    address public protocol;
    Element[] internal recipe;
    uint256 public totalSets;
    uint256 public totalBemBurned;

    event Swapped(address indexed user, uint256 sets, uint256 deskBurned, uint256 bemToPot, uint256 bemBurned, uint256 bemToProtocol);
    event InventoryWithdrawn(address indexed to, address indexed token, uint256 indexed id, uint256 amount);
    event ProtocolSet(address indexed protocol);

    error EmptyRecipe();
    error ZeroAddress();
    error ZeroSets();
    error OutOfStock();

    constructor(address desk_, address bem_, address pot_, address protocol_, Element[] memory recipe_, address owner_)
        Ownable(owner_)
    {
        if (desk_ == address(0) || bem_ == address(0) || pot_ == address(0) || protocol_ == address(0)) revert ZeroAddress();
        if (recipe_.length == 0) revert EmptyRecipe();
        desk = ERC20Burnable(desk_);
        bem = IERC20(bem_);
        pot = pot_;
        protocol = protocol_;
        uint256 one = 10 ** IERC20Metadata(bem_).decimals();
        bemPerSet = one;
        bemToPot = (one * 6) / 10;
        bemToBurn = (one * 2) / 10;
        for (uint256 i; i < recipe_.length; ++i) {
            if (recipe_[i].token == address(0) || recipe_[i].amount == 0) revert ZeroAddress();
            recipe.push(recipe_[i]);
        }
    }

    /// @notice Caller must approve this contract for `sets` x 100,000 AURUM and `sets` x 1 BEM.
    function swap(uint256 sets) external nonReentrant {
        if (sets == 0) revert ZeroSets();
        if (sets > setsLeft()) revert OutOfStock();
        uint256 burned = sets * DESK_PER_SET;
        desk.burnFrom(msg.sender, burned);

        uint256 toPot = sets * bemToPot;
        uint256 toBurn = sets * bemToBurn;
        uint256 toProtocol = sets * bemPerSet - toPot - toBurn;
        bem.safeTransferFrom(msg.sender, pot, toPot);
        bem.safeTransferFrom(msg.sender, DEAD, toBurn);
        bem.safeTransferFrom(msg.sender, protocol, toProtocol);
        IDeskPotMintSink(pot).notifyMintBem(toPot);
        totalBemBurned += toBurn;

        totalSets += sets;
        for (uint256 i; i < recipe.length; ++i) {
            Element memory e = recipe[i];
            IERC1155(e.token).safeTransferFrom(address(this), msg.sender, e.id, e.amount * sets, "");
        }
        emit Swapped(msg.sender, sets, burned, toPot, toBurn, toProtocol);
    }

    function setProtocol(address protocol_) external onlyOwner {
        if (protocol_ == address(0)) revert ZeroAddress();
        protocol = protocol_;
        emit ProtocolSet(protocol_);
    }

    /// @notice Move unused elements out, e.g. when migrating to a new swap. Owner should be a multisig.
    function withdraw(address token, uint256 id, uint256 amount, address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        IERC1155(token).safeTransferFrom(address(this), to, id, amount, "");
        emit InventoryWithdrawn(to, token, id, amount);
    }

    /// @notice How many sets the current stock can still hand out.
    function setsLeft() public view returns (uint256 left) {
        left = type(uint256).max;
        for (uint256 i; i < recipe.length; ++i) {
            uint256 n = IERC1155(recipe[i].token).balanceOf(address(this), recipe[i].id) / recipe[i].amount;
            if (n < left) left = n;
        }
    }

    function recipeLength() external view returns (uint256) {
        return recipe.length;
    }

    function recipeAt(uint256 i) external view returns (Element memory) {
        return recipe[i];
    }
}
