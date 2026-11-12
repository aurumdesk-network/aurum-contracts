// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

interface IV2RouterLike {
    function WETH() external view returns (address);
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

interface IDeskTaxSink {
    function depositTax(uint256 deskSold) external payable;
}

/// @title AurumToken
/// @notice Fixed-supply token with a sell tax on its pools.
///         - Buy (pool -> buyer): no tax. Sell (seller -> pool): 5%. Wallet-to-wallet transfers are untaxed.
///         - Taxed pools: the main PancakeSwap V2 AURUM/WBNB pair (permanent) plus any pool the owner adds (a V3 pool,
///           a AURUM/USDT pair...), so routing around the main pair does not skip the tax. Pools can never be exempt.
///         - The tax is held by this contract and sold for BNB inside the next sell on the pair (before the
///           seller's tokens reach the pair), then sent to the DeskPot, which shares it out once 0.03 BNB has built up.
///           So the Desk Pot only ever receives BNB, with no keeper needed for taxes. Anyone may also call swapTaxes().
///         - One tax sale sells all the tax collected so far, however large. A failed tax sale or deposit never
///           blocks the user's trade: the tax simply waits for the next one.
///         - Sells must use the router's ...SupportingFeeOnTransferTokens functions.
///         - Rates are constants. No mint, no blacklist, no max-wallet, no way to block selling.
///         - Tax-exempt wallets exist only so the team can seed/manage liquidity: on a V2 pair adding
///           liquidity is indistinguishable from a sell.
contract AurumToken is ERC20, ERC20Burnable, Ownable2Step {
    uint256 public constant BUY_TAX_BPS = 0;
    uint256 public constant SELL_TAX_BPS = 500;
    uint256 public constant MAX_SWAP_THRESHOLD = 10_000_000 ether;
    uint256 internal constant BPS = 10_000;

    IDeskTaxSink public immutable taxCollector; // DeskPot
    IV2RouterLike public immutable router;
    address public immutable wbnb;
    address public pair; // main PancakeSwap V2 AURUM/WBNB pair: the collected tax is sold through it
    uint256 public swapThreshold = 10_000 ether; // tax is sold once this much AURUM has collected
    mapping(address => bool) public isTaxedPool; // trades with these addresses are taxed
    mapping(address => bool) public isTaxExempt;
    bool private inSwap;

    event PairSet(address indexed pair);
    event TaxedPoolSet(address indexed pool, bool taxed);
    event TaxExemptSet(address indexed account, bool exempt);
    event SwapThresholdSet(uint256 threshold);
    event TaxTaken(address indexed from, address indexed to, uint256 amount, bool isBuy);
    event TaxSold(uint256 deskSold, uint256 bnbOut, bool deposited);

    error ZeroAddress();
    error PairAlreadySet();
    error ThresholdTooHigh();
    error Busy();
    error MainPair();
    error PoolCannotBeExempt();

    constructor(
        string memory name_,
        string memory symbol_,
        uint256 supply,
        address recipient,
        address taxCollector_,
        address router_,
        address owner_
    ) ERC20(name_, symbol_) Ownable(owner_) {
        if (recipient == address(0) || taxCollector_ == address(0) || router_ == address(0)) revert ZeroAddress();
        taxCollector = IDeskTaxSink(taxCollector_);
        router = IV2RouterLike(router_);
        wbnb = IV2RouterLike(router_).WETH();
        _mint(recipient, supply);
    }

    /// @notice The V2 router pays the tax sale's BNB here before it is forwarded to the DeskPot.
    receive() external payable {}

    /// @notice One-time: the PancakeSwap V2 AURUM/WBNB pair whose buys and sells are taxed.
    function setPair(address pair_) external onlyOwner {
        if (pair_ == address(0)) revert ZeroAddress();
        if (pair != address(0)) revert PairAlreadySet();
        pair = pair_;
        isTaxedPool[pair_] = true;
        isTaxExempt[pair_] = false;
        emit PairSet(pair_);
        emit TaxedPoolSet(pair_, true);
    }

    /// @notice Tax trades with another pool too (e.g. a PancakeSwap V3 pool or a AURUM/USDT pair). The main pair
    ///         always stays taxed.
    function setTaxedPool(address pool, bool taxed) external onlyOwner {
        if (pool == address(0)) revert ZeroAddress();
        if (pool == pair && !taxed) revert MainPair();
        isTaxedPool[pool] = taxed;
        if (taxed && isTaxExempt[pool]) {
            isTaxExempt[pool] = false;
            emit TaxExemptSet(pool, false);
        }
        emit TaxedPoolSet(pool, taxed);
    }

    /// @notice Liquidity management only. A taxed pool can never be exempt (that would switch its tax off).
    function setTaxExempt(address account, bool exempt) external onlyOwner {
        if (exempt && isTaxedPool[account]) revert PoolCannotBeExempt();
        isTaxExempt[account] = exempt;
        emit TaxExemptSet(account, exempt);
    }

    function setSwapThreshold(uint256 threshold) external onlyOwner {
        if (threshold > MAX_SWAP_THRESHOLD) revert ThresholdTooHigh();
        swapThreshold = threshold;
        emit SwapThresholdSet(threshold);
    }

    /// @notice Sell the collected tax now (e.g. after a long run of buys with no sells). Gas is the caller's.
    function swapTaxes() external {
        if (inSwap) revert Busy();
        _sellTax();
    }

    function _update(address from, address to, uint256 value) internal override {
        bool sell = isTaxedPool[to]; // pool -> pool (a multi-hop route) counts as a sell into the second pool
        if (inSwap || value == 0 || (!sell && !isTaxedPool[from])) {
            super._update(from, to, value);
            return;
        }
        // a sell: turn the tax collected so far into BNB first (through the main pair; if that pair is the one
        // mid-swap, the sale simply fails and waits)
        if (sell && from != address(this)) _sellTax();
        if (!isTaxExempt[from] && !isTaxExempt[to]) {
            uint256 tax = (value * (sell ? SELL_TAX_BPS : BUY_TAX_BPS)) / BPS;
            if (tax != 0) {
                super._update(from, address(this), tax);
                value -= tax;
                emit TaxTaken(from, to, tax, !sell);
            }
        }
        super._update(from, to, value);
    }

    function _sellTax() private {
        address p = pair;
        uint256 amount = balanceOf(address(this));
        if (p == address(0) || amount < swapThreshold || amount == 0) return;

        inSwap = true;
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = wbnb;
        _approve(address(this), address(router), amount);
        uint256 before = address(this).balance;
        try router.swapExactTokensForETHSupportingFeeOnTransferTokens(amount, 0, path, address(this), block.timestamp) {
            uint256 out = address(this).balance - before;
            // forward everything held, including BNB from an earlier sale whose deposit failed
            uint256 all = address(this).balance;
            bool deposited;
            if (all != 0) {
                try taxCollector.depositTax{value: all}(amount) {
                    deposited = true;
                } catch {}
            }
            emit TaxSold(amount, out, deposited);
        } catch {
            _approve(address(this), address(router), 0);
        }
        inSwap = false;
    }
}
