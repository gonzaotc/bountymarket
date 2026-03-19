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

    uint256 public constant PROTOCOL_FEE_BPS = 100; // 1%
    uint256 public constant REPORTER_SHARE_BPS = 9000; // 90% of R to reporter
    uint256 public constant YES_POOL_SHARE_BPS = 1000; // 10% of R to YES pool
    uint256 public constant BPS = 10_000;

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
    // Constructor
    // -------------------------------------------------------------------------

    constructor(address _usdc, address _treasury) {
        usdc = IERC20(_usdc);
        treasury = _treasury;
    }

    // -------------------------------------------------------------------------
    // Company actions
    // -------------------------------------------------------------------------

    /// @notice Create a campaign by locking a prize pool.
    /// @param prizePool  Total USDC locked for paying out valid issues.
    /// @param submissionFee  Fee (F) reporters must pay to submit an issue.
    /// @param rewardPerIssue Fixed reward (R) paid from pool per valid issue. Must be <= prizePool.
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

    /// @notice Resolve an issue. Only callable by the campaign admin.
    /// @param issueId  Issue to resolve.
    /// @param valid    True if the issue is a valid bug report.
    function resolve(uint256 issueId, bool valid) external {
        Issue storage issue = issues[issueId];
        Campaign storage campaign = campaigns[issue.campaignId];

        require(msg.sender == campaign.admin, "not admin");
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

    // -------------------------------------------------------------------------
    // Reporter actions
    // -------------------------------------------------------------------------

    /// @notice Submit an issue. Pays fee F, which becomes reporter's YES position.
    /// @param beneficiary  Address credited with the reporter position (e.g. the actual user when called via relayer).
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

    /// @notice Buy YES (bet the issue is valid).
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

    /// @notice Buy NO (bet the issue is invalid).
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

    /// @notice Pull winnings after resolution.
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

    /// @notice Preview payout for an account (view, no state change).
    function previewClaim(uint256 issueId, address account) external view returns (uint256) {
        if (!issues[issueId].resolved) return 0;
        if (claimed[issueId][account]) return 0;
        return _computePayout(issueId, account);
    }

    // -------------------------------------------------------------------------
    // Internal
    // -------------------------------------------------------------------------

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
