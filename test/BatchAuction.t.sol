// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BatchAuction} from "../src/BatchAuction.sol";

interface Vm {
    function warp(uint256 timestamp) external;
    function deal(address account, uint256 balance) external;
    function prank(address sender) external;
    function expectRevert(bytes4 selector) external;
    function expectEmit(bool topic1, bool topic2, bool topic3, bool data, address emitter) external;
    function cool(address account) external;
}

contract AuctionTestToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    bool public feeOnTransfer;
    bool public failTransfers;
    bool public returnNothing;

    function mint(address account, uint256 amount) external {
        balanceOf[account] += amount;
    }

    function configure(bool fee, bool fail, bool noReturn) external {
        feeOnTransfer = fee;
        failTransfers = fail;
        returnNothing = noReturn;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        return _move(from, to, amount);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        return _move(msg.sender, to, amount);
    }

    function _move(address from, address to, uint256 amount) internal returns (bool) {
        balanceOf[from] -= amount;
        balanceOf[to] += feeOnTransfer && amount != 0 ? amount - 1 : amount;
        // Deliberately move first: a false return must roll back the entire call.
        if (failTransfers) return false;
        if (returnNothing) {
            assembly {
                return(0, 0)
            }
        }
        return true;
    }
}

contract AuctionClaimReceiver {
    BatchAuction public immutable house;
    uint256 public id;
    bool public isSeller;
    bool public rejectEther;
    bool public probe;
    bool public observedClaimed;
    bool public blockedBidderReentry;
    bool public blockedSellerReentry;

    constructor(BatchAuction auctionHouse) {
        house = auctionHouse;
    }

    function configure(uint256 auctionId, bool seller, bool reject, bool checkReentry) external {
        id = auctionId;
        isSeller = seller;
        rejectEther = reject;
        probe = checkReentry;
    }

    function takeClaim() external {
        if (isSeller) house.sellerClaim(id);
        else house.claim(id);
    }

    receive() external payable {
        require(!rejectEther, "receiver rejects ETH");
        if (!probe) return;
        observedClaimed = isSeller ? house.auction(id).sellerClaimed : house.bidOf(id, address(this)).claimed;
        (bool ok, bytes memory reason) = address(house).call(abi.encodeCall(BatchAuction.claim, (id)));
        blockedBidderReentry = !ok && bytes4(reason) == BatchAuction.ReentrantCall.selector;
        (ok, reason) = address(house).call(abi.encodeCall(BatchAuction.sellerClaim, (id)));
        blockedSellerReentry = !ok && bytes4(reason) == BatchAuction.ReentrantCall.selector;
    }
}

abstract contract BatchAuctionTestBase {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 internal constant UNIT = 1e18;
    address internal constant SELLER = address(0x5E11E2);
    bytes32 internal constant SALT = keccak256("private bid salt");
    BatchAuction internal house;
    AuctionTestToken internal token;

    event AuctionCreated(
        uint256 indexed id,
        address indexed seller,
        address indexed token,
        uint256 supply,
        uint256 reservePrice,
        uint256 minDeposit,
        uint64 commitEnd,
        uint64 revealEnd
    );
    event Committed(uint256 indexed id, address indexed bidder, bytes32 commitment, uint256 deposit);
    event Revealed(uint256 indexed id, address indexed bidder, uint256 price, uint256 amount, bool valid);
    event Finalized(uint256 indexed id, uint256 clearingPrice, uint256 sellerProceeds, uint256 returnedTokens);
    event Claimed(uint256 indexed id, address indexed bidder, uint256 tokens, uint256 refund);
    event SellerClaimed(uint256 indexed id, address indexed seller, uint256 tokens, uint256 proceeds);
    event log_named_uint(string name, uint256 value);

    function setUp() public {
        vm.warp(1_000);
        house = new BatchAuction();
        token = new AuctionTestToken();
        vm.deal(SELLER, 0);
    }

    function _bidder(uint256 index) internal pure returns (address) {
        return address(uint160(0x1000 + index));
    }

    function _create(uint256 supply, uint256 reserve, uint256 minimum) internal returns (uint256) {
        return _createAs(SELLER, supply, reserve, minimum);
    }

    function _createAs(address seller, uint256 supply, uint256 reserve, uint256 minimum) internal returns (uint256) {
        token.mint(seller, supply);
        vm.prank(seller);
        token.approve(address(house), supply);
        vm.prank(seller);
        return house.createAuction(
            address(token), supply, reserve, minimum, uint64(block.timestamp + 10), uint64(block.timestamp + 20)
        );
    }

    function _hash(uint256 id, address bidder, uint256 price, uint256 amount) internal pure returns (bytes32) {
        return keccak256(abi.encode(id, bidder, price, amount, SALT));
    }

    function _commit(uint256 id, uint256 index, uint256 price, uint256 amount, uint256 deposit) internal {
        address bidder = _bidder(index);
        vm.deal(bidder, deposit);
        vm.prank(bidder);
        house.commit{value: deposit}(id, _hash(id, bidder, price, amount));
    }

    function _openReveal(uint256 id) internal {
        vm.warp(house.auction(id).commitEnd);
    }

    function _reveal(uint256 id, uint256 index, uint256 price, uint256 amount) internal {
        vm.prank(_bidder(index));
        house.reveal(id, price, amount, SALT);
    }

    function _finalize(uint256 id) internal {
        vm.warp(uint256(house.auction(id).revealEnd) + 1);
        vm.prank(address(0xF1A1));
        house.finalize(id);
    }

    function _checkBid(uint256 id, uint256 index, uint256 filled, uint256 payment) internal view {
        BatchAuction.Bid memory b = house.bidOf(id, _bidder(index));
        require(b.filled == filled, "wrong fill");
        require(b.payment == payment, "wrong payment");
    }

    function _checkAuction(uint256 id, uint256 price, uint256 proceeds, uint256 returned) internal view {
        BatchAuction.Auction memory a = house.auction(id);
        require(a.finalized, "not finalized");
        require(a.clearingPrice == price && house.clearingPrice(id) == price, "wrong clearing price");
        require(a.sellerProceeds == proceeds, "wrong proceeds");
        require(a.returnedTokens == returned, "wrong returned tokens");
    }

    function _claim(uint256 id, uint256 index, uint256 filled, uint256 refund) internal {
        address bidder = _bidder(index);
        uint256 ethBefore = bidder.balance;
        uint256 tokensBefore = token.balanceOf(bidder);
        vm.prank(bidder);
        house.claim(id);
        require(bidder.balance - ethBefore == refund, "wrong ETH refund");
        require(token.balanceOf(bidder) - tokensBefore == filled, "wrong token payout");
        require(house.bidOf(id, bidder).claimed, "bidder claim not recorded");
    }

    function _sellerClaim(uint256 id, uint256 returned, uint256 proceeds) internal {
        address seller = house.auction(id).seller;
        uint256 ethBefore = seller.balance;
        uint256 tokensBefore = token.balanceOf(seller);
        vm.prank(seller);
        house.sellerClaim(id);
        require(seller.balance - ethBefore == proceeds, "wrong seller ETH");
        require(token.balanceOf(seller) - tokensBefore == returned, "wrong seller tokens");
        require(house.auction(id).sellerClaimed, "seller claim not recorded");
    }

    function _emptyEscrow() internal view {
        require(address(house).balance == 0, "ETH stranded");
        require(token.balanceOf(address(house)) == 0, "tokens stranded");
    }

    // Only called with bounded operands; deliberately independent of contract math.
    function _cost(uint256 amount, uint256 price) internal pure returns (uint256) {
        return (amount * price + UNIT - 1) / UNIT;
    }
}

contract BatchAuctionAllocationTest is BatchAuctionTestBase {
    function testTwoWayTieSplitsRemainderAtUniformPrice() public {
        uint256 id = _create(10, UNIT, 1);
        // Neither commitment order nor reveal order is sorted by price.
        _commit(id, 0, 2 * UNIT, 10, 22);
        _commit(id, 1, 3 * UNIT, 6, 20);
        _commit(id, 2, 5 * UNIT, 4, 35);
        _commit(id, 3, 3 * UNIT, 6, 25);
        _openReveal(id);
        _reveal(id, 3, 3 * UNIT, 6);
        _reveal(id, 2, 5 * UNIT, 4);
        _reveal(id, 0, 2 * UNIT, 10);
        _reveal(id, 1, 3 * UNIT, 6);
        _finalize(id);
        _checkAuction(id, 3 * UNIT, 30, 0);
        _checkBid(id, 0, 0, 0);
        _checkBid(id, 1, 3, 9);
        _checkBid(id, 2, 4, 12);
        _checkBid(id, 3, 3, 9);
        _claim(id, 0, 0, 22);
        _claim(id, 1, 3, 11);
        _claim(id, 2, 4, 23);
        _claim(id, 3, 3, 16);
        _sellerClaim(id, 0, 30);
        _emptyEscrow();
    }

    function testThreeWayUnevenTieFloorsSharesAndReturnsDust() public {
        uint256 id = _create(17, UNIT, 0);
        _commit(id, 0, 4 * UNIT, 7, 28);
        _commit(id, 1, 2 * UNIT, 5, 10);
        _commit(id, 2, 9 * UNIT, 4, 36);
        _commit(id, 3, 4 * UNIT, 11, 44);
        _commit(id, 4, 4 * UNIT, 3, 12);
        _openReveal(id);
        _reveal(id, 0, 4 * UNIT, 7);
        _reveal(id, 1, 2 * UNIT, 5);
        _reveal(id, 2, 9 * UNIT, 4);
        _reveal(id, 3, 4 * UNIT, 11);
        _reveal(id, 4, 4 * UNIT, 3);
        _finalize(id);
        // 13 remaining, demand 21: floor(13 * [7,11,3] / 21) = [4,6,1].
        _checkAuction(id, 4 * UNIT, 60, 2);
        _checkBid(id, 0, 4, 16);
        _checkBid(id, 1, 0, 0);
        _checkBid(id, 2, 4, 16);
        _checkBid(id, 3, 6, 24);
        _checkBid(id, 4, 1, 4);
        _sellerClaim(id, 2, 60);
        _claim(id, 4, 1, 8);
        _claim(id, 3, 6, 20);
        _claim(id, 2, 4, 20);
        _claim(id, 1, 0, 10);
        _claim(id, 0, 4, 12);
        _emptyEscrow();
    }

    function testSingleBidRoundsCostUpAndEmitsEveryAction() public {
        token.mint(SELLER, 7);
        vm.prank(SELLER);
        token.approve(address(house), 7);
        vm.expectEmit(true, true, true, true, address(house));
        emit AuctionCreated(0, SELLER, address(token), 7, UNIT, 1, 1010, 1020);
        vm.prank(SELLER);
        uint256 id = house.createAuction(address(token), 7, UNIT, 1, 1010, 1020);
        require(id == 0 && house.nextAuctionId() == 1, "wrong first ID");
        vm.expectEmit(true, true, false, true, address(house));
        emit Committed(id, _bidder(0), _hash(id, _bidder(0), UNIT + 1, 3), 8);
        _commit(id, 0, UNIT + 1, 3, 8);
        _openReveal(id);
        vm.expectEmit(true, true, false, true, address(house));
        emit Revealed(id, _bidder(0), UNIT + 1, 3, true);
        _reveal(id, 0, UNIT + 1, 3);
        vm.expectEmit(true, false, false, true, address(house));
        emit Finalized(id, UNIT + 1, 4, 4);
        _finalize(id);
        _checkAuction(id, UNIT + 1, 4, 4);
        _checkBid(id, 0, 3, 4);
        vm.expectEmit(true, true, false, true, address(house));
        emit Claimed(id, _bidder(0), 3, 4);
        _claim(id, 0, 3, 4);
        vm.expectEmit(true, true, false, true, address(house));
        emit SellerClaimed(id, SELLER, 4, 4);
        _sellerClaim(id, 4, 4);
        _emptyEscrow();
    }

    function testUndersubscribedAuctionUsesLowestValidPrice() public {
        uint256 id = _create(12, UNIT, 0);
        _commit(id, 0, 6 * UNIT, 3, 18);
        _commit(id, 1, 2 * UNIT, 1, 2);
        _commit(id, 2, 4 * UNIT, 5, 20);
        _openReveal(id);
        _reveal(id, 2, 4 * UNIT, 5);
        _reveal(id, 0, 6 * UNIT, 3);
        _reveal(id, 1, 2 * UNIT, 1);
        _finalize(id);
        _checkAuction(id, 2 * UNIT, 18, 3);
        _checkBid(id, 0, 3, 6);
        _checkBid(id, 1, 1, 2);
        _checkBid(id, 2, 5, 10);
        _claim(id, 0, 3, 12);
        _claim(id, 1, 1, 0);
        _claim(id, 2, 5, 10);
        _sellerClaim(id, 3, 18);
        _emptyEscrow();
    }

    function testExactExhaustionDoesNotUseNextLowerPrice() public {
        uint256 id = _create(5, UNIT, 0);
        _commit(id, 0, 2 * UNIT, 5, 10);
        _commit(id, 1, 5 * UNIT, 2, 10);
        _commit(id, 2, 4 * UNIT, 3, 12);
        _openReveal(id);
        _reveal(id, 0, 2 * UNIT, 5);
        _reveal(id, 1, 5 * UNIT, 2);
        _reveal(id, 2, 4 * UNIT, 3);
        _finalize(id);
        _checkAuction(id, 4 * UNIT, 20, 0);
        _checkBid(id, 0, 0, 0);
        _checkBid(id, 1, 2, 8);
        _checkBid(id, 2, 3, 12);
    }

    function testEveryBidBelowReserveIsFullyRefundable() public {
        uint256 id = _create(10, 3 * UNIT, 0);
        for (uint256 i; i < 3; ++i) {
            _commit(id, i, i * UNIT, 5, 10);
        }
        _openReveal(id);
        for (uint256 i; i < 3; ++i) {
            _reveal(id, i, i * UNIT, 5);
            require(!house.bidOf(id, _bidder(i)).valid, "below reserve accepted");
        }
        _finalize(id);
        _checkAuction(id, 0, 0, 10);
        for (uint256 i; i < 3; ++i) {
            _claim(id, i, 0, 10);
        }
        _sellerClaim(id, 10, 0);
        _emptyEscrow();
    }

    function testNoCommitmentsReturnsWholeLot() public {
        uint256 id = _create(7, UNIT, 0);
        _finalize(id);
        _checkAuction(id, 0, 0, 7);
        _sellerClaim(id, 7, 0);
        _emptyEscrow();
    }

    function testAllMarginalSharesZeroUseLowestActualWinnerAndReturnDust() public {
        uint256 id = _create(3, UNIT, 0);
        _commit(id, 0, 5 * UNIT, 2, 10);
        _commit(id, 1, 3 * UNIT, 1, 3);
        _commit(id, 2, 3 * UNIT, 1, 3);
        _commit(id, 3, UNIT, 1, 1);
        _openReveal(id);
        _reveal(id, 0, 5 * UNIT, 2);
        _reveal(id, 1, 3 * UNIT, 1);
        _reveal(id, 2, 3 * UNIT, 1);
        _reveal(id, 3, UNIT, 1);
        _finalize(id);
        _checkAuction(id, 5 * UNIT, 10, 1);
        _checkBid(id, 0, 2, 10);
        for (uint256 i = 1; i < 4; ++i) {
            _checkBid(id, i, 0, 0);
        }
    }

    function testTinyTiedLotWithNoActualWinnerRefundsEveryone() public {
        uint256 id = _create(1, UNIT, 0);
        _commit(id, 0, UNIT, 1, 1);
        _commit(id, 1, UNIT, 1, 1);
        _openReveal(id);
        _reveal(id, 0, UNIT, 1);
        _reveal(id, 1, UNIT, 1);
        _finalize(id);
        require(house.bidOf(id, _bidder(0)).valid && house.bidOf(id, _bidder(1)).valid, "tie invalid");
        _checkAuction(id, 0, 0, 1);
        _claim(id, 0, 0, 1);
        _claim(id, 1, 0, 1);
        _sellerClaim(id, 1, 0);
        _emptyEscrow();
    }
}

contract BatchAuctionValidationTest is BatchAuctionTestBase {
    function testCreateRejectsInvalidParametersWithoutTakingTokensOrId() public {
        token.mint(address(this), 10);
        token.approve(address(house), 10);
        vm.expectRevert(BatchAuction.InvalidParameters.selector);
        house.createAuction(address(token), 0, 1, 0, 1010, 1020);
        vm.expectRevert(BatchAuction.InvalidParameters.selector);
        house.createAuction(address(token), 1, 0, 0, 1010, 1020);
        vm.expectRevert(BatchAuction.InvalidParameters.selector);
        house.createAuction(address(token), 1, 1, 0, 1000, 1020);
        vm.expectRevert(BatchAuction.InvalidParameters.selector);
        house.createAuction(address(token), 1, 1, 0, 999, 1020);
        vm.expectRevert(BatchAuction.InvalidParameters.selector);
        house.createAuction(address(token), 1, 1, 0, 1010, 1010);
        vm.expectRevert(BatchAuction.InvalidParameters.selector);
        house.createAuction(address(token), 1, 1, 0, 1020, 1010);
        require(house.nextAuctionId() == 0, "failed creation consumed ID");
        require(token.balanceOf(address(this)) == 10, "failed creation took tokens");
    }

    function testFeeOnTransferAndFalseReturnRevertAtomically() public {
        token.mint(address(this), 10);
        token.approve(address(house), 10);
        token.configure(true, false, false);
        vm.expectRevert(BatchAuction.IncorrectTokenAmount.selector);
        house.createAuction(address(token), 10, 1, 0, 1010, 1020);
        require(token.balanceOf(address(this)) == 10, "fee transfer not rolled back");
        require(token.allowance(address(this), address(house)) == 10, "allowance not rolled back");
        token.configure(false, true, false);
        vm.expectRevert(BatchAuction.TransferFailed.selector);
        house.createAuction(address(token), 10, 1, 0, 1010, 1020);
        require(token.balanceOf(address(this)) == 10, "false return not rolled back");
        require(house.nextAuctionId() == 0, "failed creation consumed ID");
        _emptyEscrow();
    }

    function testMissingApprovalAndNonTokenAddressRevert() public {
        token.mint(address(this), 10);
        vm.expectRevert(BatchAuction.TransferFailed.selector);
        house.createAuction(address(token), 10, 1, 0, 1010, 1020);
        vm.expectRevert(BatchAuction.TransferFailed.selector);
        house.createAuction(address(0), 10, 1, 0, 1010, 1020);
        vm.expectRevert(BatchAuction.TransferFailed.selector);
        house.createAuction(_bidder(0), 10, 1, 0, 1010, 1020);
        _emptyEscrow();
    }

    function testReturnlessTokenWorksAndExistingEscrowDoesNotDistortBalanceDiff() public {
        token.configure(false, false, true);
        uint256 first = _create(7, UNIT, 0);
        uint256 second = _createAs(_bidder(9), 5, 2 * UNIT, 1);
        require(first == 0 && second == 1 && house.nextAuctionId() == 2, "IDs not sequential");
        BatchAuction.Auction memory a = house.auction(second);
        require(a.seller == _bidder(9) && a.token == address(token), "wrong auction parties");
        require(a.supply == 5 && a.reservePrice == 2 * UNIT && a.minDeposit == 1, "wrong parameters");
        require(a.commitEnd == 1010 && a.revealEnd == 1020, "wrong windows");
        require(!a.finalized && !a.sellerClaimed && a.commitmentCount == 0, "dirty new auction");
        require(a.clearingPrice == 0 && a.sellerProceeds == 0 && a.returnedTokens == 0, "dirty accounting");
        require(token.balanceOf(address(house)) == 12, "wrong custody");
        _finalize(first);
        _finalize(second);
        _sellerClaim(second, 5, 0);
        _sellerClaim(first, 7, 0);
        _emptyEscrow();
    }

    function testWrongSaltPriceAmountAndSenderCannotReveal() public {
        uint256 id = _create(10, UNIT, 0);
        _commit(id, 0, 2 * UNIT, 3, 6);
        vm.deal(_bidder(1), 6);
        vm.prank(_bidder(1));
        house.commit{value: 6}(id, _hash(id, _bidder(0), 2 * UNIT, 3));
        _openReveal(id);
        vm.expectRevert(BatchAuction.CommitmentMismatch.selector);
        vm.prank(_bidder(0));
        house.reveal(id, 2 * UNIT, 3, bytes32(uint256(SALT) ^ 1));
        vm.expectRevert(BatchAuction.CommitmentMismatch.selector);
        _reveal(id, 0, 3 * UNIT, 3);
        vm.expectRevert(BatchAuction.CommitmentMismatch.selector);
        _reveal(id, 0, 2 * UNIT, 4);
        vm.expectRevert(BatchAuction.CommitmentMismatch.selector);
        _reveal(id, 1, 2 * UNIT, 3);
        vm.expectRevert(BatchAuction.NoCommitment.selector);
        _reveal(id, 2, 2 * UNIT, 3);
        require(!house.bidOf(id, _bidder(0)).revealed, "failed reveal consumed commitment");
        _reveal(id, 0, 2 * UNIT, 3);
        vm.expectRevert(BatchAuction.AlreadyRevealed.selector);
        _reveal(id, 0, 2 * UNIT, 3);
    }

    function testCommitmentCannotBeReplayedInAnotherAuction() public {
        uint256 first = _create(10, UNIT, 0);
        uint256 second = _create(10, UNIT, 0);
        _commit(first, 0, UNIT, 2, 2);
        vm.deal(_bidder(0), 2);
        vm.prank(_bidder(0));
        house.commit{value: 2}(second, _hash(first, _bidder(0), UNIT, 2));
        _openReveal(first);
        _reveal(first, 0, UNIT, 2);
        vm.expectRevert(BatchAuction.CommitmentMismatch.selector);
        _reveal(second, 0, UNIT, 2);
    }

    function testPhaseBoundariesAndFinalizeOnce() public {
        uint256 id = _create(10, UNIT, 0);
        _commit(id, 0, UNIT, 2, 2);
        _commit(id, 1, UNIT, 2, 2);
        _commit(id, 2, UNIT, 2, 2);
        vm.warp(1009);
        _commit(id, 3, UNIT, 2, 2);
        vm.expectRevert(BatchAuction.WrongPhase.selector);
        _reveal(id, 0, UNIT, 2);
        vm.expectRevert(BatchAuction.WrongPhase.selector);
        house.finalize(id);
        vm.warp(1010);
        vm.expectRevert(BatchAuction.WrongPhase.selector);
        _commit(id, 4, UNIT, 2, 2);
        _reveal(id, 0, UNIT, 2);
        vm.warp(1020);
        _reveal(id, 1, UNIT, 2);
        vm.expectRevert(BatchAuction.WrongPhase.selector);
        house.finalize(id);
        vm.warp(1021);
        vm.expectRevert(BatchAuction.WrongPhase.selector);
        _reveal(id, 2, UNIT, 2);
        house.finalize(id);
        vm.expectRevert(BatchAuction.AlreadyFinalized.selector);
        house.finalize(id);
        vm.expectRevert(BatchAuction.WrongPhase.selector);
        _reveal(id, 3, UNIT, 2);
    }

    function testInvalidRevealsRefundButCannotBeRevealedAgain() public {
        uint256 id = _create(10, UNIT, 0);
        _commit(id, 0, UNIT, 0, 7);
        _commit(id, 1, UNIT, 11, 11);
        _commit(id, 2, UNIT + 1, 1, 1); // floor cost is 1, required ceiling is 2.
        _commit(id, 3, UNIT - 1, 1, 7);
        _openReveal(id);
        vm.expectEmit(true, true, false, true, address(house));
        emit Revealed(id, _bidder(0), UNIT, 0, false);
        _reveal(id, 0, UNIT, 0);
        _reveal(id, 1, UNIT, 11);
        _reveal(id, 2, UNIT + 1, 1);
        _reveal(id, 3, UNIT - 1, 1);
        for (uint256 i; i < 4; ++i) {
            BatchAuction.Bid memory b = house.bidOf(id, _bidder(i));
            require(b.revealed && !b.valid, "invalid bid accepted");
            vm.expectRevert(BatchAuction.AlreadyRevealed.selector);
            _reveal(id, i, b.price, b.amount);
        }
        _finalize(id);
        _checkAuction(id, 0, 0, 10);
        _claim(id, 0, 0, 7);
        _claim(id, 1, 0, 11);
        _claim(id, 2, 0, 1);
        _claim(id, 3, 0, 7);
        _sellerClaim(id, 10, 0);
        _emptyEscrow();
    }

    function testAllViewsAndActionsRejectUnknownAuction() public {
        uint256 missing = 0;
        vm.expectRevert(BatchAuction.InvalidAuction.selector);
        house.auction(missing);
        vm.expectRevert(BatchAuction.InvalidAuction.selector);
        house.bidOf(missing, address(this));
        vm.expectRevert(BatchAuction.InvalidAuction.selector);
        house.clearingPrice(missing);
        vm.expectRevert(BatchAuction.InvalidAuction.selector);
        house.commit(missing, bytes32(0));
        vm.expectRevert(BatchAuction.InvalidAuction.selector);
        house.reveal(missing, 1, 1, SALT);
        vm.expectRevert(BatchAuction.InvalidAuction.selector);
        house.finalize(missing);
        vm.expectRevert(BatchAuction.InvalidAuction.selector);
        house.claim(missing);
        vm.expectRevert(BatchAuction.InvalidAuction.selector);
        house.sellerClaim(missing);
    }
}

contract BatchAuctionClaimsTest is BatchAuctionTestBase {
    function testUnrevealedDepositIsForfeitedAndNothingIsPushedAtFinalize() public {
        uint256 id = _create(10, UNIT, 1);
        _commit(id, 0, 2 * UNIT, 3, 10);
        _commit(id, 1, 20 * UNIT, 10, 200);
        _commit(id, 2, 0, 1, 7);
        _openReveal(id);
        _reveal(id, 0, 2 * UNIT, 3);
        _reveal(id, 2, 0, 1);
        _finalize(id);
        _checkAuction(id, 2 * UNIT, 206, 7);
        require(SELLER.balance == 0 && token.balanceOf(SELLER) == 0, "seller paid without claim");
        require(_bidder(0).balance == 0 && token.balanceOf(_bidder(0)) == 0, "bidder paid without claim");
        require(address(house).balance == 217 && token.balanceOf(address(house)) == 10, "custody changed");
        _claim(id, 1, 0, 0);
        _sellerClaim(id, 7, 206);
        _claim(id, 2, 0, 7);
        _claim(id, 0, 3, 4);
        _emptyEscrow();
    }

    function testClaimsRequireFinalizationAndCorrectCallerAndCannotRepeat() public {
        uint256 id = _create(4, UNIT, 0);
        _commit(id, 0, UNIT, 3, 4);
        vm.expectRevert(BatchAuction.NotFinalized.selector);
        vm.prank(_bidder(0));
        house.claim(id);
        vm.expectRevert(BatchAuction.NotFinalized.selector);
        vm.prank(SELLER);
        house.sellerClaim(id);
        _openReveal(id);
        _reveal(id, 0, UNIT, 3);
        vm.expectRevert(BatchAuction.NotFinalized.selector);
        vm.prank(_bidder(0));
        house.claim(id);
        _finalize(id);
        vm.expectRevert(BatchAuction.NoCommitment.selector);
        house.claim(id);
        vm.expectRevert(BatchAuction.NotSeller.selector);
        vm.prank(_bidder(0));
        house.sellerClaim(id);
        _claim(id, 0, 3, 1);
        vm.expectRevert(BatchAuction.AlreadyClaimed.selector);
        vm.prank(_bidder(0));
        house.claim(id);
        _sellerClaim(id, 1, 3);
        vm.expectRevert(BatchAuction.AlreadyClaimed.selector);
        vm.prank(SELLER);
        house.sellerClaim(id);
        _emptyEscrow();
    }

    function testZeroPayoutForfeiterCanClaimOnlyOnce() public {
        uint256 id = _create(1, UNIT, 0);
        _commit(id, 0, UNIT, 1, 1);
        _finalize(id);
        _claim(id, 0, 0, 0);
        vm.expectRevert(BatchAuction.AlreadyClaimed.selector);
        vm.prank(_bidder(0));
        house.claim(id);
        _sellerClaim(id, 1, 1);
        _emptyEscrow();
    }

    function testSellerCanAlsoBidAndClaimsAreIndependent() public {
        uint256 id = _createAs(_bidder(0), 5, UNIT, 0);
        _commit(id, 0, 2 * UNIT, 3, 10);
        _openReveal(id);
        _reveal(id, 0, 2 * UNIT, 3);
        _finalize(id);
        _sellerClaim(id, 2, 6);
        require(!house.bidOf(id, _bidder(0)).claimed, "seller claim consumed bid claim");
        _claim(id, 0, 3, 4);
        require(token.balanceOf(_bidder(0)) == 5 && _bidder(0).balance == 10, "self-bid lost assets");
        _emptyEscrow();
    }

    function testConcurrentAuctionsKeepClaimsAndEscrowSeparate() public {
        uint256 first = _create(10, UNIT, 0);
        uint256 second = _createAs(_bidder(9), 20, UNIT, 0);
        _commit(first, 0, 2 * UNIT, 3, 8);
        _commit(second, 0, 3 * UNIT, 4, 15);
        _openReveal(first);
        _reveal(first, 0, 2 * UNIT, 3);
        _reveal(second, 0, 3 * UNIT, 4);
        _finalize(second);
        _claim(second, 0, 4, 3);
        _sellerClaim(second, 16, 12);
        require(address(house).balance == 8 && token.balanceOf(address(house)) == 10, "other escrow spent");
        require(!house.auction(first).finalized && !house.bidOf(first, _bidder(0)).claimed, "state leaked");
        _finalize(first);
        _sellerClaim(first, 7, 6);
        _claim(first, 0, 3, 2);
        _emptyEscrow();
    }

    function testTokenTransferFailureRollsBackBidderAndSellerClaims() public {
        uint256 id = _create(5, UNIT, 0);
        _commit(id, 0, UNIT, 3, 4);
        _openReveal(id);
        _reveal(id, 0, UNIT, 3);
        _finalize(id);
        token.configure(false, true, false);
        vm.expectRevert(BatchAuction.TransferFailed.selector);
        vm.prank(_bidder(0));
        house.claim(id);
        require(!house.bidOf(id, _bidder(0)).claimed, "failed token payout consumed claim");
        require(token.balanceOf(_bidder(0)) == 0 && _bidder(0).balance == 0, "partial bidder payout");
        vm.expectRevert(BatchAuction.TransferFailed.selector);
        vm.prank(SELLER);
        house.sellerClaim(id);
        require(!house.auction(id).sellerClaimed, "failed seller payout consumed claim");
        require(token.balanceOf(SELLER) == 0 && SELLER.balance == 0, "partial seller payout");
        require(address(house).balance == 4 && token.balanceOf(address(house)) == 5, "failed claims moved assets");
        token.configure(false, false, false);
        _claim(id, 0, 3, 1);
        _sellerClaim(id, 2, 3);
        _emptyEscrow();
    }

    function testRejectingBidderCanRetryAndSeesEffectsBeforeReentrantCallback() public {
        uint256 id = _create(5, UNIT, 0);
        AuctionClaimReceiver receiver = new AuctionClaimReceiver(house);
        receiver.configure(id, false, true, false);
        vm.deal(address(receiver), 5);
        vm.prank(address(receiver));
        house.commit{value: 5}(id, _hash(id, address(receiver), UNIT, 3));
        _openReveal(id);
        vm.prank(address(receiver));
        house.reveal(id, UNIT, 3, SALT);
        _finalize(id); // A rejecting recipient cannot prevent settlement.
        vm.expectRevert(BatchAuction.TransferFailed.selector);
        receiver.takeClaim();
        require(!house.bidOf(id, address(receiver)).claimed, "failed refund consumed claim");
        require(token.balanceOf(address(receiver)) == 0, "token transfer survived ETH failure");
        require(token.balanceOf(address(house)) == 5 && address(house).balance == 5, "partial failed payout");
        receiver.configure(id, false, false, true);
        receiver.takeClaim();
        require(receiver.observedClaimed(), "bidder effects follow callback");
        require(receiver.blockedBidderReentry() && receiver.blockedSellerReentry(), "reentrancy not blocked");
        require(token.balanceOf(address(receiver)) == 3 && address(receiver).balance == 2, "wrong receiver payout");
        _sellerClaim(id, 2, 3);
        _emptyEscrow();
    }

    function testRejectingSellerCanRetryAndSeesEffectsBeforeReentrantCallback() public {
        AuctionClaimReceiver receiver = new AuctionClaimReceiver(house);
        uint256 id = _createAs(address(receiver), 5, UNIT, 0);
        receiver.configure(id, true, true, false);
        _commit(id, 0, UNIT, 3, 4);
        _openReveal(id);
        _reveal(id, 0, UNIT, 3);
        _finalize(id);
        vm.expectRevert(BatchAuction.TransferFailed.selector);
        receiver.takeClaim();
        require(!house.auction(id).sellerClaimed, "failed seller ETH consumed claim");
        require(token.balanceOf(address(receiver)) == 0, "returned tokens survived failed ETH");
        _claim(id, 0, 3, 1); // Other claims remain live after a failed seller transfer.
        receiver.configure(id, true, false, true);
        receiver.takeClaim();
        require(receiver.observedClaimed(), "seller effects follow callback");
        require(receiver.blockedBidderReentry() && receiver.blockedSellerReentry(), "seller reentrancy not blocked");
        require(token.balanceOf(address(receiver)) == 2 && address(receiver).balance == 3, "wrong seller payout");
        _emptyEscrow();
    }
}

contract BatchAuctionCapacityTest is BatchAuctionTestBase {
    function testMinimumDepositDuplicateCommitmentAnd64SlotLimit() public {
        uint256 id = _create(10, UNIT, 7);
        vm.expectRevert(BatchAuction.InsufficientDeposit.selector);
        _commit(id, 0, UNIT, 1, 6);
        require(house.auction(id).commitmentCount == 0, "failed deposit occupied slot");
        require(!house.bidOf(id, _bidder(0)).committed && address(house).balance == 0, "failed commit persisted");
        for (uint256 i; i < 64; ++i) {
            _commit(id, i, UNIT, 1, 7);
        }
        require(house.auction(id).commitmentCount == 64, "wrong commitment count");
        vm.expectRevert(BatchAuction.AlreadyCommitted.selector);
        _commit(id, 0, 2 * UNIT, 1, 7);
        vm.expectRevert(BatchAuction.AuctionFull.selector);
        _commit(id, 64, UNIT, 1, 7);
        require(house.bidOf(id, _bidder(0)).commitment == _hash(id, _bidder(0), UNIT, 1), "commit overwritten");
        require(!house.bidOf(id, _bidder(64)).committed, "65th bid recorded");
        _finalize(id);
        _checkAuction(id, 0, 448, 10);
        _sellerClaim(id, 10, 448);
        _emptyEscrow();
    }

    function testZeroHashAndZeroDepositStillOccupyExactlyOneSlot() public {
        uint256 id = _create(1, UNIT, 0);
        for (uint256 i; i < 64; ++i) {
            vm.prank(_bidder(i));
            house.commit(id, bytes32(0));
        }
        require(house.bidOf(id, _bidder(0)).committed, "zero commitment ignored");
        vm.expectRevert(BatchAuction.AlreadyCommitted.selector);
        vm.prank(_bidder(0));
        house.commit(id, bytes32(0));
        vm.expectRevert(BatchAuction.AuctionFull.selector);
        vm.prank(_bidder(64));
        house.commit(id, bytes32(0));
        _finalize(id);
        _checkAuction(id, 0, 0, 1);
        _claim(id, 0, 0, 0);
        _sellerClaim(id, 1, 0);
        _emptyEscrow();
    }

    function testRevealedInvalidSlotFillerRecoversDeposit() public {
        // Documents the specified economic limitation: minDeposit locks capital,
        // but an actor revealing invalid bids can recover it after filling slots.
        uint256 id = _create(1, UNIT, 9);
        for (uint256 i; i < 64; ++i) {
            _commit(id, i, 0, 0, 9);
        }
        vm.expectRevert(BatchAuction.AuctionFull.selector);
        _commit(id, 64, UNIT, 1, 9);
        _openReveal(id);
        for (uint256 i; i < 64; ++i) {
            _reveal(id, i, 0, 0);
        }
        _finalize(id);
        _checkAuction(id, 0, 0, 1);
        for (uint256 i; i < 64; ++i) {
            _claim(id, i, 0, 9);
        }
        _sellerClaim(id, 1, 0);
        _emptyEscrow();
    }

    function testDepositIsPublicWhileBidDetailsWaitForReveal() public {
        uint256 id = _create(10, UNIT, 0);
        _commit(id, 0, 3 * UNIT, 2, 6);
        _commit(id, 1, 3 * UNIT, 2, 60);
        for (uint256 i; i < 2; ++i) {
            BatchAuction.Bid memory b = house.bidOf(id, _bidder(i));
            require(b.committed && !b.revealed && !b.valid, "unrevealed status wrong");
            require(b.commitment == _hash(id, _bidder(i), 3 * UNIT, 2), "wrong public commitment");
            require(b.deposit == (i == 0 ? 6 : 60), "deposit is not exposed");
            require(b.price == 0 && b.amount == 0 && b.filled == 0 && b.payment == 0, "bid exposed early");
        }
        _openReveal(id);
        _reveal(id, 0, 3 * UNIT, 2);
        _reveal(id, 1, 3 * UNIT, 2);
        _finalize(id);
        _checkBid(id, 0, 2, 6);
        _checkBid(id, 1, 2, 6);
        _claim(id, 0, 2, 0);
        _claim(id, 1, 2, 54);
        _sellerClaim(id, 6, 12);
        _emptyEscrow();
    }

    function testFinalize64AscendingPricesWorstInsertionOrderGas() public {
        uint256 id = _create(64, UNIT, 0);
        for (uint256 i; i < 64; ++i) {
            _commit(id, i, (i + 1) * UNIT, 1, i + 1);
        }
        _openReveal(id);
        for (uint256 i; i < 64; ++i) {
            _reveal(id, i, (i + 1) * UNIT, 1);
        }
        vm.warp(1021);
        vm.cool(address(house));
        uint256 gasBefore = gasleft();
        house.finalize(id);
        uint256 used = gasBefore - gasleft();
        emit log_named_uint("finalize gas: 64 ascending prices", used);
        require(used < 30_000_000, "finalize exceeds 30 million gas review budget");
        _checkAuction(id, UNIT, 64, 0);
        for (uint256 i; i < 64; ++i) {
            _checkBid(id, i, 1, 1);
        }
    }
}

contract BatchAuctionWideMathTest is BatchAuctionTestBase {
    function testCostSupportsOverflowingIntermediateProduct() public {
        uint256 supply = uint256(1) << 200;
        uint256 id = _create(supply, UNIT, 0);
        _commit(id, 0, UNIT, supply, supply);
        _openReveal(id);
        _reveal(id, 0, UNIT, supply);
        require(house.bidOf(id, _bidder(0)).valid, "representable cost rejected");
        _finalize(id);
        _checkAuction(id, UNIT, supply, 0);
        _checkBid(id, 0, supply, supply);
        _claim(id, 0, supply, 0);
        _sellerClaim(id, 0, supply);
        _emptyEscrow();
    }

    function testUnrepresentableCostInvalidatesBidWithoutRevertingReveal() public {
        uint256 supply = type(uint256).max;
        uint256 id = _create(supply, 1, 0);
        _commit(id, 0, UNIT + 1, supply, 1);
        _openReveal(id);
        _reveal(id, 0, UNIT + 1, supply);
        BatchAuction.Bid memory b = house.bidOf(id, _bidder(0));
        require(b.revealed && !b.valid, "overflowing cost accepted");
        _finalize(id);
        _checkAuction(id, 0, 0, supply);
        _claim(id, 0, 0, 1);
        _sellerClaim(id, supply, 0);
        _emptyEscrow();
    }

    function testProRataProductOverflowsButDemandFitsUint256() public {
        uint256 supply = uint256(1) << 200;
        uint256 deposit = supply / UNIT + 1;
        uint256 payment = (supply / 2) / UNIT + 1;
        uint256 id = _create(supply, 1, 0);
        _commit(id, 0, 1, supply, deposit);
        _commit(id, 1, 1, supply, deposit);
        _openReveal(id);
        _reveal(id, 0, 1, supply);
        _reveal(id, 1, 1, supply);
        _finalize(id);
        _checkAuction(id, 1, 2 * payment, 0);
        for (uint256 i; i < 2; ++i) {
            _checkBid(id, i, supply / 2, payment);
            _claim(id, i, supply / 2, deposit - payment);
        }
        _sellerClaim(id, 0, 2 * payment);
        _emptyEscrow();
    }

    function testUnevenTieWithDemandExactlyTwoTo256() public {
        uint256 supply = type(uint256).max;
        uint256 id = _create(supply, 1, 0);
        uint256[3] memory amounts = [uint256(1) << 255, uint256(1) << 254, uint256(1) << 254];
        for (uint256 i; i < 3; ++i) {
            _commit(id, i, 1, amounts[i], amounts[i] / UNIT + 1);
        }
        _openReveal(id);
        for (uint256 i; i < 3; ++i) {
            _reveal(id, i, 1, amounts[i]);
        }
        _finalize(id);
        uint256 proceeds;
        // floor((2^256 - 1) * amount / 2^256) = amount - 1.
        for (uint256 i; i < 3; ++i) {
            uint256 filled = amounts[i] - 1;
            uint256 payment = filled / UNIT + 1;
            proceeds += payment;
            _checkBid(id, i, filled, payment);
            _claim(id, i, filled, (amounts[i] / UNIT + 1) - payment);
        }
        _checkAuction(id, 1, proceeds, 2);
        _sellerClaim(id, 2, proceeds);
        _emptyEscrow();
    }

    function testFinalize64MaxUintAmountsTieArithmeticAndGas() public {
        uint256 supply = type(uint256).max;
        uint256 id = _create(supply, 1, 0);
        uint256 deposit = supply / UNIT + 1;
        for (uint256 i; i < 64; ++i) {
            _commit(id, i, 1, supply, deposit);
        }
        _openReveal(id);
        for (uint256 i; i < 64; ++i) {
            _reveal(id, i, 1, supply);
        }
        vm.warp(1021);
        vm.cool(address(house));
        uint256 gasBefore = gasleft();
        house.finalize(id);
        uint256 used = gasBefore - gasleft();
        emit log_named_uint("finalize gas: 64 max-uint tied amounts", used);
        require(used < 30_000_000, "wide-demand finalize exceeds 30 million gas review budget");
        uint256 filled = supply / 64;
        uint256 payment = filled / UNIT + 1;
        _checkAuction(id, 1, payment * 64, supply % 64);
        for (uint256 i; i < 64; ++i) {
            _checkBid(id, i, filled, payment);
            _claim(id, i, filled, deposit - payment);
        }
        _sellerClaim(id, supply % 64, payment * 64);
        _emptyEscrow();
    }
}

contract BatchAuctionFuzzTest is BatchAuctionTestBase {
    struct InputBid {
        uint256 price;
        uint256 amount;
        uint256 deposit;
        bool revealBid;
    }

    struct Expected {
        uint256[] fills;
        uint256[] payments;
        uint256 price;
        uint256 proceeds;
        uint256 returned;
        uint256 deposits;
    }

    function _valid(InputBid memory b, uint256 supply, uint256 reserve) internal pure returns (bool) {
        return b.revealBid && b.price >= reserve && b.amount != 0 && b.amount <= supply
            && b.deposit >= _cost(b.amount, b.price);
    }

    // Independent oracle: no sorting or sequential allocation. For each bidder,
    // sum demand strictly above its price and demand exactly at its price.
    function _model(InputBid[] memory bids, uint256 supply, uint256 reserve) internal pure returns (Expected memory e) {
        e.fills = new uint256[](bids.length);
        e.payments = new uint256[](bids.length);
        e.returned = supply;
        for (uint256 i; i < bids.length; ++i) {
            e.deposits += bids[i].deposit;
            if (!bids[i].revealBid) e.proceeds += bids[i].deposit;
            if (!_valid(bids[i], supply, reserve)) continue;
            uint256 higher;
            uint256 tied;
            for (uint256 j; j < bids.length; ++j) {
                if (!_valid(bids[j], supply, reserve)) continue;
                if (bids[j].price > bids[i].price) higher += bids[j].amount;
                else if (bids[j].price == bids[i].price) tied += bids[j].amount;
            }
            if (higher >= supply) continue;
            uint256 available = supply - higher;
            e.fills[i] = available >= tied ? bids[i].amount : bids[i].amount * available / tied;
            e.returned -= e.fills[i];
            if (e.fills[i] != 0 && (e.price == 0 || bids[i].price < e.price)) e.price = bids[i].price;
        }
        for (uint256 i; i < bids.length; ++i) {
            e.payments[i] = _cost(e.fills[i], e.price);
            e.proceeds += e.payments[i];
        }
    }

    function testFuzzRandomBidSetsMatchModelAndConserveActualPayouts(uint256 seed, uint8 countSeed) public {
        uint256 supply = 1 + seed % 1000;
        uint256 reserve = (1 + (seed / 1000) % 4) * (UNIT / 7);
        uint256 id = _create(supply, reserve, 0);
        InputBid[] memory bids = new InputBid[](uint256(countSeed) % 65);
        for (uint256 i; i < bids.length; ++i) {
            uint256 random = uint256(keccak256(abi.encode(seed, i)));
            InputBid memory b;
            b.price = (random % 10) * (UNIT / 7);
            b.amount = (random >> 16) % (supply + 20);
            uint256 cost = _cost(b.amount, b.price);
            b.deposit = (random >> 32) % 4 == 0 && cost != 0 ? cost - 1 : cost + (random >> 40) % 13;
            b.revealBid = (random >> 64) % 4 != 0;
            bids[i] = b;
            _commit(id, i, b.price, b.amount, b.deposit);
        }
        Expected memory expected = _model(bids, supply, reserve);
        _openReveal(id);
        for (uint256 i = bids.length; i != 0;) {
            --i;
            if (bids[i].revealBid) _reveal(id, i, bids[i].price, bids[i].amount);
        }
        _finalize(id);
        _checkAuction(id, expected.price, expected.proceeds, expected.returned);
        require(address(house).balance == expected.deposits, "finalize pushed ETH");
        require(token.balanceOf(address(house)) == supply, "finalize pushed tokens");
        bool sellerFirst = seed % 2 == 0;
        if (sellerFirst) _sellerClaim(id, expected.returned, expected.proceeds);
        uint256 totalRefunds;
        uint256 totalFilled;
        for (uint256 n; n < bids.length; ++n) {
            uint256 i = sellerFirst ? n : bids.length - n - 1;
            BatchAuction.Bid memory actual = house.bidOf(id, _bidder(i));
            require(actual.valid == _valid(bids[i], supply, reserve), "validity differs from model");
            require(actual.revealed == bids[i].revealBid, "wrong reveal state");
            _checkBid(id, i, expected.fills[i], expected.payments[i]);
            uint256 refund = bids[i].revealBid ? bids[i].deposit - expected.payments[i] : 0;
            totalRefunds += refund;
            totalFilled += expected.fills[i];
            _claim(id, i, expected.fills[i], refund);
        }
        if (!sellerFirst) _sellerClaim(id, expected.returned, expected.proceeds);
        require(expected.deposits == expected.proceeds + totalRefunds, "ETH conservation");
        require(supply == totalFilled + expected.returned, "token conservation");
        _emptyEscrow();
    }

    function testFuzzTieOrderDoesNotChangeProRataShares(uint96 seed, uint8 rotation) public {
        uint256 supply = 1 + uint256(seed) % 1000;
        uint256 id = _create(supply, 1, 0);
        uint256[3] memory amounts =
            [1 + uint256(seed) % supply, 1 + (uint256(seed) >> 32) % supply, 1 + (uint256(seed) >> 64) % supply];
        uint256 demand = amounts[0] + amounts[1] + amounts[2];
        uint256 price = UNIT / 3 + 1;
        for (uint256 n; n < 3; ++n) {
            uint256 i = (n + uint256(rotation)) % 3;
            _commit(id, i, price, amounts[i], _cost(amounts[i], price));
        }
        _openReveal(id);
        for (uint256 i; i < 3; ++i) {
            _reveal(id, i, price, amounts[i]);
        }
        _finalize(id);
        uint256 totalFilled;
        uint256 proceeds;
        for (uint256 i; i < 3; ++i) {
            uint256 filled = demand <= supply ? amounts[i] : supply * amounts[i] / demand;
            uint256 payment = _cost(filled, price);
            totalFilled += filled;
            proceeds += payment;
            _checkBid(id, i, filled, payment);
            _claim(id, i, filled, _cost(amounts[i], price) - payment);
        }
        _checkAuction(id, totalFilled == 0 ? 0 : price, proceeds, supply - totalFilled);
        _sellerClaim(id, supply - totalFilled, proceeds);
        _emptyEscrow();
    }
}
