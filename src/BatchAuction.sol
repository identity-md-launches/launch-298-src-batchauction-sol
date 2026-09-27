// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Sealed bids for an ERC-20 lot, settled in ETH at one uniform price.
/// @dev Amounts are token base units; prices are wei per 1e18 base units.
/// Deposits are public bid caps, so privacy depends on over-depositing. The
/// 64-address limit can be occupied by one actor: minDeposit sets its capital
/// requirement, and unrevealed deposits are forfeited. Revealed invalid bids
/// are refundable, so minDeposit is not a Sybil-prevention mechanism.
contract BatchAuction {
    uint256 public constant MAX_BIDS = 64;
    uint256 private constant UNIT = 1e18;

    struct Auction {
        address seller;
        address token;
        uint256 supply;
        uint256 reservePrice;
        uint256 minDeposit;
        uint64 commitEnd;
        uint64 revealEnd;
        bool finalized;
        bool sellerClaimed;
        uint256 commitmentCount;
        uint256 clearingPrice;
        uint256 sellerProceeds;
        uint256 returnedTokens;
    }

    struct Bid {
        bytes32 commitment;
        uint256 deposit;
        uint256 price;
        uint256 amount;
        uint256 filled;
        uint256 payment;
        bool committed;
        bool revealed;
        bool valid;
        bool claimed;
    }

    error InvalidAuction();
    error InvalidParameters();
    error WrongPhase();
    error AuctionFull();
    error AlreadyCommitted();
    error InsufficientDeposit();
    error NoCommitment();
    error AlreadyRevealed();
    error CommitmentMismatch();
    error AlreadyFinalized();
    error NotFinalized();
    error AlreadyClaimed();
    error NotSeller();
    error TransferFailed();
    error IncorrectTokenAmount();
    error ReentrantCall();

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

    /// @notice Auction IDs start at zero and increase by one.
    uint256 public nextAuctionId;
    mapping(uint256 => Auction) private _auctions;
    mapping(uint256 => mapping(address => Bid)) private _bids;
    mapping(uint256 => address[]) private _bidders;
    uint256 private _entered;

    modifier nonReentrant() {
        if (_entered != 0) revert ReentrantCall();
        _entered = 1;
        _;
        _entered = 0;
    }

    function createAuction(
        address token,
        uint256 supply,
        uint256 reservePrice,
        uint256 minDeposit,
        uint64 commitEnd,
        uint64 revealEnd
    ) external nonReentrant returns (uint256 id) {
        if (supply == 0 || reservePrice == 0 || block.timestamp >= commitEnd || commitEnd >= revealEnd) {
            revert InvalidParameters();
        }
        uint256 beforeBalance = _balanceOf(token);
        _callToken(token, abi.encodeWithSelector(bytes4(0x23b872dd), msg.sender, address(this), supply));
        uint256 afterBalance = _balanceOf(token);
        if (afterBalance < beforeBalance || afterBalance - beforeBalance != supply) revert IncorrectTokenAmount();

        id = nextAuctionId++;
        Auction storage a = _auctions[id];
        a.seller = msg.sender;
        a.token = token;
        a.supply = supply;
        a.reservePrice = reservePrice;
        a.minDeposit = minDeposit;
        a.commitEnd = commitEnd;
        a.revealEnd = revealEnd;
        emit AuctionCreated(id, msg.sender, token, supply, reservePrice, minDeposit, commitEnd, revealEnd);
    }

    function commit(uint256 id, bytes32 commitment) external payable nonReentrant {
        Auction storage a = _auction(id);
        if (block.timestamp >= a.commitEnd) revert WrongPhase();
        Bid storage b = _bids[id][msg.sender];
        if (b.committed) revert AlreadyCommitted();
        if (a.commitmentCount == MAX_BIDS) revert AuctionFull();
        if (msg.value < a.minDeposit) revert InsufficientDeposit();
        b.committed = true; // A zero hash or zero deposit still occupies one slot.
        b.commitment = commitment;
        b.deposit = msg.value;
        _bidders[id].push(msg.sender);
        ++a.commitmentCount;
        emit Committed(id, msg.sender, commitment, msg.value);
    }

    function reveal(uint256 id, uint256 price, uint256 amount, bytes32 salt) external nonReentrant {
        Auction storage a = _auction(id);
        if (block.timestamp < a.commitEnd || block.timestamp > a.revealEnd) revert WrongPhase();
        Bid storage b = _bids[id][msg.sender];
        if (!b.committed) revert NoCommitment();
        if (b.revealed) revert AlreadyRevealed();
        if (b.commitment != keccak256(abi.encode(id, msg.sender, price, amount, salt))) revert CommitmentMismatch();
        b.revealed = true;
        b.price = price;
        b.amount = amount;
        if (price >= a.reservePrice && amount != 0 && amount <= a.supply) {
            (bool fits, uint256 cost) = _cost(amount, price);
            b.valid = fits && b.deposit >= cost;
        }
        emit Revealed(id, msg.sender, price, amount, b.valid);
    }

    function finalize(uint256 id) external nonReentrant {
        Auction storage a = _auction(id);
        if (a.finalized) revert AlreadyFinalized();
        if (block.timestamp <= a.revealEnd) revert WrongPhase();
        a.finalized = true;
        address[] memory sorted = new address[](_bidders[id].length);
        uint256 count;
        for (uint256 i; i < sorted.length; ++i) {
            address bidder = _bidders[id][i];
            Bid storage b = _bids[id][bidder];
            if (!b.revealed) a.sellerProceeds += b.deposit;
            if (!b.valid) continue;
            // Stable insertion sort; at most 64 bids and no external calls.
            uint256 j = count;
            while (j != 0 && _bids[id][sorted[j - 1]].price < b.price) {
                sorted[j] = sorted[j - 1];
                --j;
            }
            sorted[j] = bidder;
            ++count;
        }

        uint256 remaining = a.supply;
        uint256 start;
        while (start < count && remaining != 0) {
            uint256 end = start;
            uint256 price = _bids[id][sorted[start]].price;
            // A two-word sum accommodates 64 amounts even when supply is uint256.max.
            uint256 demand;
            uint256 demandHigh;
            while (end < count && _bids[id][sorted[end]].price == price) {
                uint256 amount = _bids[id][sorted[end]].amount;
                unchecked {
                    uint256 sum = demand + amount;
                    if (sum < demand) ++demandHigh;
                    demand = sum;
                }
                ++end;
            }
            bool oversubscribed = demandHigh != 0 || demand > remaining;
            uint256 allocated;
            for (uint256 i = start; i < end; ++i) {
                Bid storage b = _bids[id][sorted[i]];
                b.filled = oversubscribed ? _share(remaining, b.amount, demandHigh, demand) : b.amount;
                allocated += b.filled;
            }
            remaining -= allocated;
            // If all marginal shares round to zero, only earlier winners set
            // the price. With no actual winner the clearing price stays zero.
            if (allocated != 0) a.clearingPrice = price;
            if (oversubscribed) break; // Floor dust belongs to the seller, never lower bids.
            start = end;
        }
        a.returnedTokens = remaining;
        for (uint256 i; i < count; ++i) {
            Bid storage b = _bids[id][sorted[i]];
            if (b.filled == 0) continue;
            (bool fits, uint256 payment) = _cost(b.filled, a.clearingPrice);
            // filled <= amount and clearingPrice <= bid price preserve solvency.
            assert(fits && payment <= b.deposit);
            b.payment = payment;
            a.sellerProceeds += payment;
        }
        emit Finalized(id, a.clearingPrice, a.sellerProceeds, remaining);
    }

    function claim(uint256 id) external nonReentrant {
        Auction storage a = _auction(id);
        if (!a.finalized) revert NotFinalized();
        Bid storage b = _bids[id][msg.sender];
        if (!b.committed) revert NoCommitment();
        if (b.claimed) revert AlreadyClaimed();
        b.claimed = true;
        uint256 refund = b.revealed ? b.deposit - b.payment : 0;
        emit Claimed(id, msg.sender, b.filled, refund);
        _pay(a.token, msg.sender, b.filled, refund);
    }

    function sellerClaim(uint256 id) external nonReentrant {
        Auction storage a = _auction(id);
        if (!a.finalized) revert NotFinalized();
        if (msg.sender != a.seller) revert NotSeller();
        if (a.sellerClaimed) revert AlreadyClaimed();
        a.sellerClaimed = true;
        emit SellerClaimed(id, msg.sender, a.returnedTokens, a.sellerProceeds);
        _pay(a.token, msg.sender, a.returnedTokens, a.sellerProceeds);
    }

    function auction(uint256 id) external view returns (Auction memory) {
        return _auction(id);
    }

    function bidOf(uint256 id, address bidder) external view returns (Bid memory) {
        _auction(id);
        return _bids[id][bidder];
    }

    function clearingPrice(uint256 id) external view returns (uint256) {
        return _auction(id).clearingPrice;
    }

    function _auction(uint256 id) private view returns (Auction storage a) {
        a = _auctions[id];
        if (a.seller == address(0)) revert InvalidAuction();
    }

    function _balanceOf(address token) private view returns (uint256) {
        (bool ok, bytes memory data) = token.staticcall(abi.encodeWithSelector(bytes4(0x70a08231), address(this)));
        if (!ok || data.length < 32) revert TransferFailed();
        return abi.decode(data, (uint256));
    }

    function _callToken(address token, bytes memory callData) private {
        (bool ok, bytes memory data) = token.call(callData);
        if (!ok || token.code.length == 0 || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    function _pay(address token, address recipient, uint256 tokens, uint256 eth) private {
        if (tokens != 0) _callToken(token, abi.encodeWithSelector(bytes4(0xa9059cbb), recipient, tokens));
        if (eth != 0) {
            (bool ok,) = payable(recipient).call{value: eth}("");
            if (!ok) revert TransferFailed();
        }
    }

    function _product(uint256 x, uint256 y) private pure returns (uint256 high, uint256 low) {
        assembly {
            let mm := mulmod(x, y, not(0))
            low := mul(x, y)
            high := sub(sub(mm, low), lt(mm, low))
        }
    }

    /// @dev An overflowing cost is an invalid bid, not a reverting reveal.
    function _cost(uint256 amount, uint256 price) private pure returns (bool fits, uint256 cost) {
        (uint256 high,) = _product(amount, price);
        if (high >= UNIT) return (false, 0);
        cost = _mulDiv(amount, price, UNIT);
        if (mulmod(amount, price, UNIT) != 0) {
            if (cost == type(uint256).max) return (false, 0);
            ++cost;
        }
        return (true, cost);
    }

    /// @dev Full-precision floor(x*y/d). Callers ensure d > high(x*y).
    function _mulDiv(uint256 x, uint256 y, uint256 d) private pure returns (uint256 result) {
        (uint256 high, uint256 low) = _product(x, y);
        if (high == 0) return low / d;
        assert(d > high);
        unchecked {
            uint256 remainder = mulmod(x, y, d);
            if (remainder > low) --high;
            low -= remainder;
            // Make the division exact, factor out powers of two, then invert
            // the odd denominator modulo 2^256 using Newton iteration.
            uint256 twos = d & (0 - d);
            d /= twos;
            low /= twos;
            low |= high * ((0 - twos) / twos + 1);
            uint256 inverse = (3 * d) ^ 2;
            inverse *= 2 - d * inverse;
            inverse *= 2 - d * inverse;
            inverse *= 2 - d * inverse;
            inverse *= 2 - d * inverse;
            inverse *= 2 - d * inverse;
            inverse *= 2 - d * inverse;
            result = low * inverse;
        }
    }

    function _share(uint256 remaining, uint256 amount, uint256 demandHigh, uint256 demand)
        private
        pure
        returns (uint256 result)
    {
        if (demandHigh == 0) return _mulDiv(remaining, amount, demand);
        (uint256 high, uint256 low) = _product(remaining, amount);
        // Rare case: demand exceeds uint256. Binary long division of two
        // 512-bit integers; the quotient fits in 256 bits because amount <= demand.
        for (uint256 bit = 256; bit != 0;) {
            unchecked {
                --bit;
            }
            if (bit != 0 && demandHigh >> (256 - bit) != 0) continue;
            uint256 shiftedHigh = demandHigh << bit;
            if (bit != 0) shiftedHigh |= demand >> (256 - bit);
            uint256 shiftedLow = demand << bit;
            if (high > shiftedHigh || (high == shiftedHigh && low >= shiftedLow)) {
                unchecked {
                    high = high - shiftedHigh - (low < shiftedLow ? 1 : 0);
                    low -= shiftedLow;
                }
                result |= uint256(1) << bit;
            }
        }
    }
}
