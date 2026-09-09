// SPDX-License-Identifier: MIT
pragma solidity 0.6.9;
pragma experimental ABIEncoderV2;

import {PMMPricing} from "../lib/PMMPricing.sol";

/// @title PMMHarness
/// @notice BASTION-OWNED wrapper. The files in ../lib are DODO's, untouched and pinned
///         (see UPSTREAM.md). PMMPricing is a library of `internal` functions, so it
///         compiles to no callable bytecode on its own. This contract is the smallest
///         thing that makes it reachable from outside: it does no math of its own, it
///         only flattens PMMState across the ABI and forwards.
///
///         Compiled at solc 0.6.9, separately from Bastion's 0.8.30 code, so that any
///         comparison is against an independently compiled reference rather than
///         against another copy of our own port.
contract PMMHarness {
    /// @dev R: 0 = ONE, 1 = ABOVE_ONE, 2 = BELOW_ONE — matches PMMPricing.RState
    function _state(uint256 i, uint256 K, uint256 B, uint256 Q, uint256 B0, uint256 Q0, uint8 R)
        private
        pure
        returns (PMMPricing.PMMState memory s)
    {
        s.i = i; s.K = K; s.B = B; s.Q = Q; s.B0 = B0; s.Q0 = Q0;
        s.R = PMMPricing.RState(R);
    }

    /// @notice Sell base into the pool (maker receives base, pays quote)
    function sellBase(
        uint256 i, uint256 K, uint256 B, uint256 Q, uint256 B0, uint256 Q0, uint8 R,
        uint256 payBaseAmount
    ) external pure returns (uint256 receiveQuoteAmount, uint8 newR) {
        PMMPricing.PMMState memory s = _state(i, K, B, Q, B0, Q0, R);
        (uint256 out, PMMPricing.RState r) = PMMPricing.sellBaseToken(s, payBaseAmount);
        return (out, uint8(r));
    }

    /// @notice Sell quote into the pool (maker receives quote, pays base)
    function sellQuote(
        uint256 i, uint256 K, uint256 B, uint256 Q, uint256 B0, uint256 Q0, uint8 R,
        uint256 payQuoteAmount
    ) external pure returns (uint256 receiveBaseAmount, uint8 newR) {
        PMMPricing.PMMState memory s = _state(i, K, B, Q, B0, Q0, R);
        (uint256 out, PMMPricing.RState r) = PMMPricing.sellQuoteToken(s, payQuoteAmount);
        return (out, uint8(r));
    }

    /// @notice Re-derive the targets after the maker moves the index price `i`.
    ///         This is the recentring step the comparison is really about.
    function adjustTarget(
        uint256 i, uint256 K, uint256 B, uint256 Q, uint256 B0, uint256 Q0, uint8 R
    ) external pure returns (uint256 newB0, uint256 newQ0) {
        PMMPricing.PMMState memory s = _state(i, K, B, Q, B0, Q0, R);
        PMMPricing.adjustedTarget(s);
        return (s.B0, s.Q0);
    }

    /// @notice Current mid price, quote per base, 1e18 fixed point
    function midPrice(
        uint256 i, uint256 K, uint256 B, uint256 Q, uint256 B0, uint256 Q0, uint8 R
    ) external pure returns (uint256) {
        return PMMPricing.getMidPrice(_state(i, K, B, Q, B0, Q0, R));
    }
}
