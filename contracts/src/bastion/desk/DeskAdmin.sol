// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ECDSA } from "@1inch/solidity-utils/contracts/libraries/ECDSA.sol";

import { PMMMath } from "../pmm/PMMMath.sol";
import { PMMState } from "../pmm/PMMState.sol";
import { DeskStorage } from "./DeskStorage.sol";

/// @title DeskAdmin
/// @notice The bodies of Bastion's maker-administration calls, in a DEPLOYED library.
///
/// @dev WHY THIS FILE EXISTS — gate D1, measured at milestone 3 increment 1 exactly as the
///      plan required. With these three functions inlined into the router, the runtime was
///      26,842 bytes against EIP-170's 24,576: undeployable by 2,266 bytes. Attribution:
///
///          upstream AquaSwapVMRouter                 20,376
///          + Bastion instructions and the PMM math   23,526   (+3,150)
///          + maker administration inlined            26,842   (+3,316)  OVER
///
///      Ladder decision D2 named this outcome in advance and its fallback: "move admin into
///      a separate contract only if size binds". It binds.
///
///      An `external` library function is DELEGATECALLED, so it executes in the router's own
///      storage context and `DeskStorage.layout()` still resolves to the router's slot. The
///      state therefore stays exactly where D2 put it; only the code moves. The cost is one
///      delegatecall per administrative call — none of which is on the swap path.
///
///      This library must be deployed and linked before the router. See scripts/.
library DeskAdmin {
    using ECDSA for address;

    error RiskGroupUnknown(bytes32 groupKey);
    error RiskGroupExists(bytes32 groupKey);
    error InvalidPair(address baseToken, address quoteToken);
    error InvalidAnchorSigner();
    error BookAlreadyAdmitted(bytes32 orderHash);
    error AnchorBadSigner(address expected);
    error AnchorNonceNotMonotone(uint256 given, uint256 stored);
    error AnchorIssuedInFuture(uint64 issuedAt, uint256 nowTs);
    error AnchorAlreadyExpired(uint64 expiry, uint256 nowTs);
    error AnchorWrongPolicyVersion(uint32 given, uint32 expected);

    event RiskGroupInitialized(
        address indexed maker,
        bytes32 indexed riskGroupId,
        address baseToken,
        address quoteToken,
        uint256 k,
        address anchorSigner
    );
    event BookAdmitted(address indexed maker, bytes32 indexed riskGroupId, bytes32 indexed orderHash);
    event AnchorPosted(
        address indexed maker,
        bytes32 indexed riskGroupId,
        uint256 priceWad,
        uint256 nonce,
        uint64 issuedAt,
        uint64 expiry,
        address publisher
    );

    /// @notice A signed price update. Chain and router are bound by the domain separator.
    /// @dev Spec 5.2. `priceWad` is quote RAW units per base RAW unit after the pinned
    ///      decimal normalisation of `Scale.sol` — NOT a human price.
    struct Anchor {
        address maker;
        bytes32 riskGroupId;
        uint32 policyVersion;
        uint256 priceWad;
        uint64 issuedAt;
        uint64 expiry;
        uint64 confidenceBps;
        uint256 nonce;
    }

    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    bytes32 internal constant ANCHOR_TYPEHASH = keccak256(
        "Anchor("
            "address maker,"
            "bytes32 riskGroupId,"
            "uint32 policyVersion,"
            "uint256 priceWad,"
            "uint64 issuedAt,"
            "uint64 expiry,"
            "uint64 confidenceBps,"
            "uint256 nonce"
        ")"
    );

    /// @dev A domain of Bastion's own, separate from SwapVM's order domain on purpose: an
    ///      anchor signature must never be replayable as an order signature, or the reverse.
    ///      `address(this)` is the ROUTER here, because this runs under delegatecall.
    function domainSeparator() public view returns (bytes32) {
        return keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH, keccak256("BastionAnchor"), keccak256("1"), block.chainid, address(this)
            )
        );
    }

    function hashAnchor(Anchor memory a) public view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                ANCHOR_TYPEHASH,
                a.maker,
                a.riskGroupId,
                a.policyVersion,
                a.priceWad,
                a.issuedAt,
                a.expiry,
                a.confidenceBps,
                a.nonce
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator(), structHash));
    }

    /// @notice Open a risk group with an explicit ledger. One group, many sibling books.
    /// @dev `initialPriceWad` is the maker's declared starting price; every LATER move needs
    ///      a signed anchor. `PMMState.init` enforces the canonical opening state and the
    ///      curvature restriction from milestone 2 increment 2's FINDING 1.
    function initRiskGroup(
        address maker,
        bytes32 riskGroupId,
        address baseToken,
        address quoteToken,
        uint256 k,
        address anchorSigner,
        uint256 initialPriceWad,
        uint256 baseLedger,
        uint256 quoteLedger
    ) external returns (bytes32 groupKey) {
        require(
            baseToken != address(0) && quoteToken != address(0) && baseToken != quoteToken,
            InvalidPair(baseToken, quoteToken)
        );
        require(anchorSigner != address(0), InvalidAnchorSigner());

        groupKey = DeskStorage.key(maker, riskGroupId);
        DeskStorage.RiskGroup storage g = DeskStorage.layout().groups[groupKey];
        require(g.maker == address(0), RiskGroupExists(groupKey));

        PMMMath.PMMState memory s = PMMState.init(initialPriceWad, k, baseLedger, quoteLedger);

        g.maker = maker;
        g.baseToken = baseToken;
        g.quoteToken = quoteToken;
        g.anchorSigner = anchorSigner;
        g.policyVersion = 1;
        g.K = s.K;
        DeskStorage.storePmm(g, s);

        emit RiskGroupInitialized(maker, riskGroupId, baseToken, quoteToken, k, anchorSigner);
    }

    /// @notice Admit one book (by its SwapVM order hash) onto a risk group.
    /// @dev Admission is what makes a program Bastion's. A program that was never admitted
    ///      reverts inside PortfolioLedger before any pricing runs, so copying a Bastion
    ///      program and re-salting it produces a book that cannot quote.
    function admitBook(address maker, bytes32 riskGroupId, bytes32 orderHash) external {
        bytes32 groupKey = DeskStorage.key(maker, riskGroupId);
        DeskStorage.Layout storage $ = DeskStorage.layout();
        DeskStorage.RiskGroup storage g = $.groups[groupKey];
        // No separate "is the caller the maker" check is possible or needed: `groupKey` is
        // derived FROM the caller, so a non-maker can only ever address a group of their own
        // that does not exist, and gets RiskGroupUnknown. Authorisation is structural.
        require(g.maker != address(0), RiskGroupUnknown(groupKey));
        require($.bookOf[orderHash] == bytes32(0), BookAlreadyAdmitted(orderHash));

        $.bookOf[orderHash] = groupKey;
        emit BookAdmitted(maker, riskGroupId, orderHash);
    }

    /// @notice Publish a signed price update. Permissionless: the signature carries the
    ///         authorisation, so a keeper, a relayer or the maker may all submit it.
    /// @dev Accepting an update is the EXPLICIT recentring transition of spec 5.1. It applies
    ///      once, to the current shared state. Quoting at an unchanged anchor moves nothing,
    ///      because nothing but this function ever writes `i`.
    /// @dev NOT CHECKED HERE, and each is scheduled: maximum age at fill, maximum deviation
    ///      from the previously accepted anchor, the confidence bound (carried and stored but
    ///      not enforced), signer rotation and explicit pause. All milestone 5.
    function postAnchor(Anchor calldata a, bytes calldata signature, address publisher) external {
        bytes32 groupKey = DeskStorage.key(a.maker, a.riskGroupId);
        DeskStorage.RiskGroup storage g = DeskStorage.layout().groups[groupKey];
        require(g.maker != address(0), RiskGroupUnknown(groupKey));

        address signer = g.anchorSigner;
        require(signer.recoverOrIsValidSignature(hashAnchor(a), signature), AnchorBadSigner(signer));

        require(a.policyVersion == g.policyVersion, AnchorWrongPolicyVersion(a.policyVersion, g.policyVersion));
        require(a.nonce > g.anchorNonce, AnchorNonceNotMonotone(a.nonce, g.anchorNonce));
        require(a.issuedAt <= block.timestamp, AnchorIssuedInFuture(a.issuedAt, block.timestamp));
        require(a.expiry > block.timestamp, AnchorAlreadyExpired(a.expiry, block.timestamp));

        PMMMath.PMMState memory s = DeskStorage.loadPmm(g);
        PMMState.recentre(s, a.priceWad);
        DeskStorage.storePmm(g, s);

        g.anchorNonce = a.nonce;
        g.anchorIssuedAt = a.issuedAt;
        g.anchorExpiry = a.expiry;
        g.anchorConfidenceBps = a.confidenceBps;

        emit AnchorPosted(a.maker, a.riskGroupId, a.priceWad, a.nonce, a.issuedAt, a.expiry, publisher);
    }
}
