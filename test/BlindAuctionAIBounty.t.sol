// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import "forge-std/Test.sol";
import "../src/BlindAuctionAIBounty.sol";

contract BlindAuctionAIBountyTest is Test {
    BlindAuctionAIBounty public bounty;
    address owner = address(0x1);
    address alice = address(0x2);
    address bob = address(0x3);
    uint256 challengeId;
    bytes32 aliceCommitment;
    bytes32 bobCommitment;
    bytes32 aliceSalt = keccak256("alice_salt");
    bytes32 bobSalt = keccak256("bob_salt");
    string aliceAnswer = "Alice's solution";
    string bobAnswer = "Bob's solution";
    uint256 reward = 1 ether;
    uint256 aliceBid = 0.1 ether;
    uint256 bobBid = 0.2 ether;

    function setUp() public {
        vm.deal(owner, 10 ether);
        vm.deal(alice, 1 ether);
        vm.deal(bob, 1 ether);
        bounty = new BlindAuctionAIBounty();
        vm.startPrank(owner);
        uint256 commitDeadline = block.timestamp + 1 days;
        bounty.createChallenge{value: reward}("Test", commitDeadline, 2 days);
        challengeId = 0;
        vm.stopPrank();
        aliceCommitment = keccak256(abi.encodePacked(aliceAnswer, aliceSalt, alice, challengeId));
        bobCommitment = keccak256(abi.encodePacked(bobAnswer, bobSalt, bob, challengeId));
    }

    function testFullFlow() public {
        // Commit with bids
        vm.startPrank(alice);
        bounty.submitCommitment{value: aliceBid}(challengeId, aliceCommitment);
        vm.stopPrank();

        vm.startPrank(bob);
        bounty.submitCommitment{value: bobBid}(challengeId, bobCommitment);
        vm.stopPrank();

        // Move to reveal phase
        vm.warp(block.timestamp + 1 days + 1);

        // Reveal
        vm.startPrank(alice);
        bounty.revealAnswer(challengeId, aliceAnswer, aliceSalt);
        vm.stopPrank();

        vm.startPrank(bob);
        bounty.revealAnswer(challengeId, bobAnswer, bobSalt);
        vm.stopPrank();

        // Move to after reveal phase
        vm.warp(block.timestamp + 2 days + 1);

        // Set AI scores
        address[] memory participants = new address[](2);
        participants[0] = alice;
        participants[1] = bob;
        uint256[] memory scores = new uint256[](2);
        scores[0] = 85;
        scores[1] = 90;

        vm.startPrank(owner);
        bounty.setAIScores(challengeId, participants, scores);
        bounty.finalizeWinner(challengeId);
        vm.stopPrank();

        BlindAuctionAIBounty.ChallengeInfo memory info = bounty.getChallengeInfo(challengeId);
        assertTrue(info.finalized);
        assertEq(info.winner, bob);

        // Bob: initial 1 ether + reward 1 ether - bid 0.2 ether (sent to owner) = 1.8 ether
        assertEq(bob.balance, 1 ether + reward - bobBid);
        // Alice: initial 1 ether - bid 0.1 ether + refund 0.1 ether = 1 ether
        assertEq(alice.balance, 1 ether);
    }

    function testCannotRevealBeforeDeadline() public {
        vm.startPrank(alice);
        bounty.submitCommitment{value: aliceBid}(challengeId, aliceCommitment);
        vm.expectRevert("Not reveal phase");
        bounty.revealAnswer(challengeId, aliceAnswer, aliceSalt);
        vm.stopPrank();
    }

    function testCannotCommitWithoutBid() public {
        vm.startPrank(alice);
        vm.expectRevert("Bid must be > 0 RIT");
        bounty.submitCommitment{value: 0}(challengeId, aliceCommitment);
        vm.stopPrank();
    }

    function testCannotFinalizeWithoutAI() public {
        vm.startPrank(alice);
        bounty.submitCommitment{value: aliceBid}(challengeId, aliceCommitment);
        vm.stopPrank();

        vm.warp(block.timestamp + 1 days + 1);
        vm.startPrank(alice);
        bounty.revealAnswer(challengeId, aliceAnswer, aliceSalt);
        vm.stopPrank();

        vm.warp(block.timestamp + 2 days + 1);
        vm.startPrank(owner);
        vm.expectRevert("AI must judge first");
        bounty.finalizeWinner(challengeId);
        vm.stopPrank();
    }

    function testBidRefundToLoser() public {
        vm.startPrank(alice);
        bounty.submitCommitment{value: aliceBid}(challengeId, aliceCommitment);
        vm.stopPrank();

        vm.startPrank(bob);
        bounty.submitCommitment{value: bobBid}(challengeId, bobCommitment);
        vm.stopPrank();

        vm.warp(block.timestamp + 1 days + 1);
        vm.startPrank(alice);
        bounty.revealAnswer(challengeId, aliceAnswer, aliceSalt);
        vm.stopPrank();

        vm.startPrank(bob);
        bounty.revealAnswer(challengeId, bobAnswer, bobSalt);
        vm.stopPrank();

        vm.warp(block.timestamp + 2 days + 1);

        address[] memory participants = new address[](2);
        participants[0] = alice;
        participants[1] = bob;
        uint256[] memory scores = new uint256[](2);
        scores[0] = 50;
        scores[1] = 90;

        vm.startPrank(owner);
        bounty.setAIScores(challengeId, participants, scores);
        bounty.finalizeWinner(challengeId);
        vm.stopPrank();

        // Alice (loser) should get her bid back
        assertEq(alice.balance, 1 ether);
        // Bob (winner): initial 1 + reward 1 - bid 0.2 = 1.8
        assertEq(bob.balance, 1 ether + reward - bobBid);
    }
}
