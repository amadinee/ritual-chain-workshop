// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract BlindAuctionAIBounty {
    struct Challenge {
        address owner;
        string prompt;
        uint256 reward;
        uint256 commitDeadline;
        uint256 revealDeadline;
        bool finalized;
        address winner;
        string[] answers;
        address[] participants;
        mapping(address => bytes32) commitments;
        mapping(address => bool) hasRevealed;
        mapping(address => uint256) answerIndex;
        mapping(address => uint256) bids;
        mapping(address => bool) bidRefunded;
        mapping(address => uint256) aiScores;
        uint256 totalBids;
        bool judged;
    }

    struct ChallengeInfo {
        address owner;
        string prompt;
        uint256 reward;
        uint256 commitDeadline;
        uint256 revealDeadline;
        bool finalized;
        address winner;
        uint256 participantCount;
        uint256 answerCount;
        uint256 totalBids;
        bool judged;
    }

    uint256 public challengeCounter;
    mapping(uint256 => Challenge) public challenges;

    event ChallengeCreated(uint256 indexed id, address indexed owner, uint256 reward);
    event CommitmentSubmitted(uint256 indexed id, address indexed participant, uint256 bid);
    event AnswerRevealed(uint256 indexed id, address indexed participant, string answer, uint256 bid);
    event WinnerFinalized(uint256 indexed id, address indexed winner, uint256 winningBid);
    event BidRefunded(uint256 indexed id, address indexed participant, uint256 amount);

    modifier challengeExists(uint256 id) {
        require(challenges[id].owner != address(0), "Challenge does not exist");
        _;
    }

    modifier onlyCommitPhase(uint256 id) {
        require(block.timestamp <= challenges[id].commitDeadline, "Commit phase ended");
        _;
    }

    modifier onlyRevealPhase(uint256 id) {
        require(block.timestamp > challenges[id].commitDeadline, "Not reveal phase");
        require(block.timestamp <= challenges[id].revealDeadline, "Reveal phase ended");
        _;
    }

    modifier onlyAfterReveal(uint256 id) {
        require(block.timestamp > challenges[id].revealDeadline, "Reveal phase not over");
        _;
    }

    modifier onlyOwner(uint256 id) {
        require(msg.sender == challenges[id].owner, "Not challenge owner");
        _;
    }

    modifier notFinalized(uint256 id) {
        require(!challenges[id].finalized, "Already finalized");
        _;
    }

    function createChallenge(
        string calldata prompt,
        uint256 commitDeadline,
        uint256 revealDuration
    ) external payable {
        require(msg.value > 0, "Reward must be > 0 RIT");
        require(commitDeadline > block.timestamp, "Deadline must be in future");
        require(revealDuration > 0, "Reveal duration must be > 0");

        uint256 id = challengeCounter++;
        Challenge storage c = challenges[id];
        c.owner = msg.sender;
        c.prompt = prompt;
        c.reward = msg.value;
        c.commitDeadline = commitDeadline;
        c.revealDeadline = commitDeadline + revealDuration;

        emit ChallengeCreated(id, msg.sender, msg.value);
    }

    function submitCommitment(
        uint256 id,
        bytes32 commitment
    ) external payable 
        challengeExists(id)
        onlyCommitPhase(id)
    {
        Challenge storage c = challenges[id];
        require(c.commitments[msg.sender] == 0, "Already committed");
        require(msg.value > 0, "Bid must be > 0 RIT");

        c.commitments[msg.sender] = commitment;
        c.bids[msg.sender] = msg.value;
        c.participants.push(msg.sender);
        c.totalBids += msg.value;

        emit CommitmentSubmitted(id, msg.sender, msg.value);
    }

    function revealAnswer(
        uint256 id,
        string calldata answer,
        bytes32 salt
    ) external 
        challengeExists(id)
        onlyRevealPhase(id)
    {
        Challenge storage c = challenges[id];
        bytes32 commitment = c.commitments[msg.sender];
        require(commitment != 0, "No commitment found");
        require(!c.hasRevealed[msg.sender], "Already revealed");

        bytes32 computed = keccak256(abi.encodePacked(answer, salt, msg.sender, id));
        require(computed == commitment, "Commitment mismatch");

        c.hasRevealed[msg.sender] = true;
        c.answerIndex[msg.sender] = c.answers.length;
        c.answers.push(answer);

        emit AnswerRevealed(id, msg.sender, answer, c.bids[msg.sender]);
    }

    function setAIScores(
        uint256 id,
        address[] calldata participants,
        uint256[] calldata scores
    ) external 
        challengeExists(id)
        onlyOwner(id)
        onlyAfterReveal(id)
        notFinalized(id)
    {
        Challenge storage c = challenges[id];
        require(!c.judged, "Already judged");
        require(participants.length == scores.length, "Length mismatch");

        for (uint i = 0; i < participants.length; i++) {
            require(c.hasRevealed[participants[i]], "Participant not revealed");
            c.aiScores[participants[i]] = scores[i];
        }

        c.judged = true;
    }

    function finalizeWinner(uint256 id) external 
        challengeExists(id)
        onlyOwner(id)
        onlyAfterReveal(id)
        notFinalized(id)
    {
        Challenge storage c = challenges[id];
        require(c.judged, "AI must judge first");
        require(c.answers.length > 0, "No revealed answers");

        address winner = c.participants[0];
        uint256 maxScore = 0;

        for (uint i = 0; i < c.participants.length; i++) {
            address participant = c.participants[i];
            if (!c.hasRevealed[participant]) continue;
            
            uint256 combinedScore = c.aiScores[participant] + c.bids[participant] / 1e16;
            if (combinedScore > maxScore) {
                maxScore = combinedScore;
                winner = participant;
            }
        }

        c.finalized = true;
        c.winner = winner;

        // Refund bids to all losers
        for (uint i = 0; i < c.participants.length; i++) {
            address participant = c.participants[i];
            if (participant != winner && c.hasRevealed[participant]) {
                uint256 bid = c.bids[participant];
                if (bid > 0 && !c.bidRefunded[participant]) {
                    c.bidRefunded[participant] = true;
                    (bool success, ) = payable(participant).call{value: bid}("");
                    require(success, "Refund failed");
                    emit BidRefunded(id, participant, bid);
                }
            }
        }

        // Send reward to winner
        (bool rewardSuccess, ) = payable(winner).call{value: c.reward}("");
        require(rewardSuccess, "Reward transfer failed");

        // Winner's bid is sent to owner
        uint256 winningBid = c.bids[winner];
        if (winningBid > 0) {
            (bool bidSuccess, ) = payable(c.owner).call{value: winningBid}("");
            require(bidSuccess, "Bid transfer failed");
        }

        emit WinnerFinalized(id, winner, winningBid);
    }

    function getChallengeInfo(uint256 id) external view returns (ChallengeInfo memory) {
        Challenge storage c = challenges[id];
        return ChallengeInfo({
            owner: c.owner,
            prompt: c.prompt,
            reward: c.reward,
            commitDeadline: c.commitDeadline,
            revealDeadline: c.revealDeadline,
            finalized: c.finalized,
            winner: c.winner,
            participantCount: c.participants.length,
            answerCount: c.answers.length,
            totalBids: c.totalBids,
            judged: c.judged
        });
    }

    function getAnswers(uint256 id) external view returns (string[] memory) {
        require(msg.sender == challenges[id].owner || challenges[id].finalized, "Not authorized");
        return challenges[id].answers;
    }

    function getAIScore(uint256 id, address participant) external view returns (uint256) {
        return challenges[id].aiScores[participant];
    }

    function getBid(uint256 id, address participant) external view returns (uint256) {
        return challenges[id].bids[participant];
    }

    function hasCommitted(uint256 id, address participant) external view returns (bool) {
        return challenges[id].commitments[participant] != 0;
    }

    function hasRevealed(uint256 id, address participant) external view returns (bool) {
        return challenges[id].hasRevealed[participant];
    }
}
