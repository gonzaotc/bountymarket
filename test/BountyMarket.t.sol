// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {BountyMarket} from "../src/BountyMarket.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract BountyMarketTest is Test {
    BountyMarket market;
    MockUSDC usdc;

    address treasury = makeAddr("treasury");
    address company  = makeAddr("company");
    address reporter = makeAddr("reporter");
    address yesBuyer = makeAddr("yesBuyer");
    address noBuyer  = makeAddr("noBuyer");

    // Campaign params
    uint256 constant PRIZE_POOL       = 1_000e6;  // $1,000 USDC
    uint256 constant SUBMISSION_FEE   =    10e6;  // $10 USDC
    uint256 constant REWARD_PER_ISSUE =   500e6;  // $500 USDC
    uint256 constant PROTOCOL_FEE     =    10e6;  // 1% of prizePool

    uint256 constant YES_BET = 50e6;   // $50 USDC
    uint256 constant NO_BET  = 30e6;   // $30 USDC

    uint256 campaignId;
    uint256 issueId;

    function setUp() public {
        usdc = new MockUSDC();
        market = new BountyMarket(address(usdc), treasury);

        // Fund all actors
        usdc.mint(company,   PRIZE_POOL + PROTOCOL_FEE + 1e6);
        usdc.mint(reporter,  SUBMISSION_FEE);
        usdc.mint(yesBuyer,  YES_BET);
        usdc.mint(noBuyer,   NO_BET);
    }

    // -------------------------------------------------------------------------
    // Step 1: Company creates campaign
    // -------------------------------------------------------------------------

    function test_step1_createCampaign() public {
        _createCampaign();

        (address admin, uint256 pool, uint256 fee, uint256 reward, bool active) = market.campaigns(campaignId);

        console.log("=== Campaign Created ===");
        console.log("campaignId:      ", campaignId);
        console.log("admin:           ", admin);
        console.log("prizePool:       ", pool);
        console.log("submissionFee:   ", fee);
        console.log("rewardPerIssue:  ", reward);
        console.log("active:          ", active);
        console.log("treasury balance:", usdc.balanceOf(treasury));

        assertEq(admin, company);
        assertEq(pool, PRIZE_POOL);
        assertEq(fee, SUBMISSION_FEE);
        assertEq(reward, REWARD_PER_ISSUE);
        assertTrue(active);
        assertEq(usdc.balanceOf(treasury), PROTOCOL_FEE);
        assertEq(usdc.balanceOf(address(market)), PRIZE_POOL);
    }

    // -------------------------------------------------------------------------
    // Step 2: Reporter submits issue
    // -------------------------------------------------------------------------

    function test_step2_submitIssue() public {
        _createCampaign();
        _submitIssue();

        (uint256 cId, address rep, uint256 yesPool, uint256 noPool, bool resolved, bool valid) = market.issues(issueId);

        console.log("=== Issue Submitted ===");
        console.log("issueId:    ", issueId);
        console.log("campaignId: ", cId);
        console.log("reporter:   ", rep);
        console.log("yesPool:    ", yesPool);
        console.log("noPool:     ", noPool);
        console.log("resolved:   ", resolved);

        assertEq(rep, reporter);
        assertEq(yesPool, SUBMISSION_FEE); // reporter's fee is the initial YES pool
        assertEq(noPool, 0);
        assertFalse(resolved);
        assertEq(market.yesShares(issueId, reporter), SUBMISSION_FEE);
    }

    // -------------------------------------------------------------------------
    // Step 3: YES and NO buys, check market state
    // -------------------------------------------------------------------------

    function test_step3_marketTrading() public {
        _createCampaign();
        _submitIssue();
        _buyYes();
        _buyNo();

        (, , uint256 yesPool, uint256 noPool, , ) = market.issues(issueId);

        console.log("=== Market State After Trading ===");
        console.log("yesPool: ", yesPool);  // 10 + 50 = 60
        console.log("noPool:  ", noPool);   // 30
        console.log("yesShares[reporter]: ", market.yesShares(issueId, reporter));
        console.log("yesShares[yesBuyer]: ", market.yesShares(issueId, yesBuyer));
        console.log("noShares[noBuyer]:   ", market.noShares(issueId, noBuyer));

        assertEq(yesPool, SUBMISSION_FEE + YES_BET); // 60 USDC
        assertEq(noPool, NO_BET);                    // 30 USDC
        assertEq(market.yesShares(issueId, reporter), SUBMISSION_FEE);
        assertEq(market.yesShares(issueId, yesBuyer), YES_BET);
        assertEq(market.noShares(issueId, noBuyer), NO_BET);
    }

    // -------------------------------------------------------------------------
    // Step 4a: Company resolves VALID → reporter + YES buyers win
    // -------------------------------------------------------------------------

    function test_step4a_resolveValid_and_claim() public {
        _createCampaign();
        _submitIssue();
        _buyYes();
        _buyNo();

        // Resolve valid
        vm.prank(company);
        market.resolve(issueId, true);

        (, , uint256 yesPool, uint256 noPool, bool resolved, bool valid) = market.issues(issueId);
        console.log("=== Resolved VALID ===");
        console.log("resolved: ", resolved);
        console.log("valid:    ", valid);
        assertTrue(resolved);
        assertTrue(valid);

        // Prize pool decreased by R
        (, uint256 remainingPool, , , ) = market.campaigns(campaignId);
        assertEq(remainingPool, PRIZE_POOL - REWARD_PER_ISSUE);
        console.log("remaining prizePool: ", remainingPool); // 500

        // Preview payouts
        // R = 500, yesPool = 60, noPool = 30
        // yesPoolPrize = 10% of 500 + 30 = 50 + 30 = 80
        // reporter: shares=10, total yesPool=60 → marketPayout = 80*10/60 = 13.33
        //           + reporterBonus = 90% of 500 = 450
        //           total = ~463.33
        // yesBuyer: shares=50, total yesPool=60 → marketPayout = 80*50/60 = 66.66
        uint256 reporterPayout = market.previewClaim(issueId, reporter);
        uint256 yesBuyerPayout = market.previewClaim(issueId, yesBuyer);
        uint256 noBuyerPayout  = market.previewClaim(issueId, noBuyer);

        console.log("=== Payouts ===");
        console.log("reporter payout:  ", reporterPayout);
        console.log("yesBuyer payout:  ", yesBuyerPayout);
        console.log("noBuyer payout:   ", noBuyerPayout); // should be 0

        assertEq(noBuyerPayout, 0); // NO buyers lose on valid

        // Claim
        vm.prank(reporter);
        market.claim(issueId);

        vm.prank(yesBuyer);
        market.claim(issueId);

        console.log("=== Balances After Claim ===");
        console.log("reporter balance:  ", usdc.balanceOf(reporter));
        console.log("yesBuyer balance:  ", usdc.balanceOf(yesBuyer));
        console.log("noBuyer balance:   ", usdc.balanceOf(noBuyer));

        assertEq(usdc.balanceOf(reporter), reporterPayout);
        assertEq(usdc.balanceOf(yesBuyer), yesBuyerPayout);
        assertEq(usdc.balanceOf(noBuyer), 0); // lost their bet

        // Double claim fails
        vm.prank(reporter);
        vm.expectRevert("already claimed");
        market.claim(issueId);
    }

    // -------------------------------------------------------------------------
    // Step 4b: Company resolves INVALID → NO buyers win the YES pool
    // -------------------------------------------------------------------------

    function test_step4b_resolveInvalid_and_claim() public {
        _createCampaign();
        _submitIssue();
        _buyYes();
        _buyNo();

        vm.prank(company);
        market.resolve(issueId, false);

        (, , uint256 yesPool, , bool resolved, bool valid) = market.issues(issueId);
        console.log("=== Resolved INVALID ===");
        assertFalse(valid);

        // Prize pool unchanged
        (, uint256 remainingPool, , , ) = market.campaigns(campaignId);
        assertEq(remainingPool, PRIZE_POOL);
        console.log("remaining prizePool: ", remainingPool); // still 1000

        // NO buyers win the entire YES pool pro-rata
        // yesPool = 60, noPool = 30, noBuyer has all 30 noShares
        // noBuyer payout = 60 * 30 / 30 = 60
        uint256 noBuyerPayout   = market.previewClaim(issueId, noBuyer);
        uint256 reporterPayout  = market.previewClaim(issueId, reporter);
        uint256 yesBuyerPayout  = market.previewClaim(issueId, yesBuyer);

        console.log("=== Payouts ===");
        console.log("noBuyer payout:  ", noBuyerPayout);  // 60
        console.log("reporter payout: ", reporterPayout); // 0
        console.log("yesBuyer payout: ", yesBuyerPayout); // 0

        assertEq(noBuyerPayout, yesPool); // wins the whole YES pool
        assertEq(reporterPayout, 0);
        assertEq(yesBuyerPayout, 0);

        vm.prank(noBuyer);
        market.claim(issueId);

        console.log("noBuyer final balance: ", usdc.balanceOf(noBuyer));
        assertEq(usdc.balanceOf(noBuyer), yesPool); // $60 from $30 bet
    }

    // -------------------------------------------------------------------------
    // Edge cases
    // -------------------------------------------------------------------------

    function test_cannotResolveIfNotAdmin() public {
        _createCampaign();
        _submitIssue();

        vm.prank(reporter);
        vm.expectRevert("not admin");
        market.resolve(issueId, true);
    }

    function test_cannotResolveAlreadyResolved() public {
        _createCampaign();
        _submitIssue();

        vm.prank(company);
        market.resolve(issueId, true);

        vm.prank(company);
        vm.expectRevert("already resolved");
        market.resolve(issueId, true);
    }

    function test_cannotBuyOnResolvedIssue() public {
        _createCampaign();
        _submitIssue();

        vm.prank(company);
        market.resolve(issueId, false);

        usdc.mint(yesBuyer, YES_BET);
        vm.prank(yesBuyer);
        usdc.approve(address(market), YES_BET);

        vm.prank(yesBuyer);
        vm.expectRevert("resolved");
        market.buyYes(issueId, YES_BET, yesBuyer);
    }

    function test_poolExhaustsAfterManyValidIssues() public {
        // prize pool = 1000, reward = 500 → can pay 2 valid issues
        _createCampaign();

        for (uint i = 0; i < 2; i++) {
            usdc.mint(reporter, SUBMISSION_FEE);
            vm.startPrank(reporter);
            usdc.approve(address(market), SUBMISSION_FEE);
            uint256 id = market.submitIssue(campaignId, reporter);
            vm.stopPrank();

            vm.prank(company);
            market.resolve(id, true);
        }

        (, uint256 remainingPool, , , ) = market.campaigns(campaignId);
        assertEq(remainingPool, 0);

        // 3rd valid issue fails
        usdc.mint(reporter, SUBMISSION_FEE);
        vm.startPrank(reporter);
        usdc.approve(address(market), SUBMISSION_FEE);
        uint256 id3 = market.submitIssue(campaignId, reporter);
        vm.stopPrank();

        vm.prank(company);
        vm.expectRevert("pool exhausted");
        market.resolve(id3, true);
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _createCampaign() internal {
        uint256 total = PRIZE_POOL + PROTOCOL_FEE;
        vm.startPrank(company);
        usdc.approve(address(market), total);
        campaignId = market.createCampaign(PRIZE_POOL, SUBMISSION_FEE, REWARD_PER_ISSUE);
        vm.stopPrank();
    }

    function _submitIssue() internal {
        vm.startPrank(reporter);
        usdc.approve(address(market), SUBMISSION_FEE);
        issueId = market.submitIssue(campaignId, reporter);
        vm.stopPrank();
    }

    function _buyYes() internal {
        vm.startPrank(yesBuyer);
        usdc.approve(address(market), YES_BET);
        market.buyYes(issueId, YES_BET, yesBuyer);
        vm.stopPrank();
    }

    function _buyNo() internal {
        vm.startPrank(noBuyer);
        usdc.approve(address(market), NO_BET);
        market.buyNo(issueId, NO_BET, noBuyer);
        vm.stopPrank();
    }
}
