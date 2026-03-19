// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

/// @title BountyMarket
/// @notice Pay-to-submit bug bounty platform with prediction markets on issue validity.
///
/// Actors:
///   Company  — creates a campaign, locks a prize pool, resolves issues.
///   Reporter — pays submission fee F to open an issue (implicit YES position).
///   YES buyer — bets the issue is valid.
///   NO buyer  — bets the issue is invalid (e.g. duplicate-detection agents).
///
/// On VALID resolution:
///   Reporter  → 90% of reward R (from prize pool) + pro-rata share of YES pool's (10% R + NO pool)
///   YES pool  → 10% of R + NO pool, distributed pro-rata by yesShares
///   NO pool   → redistributed to YES pool
///   Prize pool→ decreases by R
///
/// On INVALID resolution:
///   NO pool   → wins YES pool (F + YES buyers), distributed pro-rata by noShares
///   Prize pool→ unchanged
///   Reporter  → loses F

contract BountyMarket is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    uint256 public constant BPS = 10_000;

    // -------------------------------------------------------------------------
    // Immutables
    // -------------------------------------------------------------------------

    uint256 public immutable PROTOCOL_FEE_BPS;  // e.g. 100 = 1%
    uint256 public immutable REPORTER_SHARE_BPS; // e.g. 9000 = 90% of R to reporter
    uint256 public immutable YES_POOL_SHARE_BPS; // e.g. 1000 = 10% of R to YES pool

    // -------------------------------------------------------------------------
    // Storage
    // -------------------------------------------------------------------------

    IERC20 public immutable usdc;
    address public immutable treasury;

    uint256 public nextCampaignId;
    uint256 public nextIssueId;

    struct Campaign {
        address admin;
        uint256 prizePool;     // remaining USDC available for rewards
        uint256 submissionFee; // F: fee required to open an issue
        uint256 rewardPerIssue; // R: fixed reward paid on valid issue
        bool active;
    }

    struct Issue {
        uint256 campaignId;
        address reporter;
        uint256 yesPool;  // F + Σ YES buys
        uint256 noPool;   // Σ NO buys
        bool resolved;
        bool valid;
    }

    mapping(uint256 => Campaign) public campaigns;
    mapping(uint256 => Issue) public issues;

    // yesShares[issueId][account] = amount deposited on YES side
    mapping(uint256 => mapping(address => uint256)) public yesShares;
    // noShares[issueId][account] = amount deposited on NO side
    mapping(uint256 => mapping(address => uint256)) public noShares;
    // claimed[issueId][account] = whether winnings have been pulled
    mapping(uint256 => mapping(address => bool)) public claimed;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event CampaignCreated(uint256 indexed id, address indexed admin, uint256 prizePool, uint256 submissionFee, uint256 rewardPerIssue);
    event IssueSubmitted(uint256 indexed issueId, uint256 indexed campaignId, address indexed reporter);
    event YesBought(uint256 indexed issueId, address indexed buyer, uint256 amount);
    event NoBought(uint256 indexed issueId, address indexed buyer, uint256 amount);
    event IssueResolved(uint256 indexed issueId, bool valid);
    event Claimed(uint256 indexed issueId, address indexed account, uint256 amount);

    // -------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------

    modifier onlyCampaignAdmin(uint256 campaignId) {
        require(msg.sender == campaigns[campaignId].admin, "not campaign admin");
        _;
    }

    modifier onlyIssueAdmin(uint256 issueId) {
        require(msg.sender == campaigns[issues[issueId].campaignId].admin, "not campaign admin");
        _;
    }

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    /// @notice Deploy BountyMarket with configurable fee and reward splits.
    /// @param _usdc             ERC20 token used for all payments (USDC).
    /// @param _treasury         Address that receives the protocol fee on campaign creation.
    /// @param _protocolFeeBps   Fee charged on prize pool at campaign creation, in BPS (e.g. 100 = 1%).
    /// @param _reporterShareBps Share of rewardPerIssue paid directly to the reporter on valid resolution, in BPS.
    /// @param _yesPoolShareBps  Share of rewardPerIssue distributed pro-rata to all YES holders on valid resolution, in BPS.
    ///                          Must satisfy: _reporterShareBps + _yesPoolShareBps == 10_000.
    constructor(
        address _usdc,
        address _treasury,
        uint256 _protocolFeeBps,
        uint256 _reporterShareBps,
        uint256 _yesPoolShareBps
    ) {
        require(_protocolFeeBps <= BPS, "fee too high");
        require(_reporterShareBps + _yesPoolShareBps == BPS, "shares must sum to 100%");
        usdc = IERC20(_usdc);
        treasury = _treasury;
        PROTOCOL_FEE_BPS = _protocolFeeBps;
        REPORTER_SHARE_BPS = _reporterShareBps;
        YES_POOL_SHARE_BPS = _yesPoolShareBps;
    }

    // -------------------------------------------------------------------------
    // Company actions
    // -------------------------------------------------------------------------

    /// @notice Create a bounty campaign and lock the prize pool.
    /// @dev    Caller pays prizePool + protocolFee upfront. The protocol fee is forwarded
    ///         to treasury immediately; the prize pool is held in the contract until issues
    ///         are resolved or the admin withdraws it. Caller becomes the campaign admin.
    /// @param prizePool      Total USDC locked for paying out valid issues.
    /// @param submissionFee  Fee (F) reporters must pay to submit an issue. Becomes their YES position.
    /// @param rewardPerIssue Fixed reward (R) deducted from the pool per valid resolution. Must be <= prizePool.
    /// @return id            The new campaign ID.
    function createCampaign(
        uint256 prizePool,
        uint256 submissionFee,
        uint256 rewardPerIssue
    ) external returns (uint256 id) {
        require(prizePool > 0, "empty pool");
        require(rewardPerIssue > 0 && rewardPerIssue <= prizePool, "bad reward");
        require(submissionFee > 0, "fee required");

        uint256 protocolFee = (prizePool * PROTOCOL_FEE_BPS) / BPS;
        uint256 total = prizePool + protocolFee;

        usdc.safeTransferFrom(msg.sender, address(this), total);
        usdc.safeTransfer(treasury, protocolFee);

        id = nextCampaignId++;
        campaigns[id] = Campaign({
            admin: msg.sender,
            prizePool: prizePool,
            submissionFee: submissionFee,
            rewardPerIssue: rewardPerIssue,
            active: true
        });

        emit CampaignCreated(id, msg.sender, prizePool, submissionFee, rewardPerIssue);
    }

    /// @notice Resolve an issue as valid or invalid. Only callable by the campaign admin.
    /// @dev    Valid: deducts rewardPerIssue from the prize pool; reporter and YES holders
    ///         can claim their share. Invalid: prize pool is untouched; NO holders claim
    ///         the entire YES pool. Cannot be called if the campaign has been deactivated.
    /// @param issueId  ID of the issue to resolve.
    /// @param valid    True if the issue is a confirmed valid bug report.
    function resolve(uint256 issueId, bool valid) external onlyIssueAdmin(issueId) {
        Issue storage issue = issues[issueId];
        Campaign storage campaign = campaigns[issue.campaignId];

        require(!issue.resolved, "already resolved");
        require(campaign.active, "campaign inactive");

        if (valid) {
            require(campaign.prizePool >= campaign.rewardPerIssue, "pool exhausted");
            campaign.prizePool -= campaign.rewardPerIssue;
        }

        issue.resolved = true;
        issue.valid = valid;

        emit IssueResolved(issueId, valid);
    }

    /// @notice Withdraw the remaining prize pool and close the campaign.
    /// @dev    Sets active=false so no new issues can be submitted. Issues already submitted
    ///         can still be resolved and claimed normally — only the pool funding them is gone,
    ///         so valid resolutions will revert with "pool exhausted" if the pool runs dry.
    ///         Use this to wind down a campaign or recover unused funds.
    /// @param campaignId  ID of the campaign to close.
    function withdrawPool(uint256 campaignId) external onlyCampaignAdmin(campaignId) nonReentrant {
        Campaign storage campaign = campaigns[campaignId];
        uint256 amount = campaign.prizePool;
        require(amount > 0, "nothing to withdraw");

        campaign.prizePool = 0;
        campaign.active = false;

        usdc.safeTransfer(msg.sender, amount);
    }

    // -------------------------------------------------------------------------
    // Reporter actions
    // -------------------------------------------------------------------------

    /// @notice Submit a bug report to a campaign. The submission fee becomes the reporter's YES position.
    /// @dev    msg.sender pays the fee (typically the MPP relayer). `beneficiary` is recorded as the
    ///         reporter on-chain and credited with the YES shares, enabling non-custodial claiming.
    /// @param campaignId   ID of the campaign to submit against.
    /// @param beneficiary  Address credited as reporter and YES position holder.
    /// @return issueId     The new issue ID.
    function submitIssue(uint256 campaignId, address beneficiary) external nonReentrant returns (uint256 issueId) {
        Campaign storage campaign = campaigns[campaignId];
        require(campaign.active, "campaign inactive");

        usdc.safeTransferFrom(msg.sender, address(this), campaign.submissionFee);

        issueId = nextIssueId++;
        issues[issueId] = Issue({
            campaignId: campaignId,
            reporter: beneficiary,
            yesPool: campaign.submissionFee,
            noPool: 0,
            resolved: false,
            valid: false
        });

        yesShares[issueId][beneficiary] = campaign.submissionFee;

        emit IssueSubmitted(issueId, campaignId, beneficiary);
    }

    // -------------------------------------------------------------------------
    // Market actions
    // -------------------------------------------------------------------------

    /// @notice Buy a YES position — bet that the issue is a valid bug report.
    /// @dev    msg.sender pays (typically the MPP relayer). `beneficiary` is credited with the
    ///         shares on-chain. On valid resolution, YES holders share (YES_POOL_SHARE_BPS% of R + noPool)
    ///         pro-rata by their share of yesPool.
    /// @param issueId      ID of the issue to bet on.
    /// @param amount       USDC amount to stake (raw units, 6 decimals).
    /// @param beneficiary  Address credited with the YES position.
    function buyYes(uint256 issueId, uint256 amount, address beneficiary) external nonReentrant {
        Issue storage issue = issues[issueId];
        require(!issue.resolved, "resolved");
        require(amount > 0, "zero amount");

        usdc.safeTransferFrom(msg.sender, address(this), amount);

        issue.yesPool += amount;
        yesShares[issueId][beneficiary] += amount;

        emit YesBought(issueId, beneficiary, amount);
    }

    /// @notice Buy a NO position — bet that the issue is invalid (spam, duplicate, out-of-scope).
    /// @dev    msg.sender pays (typically the MPP relayer). `beneficiary` is credited with the
    ///         shares on-chain. On invalid resolution, NO holders split the entire YES pool
    ///         pro-rata by their share of noPool.
    /// @param issueId      ID of the issue to bet against.
    /// @param amount       USDC amount to stake (raw units, 6 decimals).
    /// @param beneficiary  Address credited with the NO position.
    function buyNo(uint256 issueId, uint256 amount, address beneficiary) external nonReentrant {
        Issue storage issue = issues[issueId];
        require(!issue.resolved, "resolved");
        require(amount > 0, "zero amount");

        usdc.safeTransferFrom(msg.sender, address(this), amount);

        issue.noPool += amount;
        noShares[issueId][beneficiary] += amount;

        emit NoBought(issueId, beneficiary, amount);
    }

    // -------------------------------------------------------------------------
    // Claim
    // -------------------------------------------------------------------------

    /// @notice Claim winnings after an issue has been resolved.
    /// @dev    Computes msg.sender's payout based on their shares and the resolution outcome,
    ///         marks them as claimed, and transfers USDC. Reverts if nothing is owed.
    /// @param issueId  ID of the resolved issue to claim from.
    function claim(uint256 issueId) external nonReentrant {
        Issue storage issue = issues[issueId];
        require(issue.resolved, "not resolved");
        require(!claimed[issueId][msg.sender], "already claimed");

        claimed[issueId][msg.sender] = true;

        uint256 payout = _computePayout(issueId, msg.sender);
        require(payout > 0, "nothing to claim");

        usdc.safeTransfer(msg.sender, payout);

        emit Claimed(issueId, msg.sender, payout);
    }

    /// @notice Preview the claimable payout for an account without executing a claim.
    /// @dev    Returns 0 if the issue is unresolved, already claimed, or the account has no position.
    /// @param issueId  ID of the issue.
    /// @param account  Address to preview the payout for.
    /// @return         Claimable USDC amount (raw units, 6 decimals).
    function previewClaim(uint256 issueId, address account) external view returns (uint256) {
        if (!issues[issueId].resolved) return 0;
        if (claimed[issueId][account]) return 0;
        return _computePayout(issueId, account);
    }

    // -------------------------------------------------------------------------
    // Internal
    // -------------------------------------------------------------------------

    /// @dev Compute the payout for `account` on a resolved issue.
    ///      Valid:   YES holders share (YES_POOL_SHARE_BPS% of R + noPool) pro-rata; reporter also gets REPORTER_SHARE_BPS% of R.
    ///      Invalid: NO holders split the entire YES pool pro-rata.
    function _computePayout(uint256 issueId, address account) internal view returns (uint256) {
        Issue storage issue = issues[issueId];
        Campaign storage campaign = campaigns[issue.campaignId];
        uint256 R = campaign.rewardPerIssue;

        if (issue.valid) {
            // YES side wins.
            // Total distributed to YES pool = 10% of R + noPool.
            uint256 yesPoolPrize = (R * YES_POOL_SHARE_BPS) / BPS + issue.noPool;
            uint256 shares = yesShares[issueId][account];
            if (shares == 0) return 0;

            // Pro-rata share of yesPoolPrize.
            uint256 marketPayout = (yesPoolPrize * shares) / issue.yesPool;

            // Reporter additionally gets 90% of R directly from prize pool.
            uint256 reporterBonus = (account == issue.reporter)
                ? (R * REPORTER_SHARE_BPS) / BPS
                : 0;

            return marketPayout + reporterBonus;
        } else {
            // NO side wins the entire YES pool.
            uint256 shares = noShares[issueId][account];
            if (shares == 0) return 0;
            return (issue.yesPool * shares) / issue.noPool;
        }
    }
}
