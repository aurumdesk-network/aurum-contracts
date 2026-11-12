// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/// @title TapeCodeRewards
/// @notice The NFT Staking Pool, deployed on BNB Chain. Holds the TapeCode share of the AURUM tax as BNB and pays it to
///         the wallets that stake TapeCode NFTs on X Layer (TapeCodeStaking).
///
///  BNB Chain cannot read X Layer, so the owner (a multisig) publishes one list per period: the Merkle root of
///  (period, wallet, amount), built from TapeCodeStaking's state by a public script anyone can re-run. Then anyone may
///  send the rewards with the proofs; the BNB only ever goes to the wallet in the list, so nobody needs a key on a server.
///
///  What protects the BNB
///   - A list can only hand out BNB that is not promised to an earlier list; a published list cannot be cancelled.
///   - One list can never pay more than its total, whatever its tree holds.
///   - Periods must follow each other (`fromTime` == the previous `toTime`), so no span of time is paid twice.
///   - Lists are the only way out: no function lets the owner take BNB.
///  What the owner can do: decide what the lists say, within the BNB not yet promised.
contract TapeCodeRewards is Ownable2Step, ReentrancyGuard {
    /// @notice Gas one wallet gets inside a batch, so a wallet burning gas cannot stop the others. A smart-contract wallet
    ///         that needs more is paid through `pay`.
    uint256 public constant PAY_MANY_GAS = 50_000;

    struct Period {
        bytes32 root;
        uint256 total; // BNB this list hands out
        uint256 paid; // BNB already sent
        uint64 fromTime; // X Layer time the list starts counting from
        uint64 toTime; // X Layer time the list was taken at
    }

    struct Payment {
        uint256 period;
        address wallet;
        uint256 amount;
        bytes32[] proof;
    }

    Period[] public periods;
    mapping(uint256 => mapping(address => bool)) public isPaid;
    uint64 public lastToTime;
    uint256 public promised; // BNB in published lists, not yet sent
    uint256 public totalPaid;

    event BnbReceived(address indexed from, uint256 amount);
    event ListPublished(uint256 indexed period, bytes32 root, uint256 total, uint64 fromTime, uint64 toTime, string listUri);
    event Paid(uint256 indexed period, address indexed wallet, uint256 amount);
    event PaymentRefused(uint256 indexed period, address indexed wallet, uint256 amount);

    error BadList();
    error BadPeriod();
    error NotEnoughBnb();
    error BadProof();
    error AlreadyPaid();
    error OverPaid();
    error WalletRefusedBnb();

    constructor(address owner_) Ownable(owner_) {}

    /// @notice The tax share arrives here, from DeskPot inside a round. It only books the BNB, so a sale with little gas
    ///         left can always deliver the share.
    receive() external payable {
        emit BnbReceived(msg.sender, msg.value);
    }

    // ------------------------------------------------------------------
    // Lists
    // ------------------------------------------------------------------

    /// @notice BNB a new list may hand out.
    function available() public view returns (uint256) {
        return address(this).balance - promised;
    }

    function periodCount() external view returns (uint256) {
        return periods.length;
    }

    /// @notice Publish the list for [fromTime, toTime). `listUri` tells everyone where to read the full list.
    function publish(bytes32 root, uint256 total, uint64 fromTime, uint64 toTime, string calldata listUri) external onlyOwner {
        if (root == bytes32(0) || total == 0) revert BadList();
        if (fromTime != lastToTime || toTime <= fromTime || toTime > block.timestamp) revert BadPeriod();
        if (total > available()) revert NotEnoughBnb();
        uint256 id = periods.length;
        periods.push(Period(root, total, 0, fromTime, toTime));
        lastToTime = toTime;
        promised += total;
        emit ListPublished(id, root, total, fromTime, toTime, listUri);
    }

    /// @notice The hash stored in a list's Merkle tree.
    function leaf(uint256 period, address wallet, uint256 amount) public pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(period, wallet, amount))));
    }

    /// @notice Send one wallet its BNB. Anyone may call it; the BNB goes to `wallet`.
    function pay(uint256 period, address wallet, uint256 amount, bytes32[] calldata proof) external nonReentrant {
        if (isPaid[period][wallet]) revert AlreadyPaid();
        if (!_pay(period, wallet, amount, proof, gasleft())) revert WalletRefusedBnb();
    }

    /// @notice Send many wallets their BNB in one transaction. Wallets already paid are skipped, so one wallet claiming
    ///         first cannot make the whole batch fail, and a wallet refusing BNB stays unpaid without stopping the others.
    ///         A wrong proof still fails the batch.
    function payMany(Payment[] calldata list) external nonReentrant {
        for (uint256 i; i < list.length; ++i) {
            Payment calldata p = list[i];
            if (!isPaid[p.period][p.wallet]) _pay(p.period, p.wallet, p.amount, p.proof, PAY_MANY_GAS);
        }
    }

    /// @dev The books change before the BNB moves. A wallet that refuses it leaves them as they were: it can be paid later.
    function _pay(uint256 period, address wallet, uint256 amount, bytes32[] calldata proof, uint256 gasLimit) private returns (bool sent) {
        if (period >= periods.length) revert BadPeriod();
        Period storage p = periods[period];
        if (!MerkleProof.verifyCalldata(proof, p.root, leaf(period, wallet, amount))) revert BadProof();
        if (p.paid + amount > p.total) revert OverPaid();
        isPaid[period][wallet] = true;
        p.paid += amount;
        promised -= amount;
        totalPaid += amount;
        (sent, ) = wallet.call{value: amount, gas: gasLimit}("");
        if (sent) {
            emit Paid(period, wallet, amount);
            return true;
        }
        isPaid[period][wallet] = false;
        p.paid -= amount;
        promised += amount;
        totalPaid -= amount;
        emit PaymentRefused(period, wallet, amount);
    }
}
