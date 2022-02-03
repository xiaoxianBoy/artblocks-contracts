import {
  BN,
  constants,
  expectEvent,
  expectRevert,
  balance,
  ether,
} from "@openzeppelin/test-helpers";
import { expect } from "chai";
import { ethers } from "hardhat";

describe("MinterFilter", async function () {
  const name = "Non Fungible Token";
  const symbol = "NFT";

  const firstTokenId = new BN("30000000");
  const secondTokenId = new BN("3000001");

  const pricePerTokenInWei = ethers.utils.parseEther("1");
  const higherPricePerTokenInWei = ethers.utils.parseEther("1.1");
  const projectOne = 0;
  const projectTwo = 1;
  const projectThree = 2;

  beforeEach(async function () {
    const [owner, newOwner, artist, additional, snowfro] =
      await ethers.getSigners();
    this.accounts = {
      owner: owner,
      newOwner: newOwner,
      artist: artist,
      additional: additional,
      snowfro: snowfro,
    };
    const randomizerFactory = await ethers.getContractFactory("Randomizer");
    this.randomizer = await randomizerFactory.deploy();

    const artblocksFactory = await ethers.getContractFactory("GenArt721CoreV3");
    this.token = await artblocksFactory
      .connect(snowfro)
      .deploy(name, symbol, this.randomizer.address);

    const minterFilterFactory = await ethers.getContractFactory("MinterFilter");
    this.minterFilter = await minterFilterFactory.deploy(this.token.address);

    const minterFactory = await ethers.getContractFactory(
      "GenArt721FilteredMinterETH"
    );
    this.minter1 = await minterFactory.deploy(
      this.token.address,
      this.minterFilter.address
    );
    this.minter2 = await minterFactory.deploy(
      this.token.address,
      this.minterFilter.address
    );
    this.minter3 = await minterFactory.deploy(
      this.token.address,
      this.minterFilter.address
    );

    await this.token.connect(snowfro).addProject("project1", artist.address);

    await this.token.connect(snowfro).addProject("project2", artist.address);

    await this.token.connect(snowfro).addProject("project3", artist.address);

    await this.token.connect(snowfro).toggleProjectIsActive(projectOne);
    await this.token.connect(snowfro).toggleProjectIsActive(projectTwo);
    await this.token.connect(snowfro).toggleProjectIsActive(projectThree);

    await this.token
      .connect(snowfro)
      .updateMinterContract(this.minterFilter.address);

    await this.token
      .connect(artist)
      .updateProjectMaxInvocations(projectOne, 15);
    await this.token
      .connect(artist)
      .updateProjectMaxInvocations(projectTwo, 15);
    await this.token
      .connect(artist)
      .updateProjectMaxInvocations(projectThree, 15);

    await this.token
      .connect(this.accounts.artist)
      .toggleProjectIsPaused(projectOne);
    await this.token
      .connect(this.accounts.artist)
      .toggleProjectIsPaused(projectTwo);
    await this.token
      .connect(this.accounts.artist)
      .toggleProjectIsPaused(projectThree);

    await this.minterFilter
      .connect(this.accounts.snowfro)
      .addApprovedMinter(this.minter1.address);
    await this.minterFilter
      .connect(this.accounts.snowfro)
      .addApprovedMinter(this.minter2.address);
    await this.minterFilter
      .connect(this.accounts.snowfro)
      .addApprovedMinter(this.minter3.address);

    await this.minterFilter
      .connect(this.accounts.snowfro)
      .setMinterForProject(projectOne, this.minter1.address);
    await this.minterFilter
      .connect(this.accounts.snowfro)
      .setMinterForProject(projectTwo, this.minter2.address);
    // We leave project three with no minter on purpose

    // set token price for first two projects on minter one
    await this.minter1
      .connect(artist)
      .updatePricePerTokenInWei(projectOne, pricePerTokenInWei);
    await this.minter1
      .connect(artist)
      .updatePricePerTokenInWei(projectTwo, pricePerTokenInWei);
  });

  describe("updatePricePerTokenInWei", async function () {
    it("only allows artist to update price", async function () {
      const onlyArtistErrorMessage = "Only Artist";
      // doesn't allow owner
      await expectRevert(
        this.minter1
          .connect(this.accounts.owner)
          .updatePricePerTokenInWei(projectOne, higherPricePerTokenInWei),
        onlyArtistErrorMessage
      );
      // doesn't allow snowfro
      await expectRevert(
        this.minter1
          .connect(this.accounts.snowfro)
          .updatePricePerTokenInWei(projectOne, higherPricePerTokenInWei),
        onlyArtistErrorMessage
      );
      // doesn't allow additional
      await expectRevert(
        this.minter1
          .connect(this.accounts.additional)
          .updatePricePerTokenInWei(projectOne, higherPricePerTokenInWei),
        onlyArtistErrorMessage
      );
      // does allow artist
      await this.minter1
        .connect(this.accounts.artist)
        .updatePricePerTokenInWei(projectOne, higherPricePerTokenInWei);
    });

    it("enforces price update", async function () {
      const needMoreValueErrorMessage = "Must send minimum value to mint!";
      // artist increases price
      await this.minter1
        .connect(this.accounts.artist)
        .updatePricePerTokenInWei(projectOne, higherPricePerTokenInWei);
      // cannot purchase token at lower price
      await expectRevert(
        this.minter1.connect(this.accounts.owner).purchase(projectOne, {
          value: pricePerTokenInWei,
        }),
        needMoreValueErrorMessage
      );
      // can purchase token at higher price
      await this.minter1.connect(this.accounts.owner).purchase(projectOne, {
        value: higherPricePerTokenInWei,
      });
    });

    it("enforces price update only on desired project", async function () {
      const needMoreValueErrorMessage = "Must send minimum value to mint!";
      // update project two to use minter one
      await this.minterFilter
        .connect(this.accounts.snowfro)
        .setMinterForProject(projectTwo, this.minter1.address);
      // artist increases price of project one
      await this.minter1
        .connect(this.accounts.artist)
        .updatePricePerTokenInWei(projectOne, higherPricePerTokenInWei);
      // cannot purchase project one token at lower price
      await expectRevert(
        this.minter1.connect(this.accounts.owner).purchase(projectOne, {
          value: pricePerTokenInWei,
        }),
        needMoreValueErrorMessage
      );
      // can purchase project two token at lower price
      await this.minter1.connect(this.accounts.owner).purchase(projectTwo, {
        value: pricePerTokenInWei,
      });
    });

    it("emits event upon price update", async function () {
      // artist increases price
      await expect(
        this.minter1
          .connect(this.accounts.artist)
          .updatePricePerTokenInWei(projectOne, higherPricePerTokenInWei)
      )
        .to.emit(this.minter1, "PricePerTokenInWeiUpdated")
        .withArgs(projectOne, higherPricePerTokenInWei);
    });
  });

  describe("purchase", async function () {
    it("allows purchases through the correct minter", async function () {
      for (let i = 0; i < 15; i++) {
        await this.minter1.connect(this.accounts.owner).purchase(projectOne, {
          value: pricePerTokenInWei,
        });
      }
      for (let i = 0; i < 15; i++) {
        await this.minter2.connect(this.accounts.owner).purchase(projectTwo, {
          value: pricePerTokenInWei,
        });
      }
    });

    it("blocks purchases through the incorrect minter", async function () {
      const noAssignedMinterErrorMessage = "EnumerableMap: nonexistent key";
      const OnlyAssignedMinterErrorMessage = "Only assigned minter";
      await expectRevert(
        this.minter2.connect(this.accounts.owner).purchase(projectOne, {
          value: pricePerTokenInWei,
        }),
        OnlyAssignedMinterErrorMessage
      );
      await expectRevert(
        this.minter1.connect(this.accounts.owner).purchase(projectTwo, {
          value: pricePerTokenInWei,
        }),
        OnlyAssignedMinterErrorMessage
      );

      await expectRevert(
        this.minter1.connect(this.accounts.owner).purchase(projectThree, {
          value: pricePerTokenInWei,
        }),
        noAssignedMinterErrorMessage
      );
      await expectRevert(
        this.minter2.connect(this.accounts.owner).purchase(projectThree, {
          value: pricePerTokenInWei,
        }),
        noAssignedMinterErrorMessage
      );

      await expectRevert(
        this.minter3.connect(this.accounts.owner).purchase(projectOne, {
          value: pricePerTokenInWei,
        }),
        OnlyAssignedMinterErrorMessage
      );
      await expectRevert(
        this.minter3.connect(this.accounts.owner).purchase(projectTwo, {
          value: pricePerTokenInWei,
        }),
        OnlyAssignedMinterErrorMessage
      );
      await expectRevert(
        this.minter3.connect(this.accounts.owner).purchase(projectThree, {
          value: pricePerTokenInWei,
        }),
        noAssignedMinterErrorMessage
      );
    });
  });

  describe("purchaseTo", async function () {
    it("allows `purchaseTo` by default", async function () {
      await this.minter1
        .connect(this.accounts.owner)
        .purchaseTo(this.accounts.additional.address, projectOne, {
          value: pricePerTokenInWei,
        });
    });

    it("disallows `purchaseTo` if disallowed explicitly", async function () {
      await this.minter1
        .connect(this.accounts.snowfro)
        .togglePurchaseToDisabled(projectOne);
      await expectRevert(
        this.minter1
          .connect(this.accounts.owner)
          .purchaseTo(this.accounts.additional.address, projectOne, {
            value: pricePerTokenInWei,
          }),
        "No `purchaseTo` Allowed"
      );
      // still allows `purchaseTo` if destination matches sender.
      await this.minter1
        .connect(this.accounts.owner)
        .purchaseTo(this.accounts.owner.address, projectOne, {
          value: pricePerTokenInWei,
        });
    });

    it("emits event when `purchaseTo` is toggled", async function () {
      // emits true when changed from initial value of false
      await expect(
        this.minter1
          .connect(this.accounts.snowfro)
          .togglePurchaseToDisabled(projectOne)
      )
        .to.emit(this.minter1, "PurchaseToDisabledUpdated")
        .withArgs(projectOne, true);
      // emits false when changed from initial value of true
      await expect(
        this.minter1
          .connect(this.accounts.snowfro)
          .togglePurchaseToDisabled(projectOne)
      )
        .to.emit(this.minter1, "PurchaseToDisabledUpdated")
        .withArgs(projectOne, false);
    });
  });

  describe("only allow ETH", async function () {
    it("disallows non-ETH projects", async function () {
      await this.token
        .connect(this.accounts.artist)
        .updateProjectCurrencyInfo(
          projectOne,
          "USDC",
          "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"
        );

      await expectRevert(
        this.minter1
          .connect(this.accounts.owner)
          .purchaseTo(this.accounts.additional.address, projectOne, {
            value: pricePerTokenInWei,
          }),
        "Project currency must be ETH"
      );
    });
  });
});
