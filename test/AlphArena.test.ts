import { expect } from "chai";
import { ethers } from "hardhat";
import { AlphArena, MockUSDC } from "../typechain-types";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";

describe("AlphArena", function () {
  let arena: AlphArena;
  let usdc: MockUSDC;
  let owner: HardhatEthersSigner;
  let operatorSigner: HardhatEthersSigner;
  let agentA: HardhatEthersSigner;
  let agentB: HardhatEthersSigner;
  let stranger: HardhatEthersSigner;

  const USDC = (n: number) => BigInt(n) * 10n ** 6n; // 6 decimals
  const MATCH_ID = ethers.id("match-001");

  beforeEach(async function () {
    [owner, operatorSigner, agentA, agentB, stranger] = await ethers.getSigners();

    // Deploy MockUSDC
    const MockUSDC = await ethers.getContractFactory("MockUSDC");
    usdc = await MockUSDC.deploy();

    // Deploy AlphArena with USDC address
    const AlphArena = await ethers.getContractFactory("AlphArena");
    arena = await AlphArena.deploy(await usdc.getAddress());

    // Set operator
    await arena.setOperator(operatorSigner.address);

    // Fund operator with USDC for escrow
    await usdc.mint(operatorSigner.address, USDC(100_000));
    // Operator approves arena to spend USDC
    await usdc.connect(operatorSigner).approve(await arena.getAddress(), ethers.MaxUint256);
  });

  // ---------------------------------------------------------------------------
  //  Deployment
  // ---------------------------------------------------------------------------

  describe("Deployment", function () {
    it("sets the USDC token address as immutable", async function () {
      expect(await arena.usdc()).to.equal(await usdc.getAddress());
    });

    it("sets deployer as owner", async function () {
      expect(await arena.owner()).to.equal(owner.address);
    });

    it("USDC has 6 decimals", async function () {
      expect(await usdc.decimals()).to.equal(6);
    });

    it("reverts if deployed with zero USDC address", async function () {
      const AlphArena = await ethers.getContractFactory("AlphArena");
      await expect(AlphArena.deploy(ethers.ZeroAddress)).to.be.revertedWithCustomError(
        arena,
        "ZeroAddress"
      );
    });
  });

  // ---------------------------------------------------------------------------
  //  Admin
  // ---------------------------------------------------------------------------

  describe("Admin", function () {
    it("owner can set operator", async function () {
      await expect(arena.setOperator(stranger.address))
        .to.emit(arena, "OperatorUpdated")
        .withArgs(operatorSigner.address, stranger.address);
      expect(await arena.operator()).to.equal(stranger.address);
    });

    it("non-owner cannot set operator", async function () {
      await expect(
        arena.connect(stranger).setOperator(stranger.address)
      ).to.be.revertedWithCustomError(arena, "OnlyOwner");
    });

    it("owner can transfer ownership", async function () {
      await expect(arena.transferOwnership(stranger.address))
        .to.emit(arena, "OwnershipTransferred")
        .withArgs(owner.address, stranger.address);
      expect(await arena.owner()).to.equal(stranger.address);
    });

    it("cannot set operator to zero address", async function () {
      await expect(arena.setOperator(ethers.ZeroAddress)).to.be.revertedWithCustomError(
        arena,
        "ZeroAddress"
      );
    });

    it("cannot transfer ownership to zero address", async function () {
      await expect(
        arena.transferOwnership(ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(arena, "ZeroAddress");
    });
  });

  // ---------------------------------------------------------------------------
  //  Escrow
  // ---------------------------------------------------------------------------

  describe("escrowFunds", function () {
    it("escrows USDC and emits event", async function () {
      const amount = USDC(100);
      await expect(
        arena
          .connect(operatorSigner)
          .escrowFunds(MATCH_ID, agentA.address, agentB.address, amount)
      )
        .to.emit(arena, "FundsEscrowed")
        .withArgs(MATCH_ID, agentA.address, agentB.address, amount);

      // Check match state
      const [rAgentA, rAgentB, rAmount, rState] = await arena.getMatchInfo(MATCH_ID);
      expect(rAgentA).to.equal(agentA.address);
      expect(rAgentB).to.equal(agentB.address);
      expect(rAmount).to.equal(amount);
      expect(rState).to.equal(1); // Escrowed

      // USDC transferred to contract
      expect(await usdc.balanceOf(await arena.getAddress())).to.equal(amount);
    });

    it("reverts if not operator", async function () {
      await expect(
        arena.connect(stranger).escrowFunds(MATCH_ID, agentA.address, agentB.address, USDC(10))
      ).to.be.revertedWithCustomError(arena, "OnlyOperator");
    });

    it("reverts if match already exists", async function () {
      await arena
        .connect(operatorSigner)
        .escrowFunds(MATCH_ID, agentA.address, agentB.address, USDC(10));

      await expect(
        arena
          .connect(operatorSigner)
          .escrowFunds(MATCH_ID, agentA.address, agentB.address, USDC(10))
      ).to.be.revertedWithCustomError(arena, "MatchAlreadyExists");
    });

    it("reverts on zero agent address", async function () {
      await expect(
        arena
          .connect(operatorSigner)
          .escrowFunds(MATCH_ID, ethers.ZeroAddress, agentB.address, USDC(10))
      ).to.be.revertedWithCustomError(arena, "ZeroAddress");
    });

    it("reverts on zero amount", async function () {
      await expect(
        arena
          .connect(operatorSigner)
          .escrowFunds(MATCH_ID, agentA.address, agentB.address, 0)
      ).to.be.revertedWithCustomError(arena, "InvalidAmount");
    });

    it("reverts if operator has insufficient USDC allowance", async function () {
      // Reset allowance to 0
      await usdc.connect(operatorSigner).approve(await arena.getAddress(), 0);

      await expect(
        arena
          .connect(operatorSigner)
          .escrowFunds(MATCH_ID, agentA.address, agentB.address, USDC(10))
      ).to.be.reverted;
    });
  });

  // ---------------------------------------------------------------------------
  //  Payout
  // ---------------------------------------------------------------------------

  describe("releasePayout", function () {
    const escrowAmount = USDC(200);

    beforeEach(async function () {
      await arena
        .connect(operatorSigner)
        .escrowFunds(MATCH_ID, agentA.address, agentB.address, escrowAmount);
    });

    it("pays winner full escrow amount", async function () {
      const balBefore = await usdc.balanceOf(agentA.address);

      await expect(
        arena.connect(operatorSigner).releasePayout(MATCH_ID, agentA.address, escrowAmount)
      )
        .to.emit(arena, "PayoutReleased")
        .withArgs(MATCH_ID, agentA.address, escrowAmount);

      const balAfter = await usdc.balanceOf(agentA.address);
      expect(balAfter - balBefore).to.equal(escrowAmount);

      // Match is settled
      expect(await arena.getMatchState(MATCH_ID)).to.equal(2); // Settled
    });

    it("partial payout sends remainder to fees", async function () {
      const payoutAmount = USDC(180);
      const expectedFee = escrowAmount - payoutAmount;

      await arena
        .connect(operatorSigner)
        .releasePayout(MATCH_ID, agentB.address, payoutAmount);

      expect(await arena.accumulatedFees()).to.equal(expectedFee);
    });

    it("reverts if match not escrowed", async function () {
      const otherMatch = ethers.id("nonexistent");
      await expect(
        arena.connect(operatorSigner).releasePayout(otherMatch, agentA.address, USDC(10))
      ).to.be.revertedWithCustomError(arena, "MatchNotEscrowed");
    });

    it("reverts if winner is not a participant", async function () {
      await expect(
        arena.connect(operatorSigner).releasePayout(MATCH_ID, stranger.address, USDC(10))
      ).to.be.revertedWithCustomError(arena, "InvalidWinner");
    });

    it("reverts if payout exceeds escrow", async function () {
      await expect(
        arena
          .connect(operatorSigner)
          .releasePayout(MATCH_ID, agentA.address, escrowAmount + 1n)
      ).to.be.revertedWithCustomError(arena, "PayoutExceedsEscrow");
    });

    it("reverts on zero payout", async function () {
      await expect(
        arena.connect(operatorSigner).releasePayout(MATCH_ID, agentA.address, 0)
      ).to.be.revertedWithCustomError(arena, "InvalidAmount");
    });
  });

  // ---------------------------------------------------------------------------
  //  Refund
  // ---------------------------------------------------------------------------

  describe("refundMatch", function () {
    const escrowAmount = USDC(100);

    beforeEach(async function () {
      await arena
        .connect(operatorSigner)
        .escrowFunds(MATCH_ID, agentA.address, agentB.address, escrowAmount);
    });

    it("refunds both agents equally", async function () {
      const balABefore = await usdc.balanceOf(agentA.address);
      const balBBefore = await usdc.balanceOf(agentB.address);

      await expect(arena.connect(operatorSigner).refundMatch(MATCH_ID))
        .to.emit(arena, "MatchRefunded")
        .withArgs(MATCH_ID);

      const half = escrowAmount / 2n;
      expect((await usdc.balanceOf(agentA.address)) - balABefore).to.equal(half);
      expect((await usdc.balanceOf(agentB.address)) - balBBefore).to.equal(half);

      // State is Refunded
      expect(await arena.getMatchState(MATCH_ID)).to.equal(3); // Refunded
    });

    it("odd-amount rounding remainder goes to fees", async function () {
      const oddAmount = USDC(100) + 1n; // 100.000001 USDC
      const matchId2 = ethers.id("match-odd");
      await arena
        .connect(operatorSigner)
        .escrowFunds(matchId2, agentA.address, agentB.address, oddAmount);

      await arena.connect(operatorSigner).refundMatch(matchId2);

      expect(await arena.accumulatedFees()).to.equal(1n); // 0.000001 USDC
    });

    it("reverts if match not escrowed", async function () {
      await expect(
        arena.connect(operatorSigner).refundMatch(ethers.id("nope"))
      ).to.be.revertedWithCustomError(arena, "MatchNotEscrowed");
    });

    it("cannot refund an already settled match", async function () {
      await arena
        .connect(operatorSigner)
        .releasePayout(MATCH_ID, agentA.address, escrowAmount);

      await expect(
        arena.connect(operatorSigner).refundMatch(MATCH_ID)
      ).to.be.revertedWithCustomError(arena, "MatchNotEscrowed");
    });
  });

  // ---------------------------------------------------------------------------
  //  Fee Withdrawal
  // ---------------------------------------------------------------------------

  describe("withdrawFees", function () {
    it("owner withdraws accumulated USDC fees", async function () {
      // Create a match and settle with partial payout to generate fees
      const escrow = USDC(100);
      const payout = USDC(90);
      await arena
        .connect(operatorSigner)
        .escrowFunds(MATCH_ID, agentA.address, agentB.address, escrow);
      await arena
        .connect(operatorSigner)
        .releasePayout(MATCH_ID, agentA.address, payout);

      const expectedFees = escrow - payout;
      expect(await arena.accumulatedFees()).to.equal(expectedFees);

      const ownerBalBefore = await usdc.balanceOf(owner.address);
      await expect(arena.withdrawFees())
        .to.emit(arena, "FeesWithdrawn")
        .withArgs(owner.address, expectedFees);

      expect((await usdc.balanceOf(owner.address)) - ownerBalBefore).to.equal(expectedFees);
      expect(await arena.accumulatedFees()).to.equal(0);
    });

    it("reverts if no fees accumulated", async function () {
      await expect(arena.withdrawFees()).to.be.revertedWithCustomError(
        arena,
        "NoFeesToWithdraw"
      );
    });

    it("non-owner cannot withdraw fees", async function () {
      await expect(
        arena.connect(stranger).withdrawFees()
      ).to.be.revertedWithCustomError(arena, "OnlyOwner");
    });
  });

  // ---------------------------------------------------------------------------
  //  View helpers
  // ---------------------------------------------------------------------------

  describe("View helpers", function () {
    it("getContractBalance returns USDC held", async function () {
      expect(await arena.getContractBalance()).to.equal(0);

      await arena
        .connect(operatorSigner)
        .escrowFunds(MATCH_ID, agentA.address, agentB.address, USDC(50));

      expect(await arena.getContractBalance()).to.equal(USDC(50));
    });

    it("getMatchState returns correct state", async function () {
      expect(await arena.getMatchState(MATCH_ID)).to.equal(0); // None

      await arena
        .connect(operatorSigner)
        .escrowFunds(MATCH_ID, agentA.address, agentB.address, USDC(10));
      expect(await arena.getMatchState(MATCH_ID)).to.equal(1); // Escrowed
    });
  });
});
