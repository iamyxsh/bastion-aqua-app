// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title Scale
/// @notice Decimal normalisation for the PMM anchor price, spec 5.2's `priceWad`.
///
/// @dev THE PROBLEM. `PMMMath` is decimal-blind: it multiplies raw token amounts by `i`
///      and divides by 1e18. For that to produce raw units of the other token, `i` must be
///
///          i = (quote RAW units per base RAW unit) * 1e18
///
///      A human price does not have that shape. "3,000 USDC per WETH" with USDC at 6 dp
///      and WETH at 18 dp is 3_000e6 raw quote per 1e18 raw base, so
///
///          i = 3_000e18 * 10**6 / 10**18 = 3_000e6 = 3e9
///
///      Check it: paying 1e18 raw base at k = 0 returns i * 1e18 / 1e18 = 3e9 raw quote,
///      which is 3,000.000000 USDC. A caller who signed 3_000e18 instead would quote a
///      price 1e12 times too high and every downstream check would look healthy.
///
///      WHERE THIS RUNS. Nowhere in the pricing path. Spec 5.2 defines the SIGNED anchor
///      as already-normalised `priceWad`, so the contract consumes `i` directly and never
///      sees a token decimal. These helpers exist so the party that BUILDS an anchor (a
///      maker, the keeper, a test) and the party that DISPLAYS one (the console) compute
///      the same number, and so that "pinned decimal normalisation" is one auditable
///      definition rather than a convention repeated in three places.
///
///      ROUNDING. Both directions round DOWN. When `baseDecimals > quoteDecimals` the
///      forward conversion divides and loses precision, so the round trip is lossy: a
///      6 dp quote leg keeps about 6 significant decimal places of the price. That is a
///      property of the units, not a bug, but it means `toHumanPriceWad(toAnchorWad(p))`
///      is `<= p`, never `>`. Callers that need an exact anchor must sign `i` itself.
library Scale {
    /// @notice A decimals value this library refuses to exponentiate.
    error DecimalsOutOfRange(uint8 decimals);
    /// @notice Normalisation floored the price to zero; the curve would divide by it.
    error PriceUnderflow();

    /// @dev 10**36 fits comfortably in uint256; anything past this is not a real token.
    uint8 internal constant MAX_DECIMALS = 36;

    uint256 internal constant ONE = 10 ** 18;

    /// @notice Human price -> the curve's `i` (spec 5.2 `priceWad`).
    /// @param humanPriceWad quote HUMAN units per base HUMAN unit, 1e18 fixed point
    /// @param baseDecimals  decimals of the base token
    /// @param quoteDecimals decimals of the quote token
    /// @return i quote RAW units per base RAW unit, 1e18 fixed point. Never zero.
    function toAnchorWad(
        uint256 humanPriceWad,
        uint8 baseDecimals,
        uint8 quoteDecimals
    ) internal pure returns (uint256 i) {
        if (baseDecimals > MAX_DECIMALS) revert DecimalsOutOfRange(baseDecimals);
        if (quoteDecimals > MAX_DECIMALS) revert DecimalsOutOfRange(quoteDecimals);

        if (quoteDecimals >= baseDecimals) {
            i = humanPriceWad * (10 ** (quoteDecimals - baseDecimals));
        } else {
            i = humanPriceWad / (10 ** (baseDecimals - quoteDecimals));
        }
        // `reciprocalFloor(0)` panics inside the curve, and a zero anchor is meaningless
        // anyway. Fail here, where the cause is visible.
        if (i == 0) revert PriceUnderflow();
    }

    /// @notice The curve's `i` -> a human price, for display only.
    /// @dev Lossy in the direction described in the header. Never feed the result back
    ///      into `toAnchorWad` and expect the original `i`.
    function toHumanPriceWad(
        uint256 i,
        uint8 baseDecimals,
        uint8 quoteDecimals
    ) internal pure returns (uint256 humanPriceWad) {
        if (baseDecimals > MAX_DECIMALS) revert DecimalsOutOfRange(baseDecimals);
        if (quoteDecimals > MAX_DECIMALS) revert DecimalsOutOfRange(quoteDecimals);

        if (quoteDecimals >= baseDecimals) {
            humanPriceWad = i / (10 ** (quoteDecimals - baseDecimals));
        } else {
            humanPriceWad = i * (10 ** (baseDecimals - quoteDecimals));
        }
    }
}
