# Test Plan – BlindAuctionAIBounty

- Happy path: 2 participants commit with bids → reveal → AI scores → finalize
- Cannot reveal before deadline (reverts)
- Cannot commit without bid (reverts)
- Cannot finalize without AI scores (reverts)
- Loser gets bid refunded
- Winner receives reward (bid goes to owner)
