// This file is used to configure the deployment of Engine and Engine Flex contracts
// It is intended to be imported by the batch engine factory deployer by running `deploy:mainnet:v3-engine`, `deploy:staging:v3-engine` or `deploy:dev:v3-engine`.
type EngineConfiguration = {
  tokenName: string;
  tokenSymbol: string;
  renderProviderAddress: string;
  platformProviderAddress: string;
  newSuperAdminAddress: string; // Address 0 to use existing, "0x..." for new
  randomizerContractAddress: string | null;
  splitProviderAddress: string;
  startingProjectId: number;
  autoApproveArtistSplitProposals: boolean;
  nullPlatformProvider: boolean;
  allowArtistProjectActivation: boolean;
};

export type EngineContractConfig = {
  engineCoreContractType: number; // 0 for engine, 1 for engine flex
  engineConfiguration: EngineConfiguration;
  adminACLContract: string; // Address 0 for new or existing "0x..."
  salt: string;
  transactionHash?: string;
  defaultVerticalName: string;
};

export const deployConfigDetailsArray = [
  {
    engineCoreContractType: 0, // 0 for Engine, 1 for Engine Flex
    engineConfiguration: {
      tokenName: "NFT",
      tokenSymbol: "NFT",
      renderProviderAddress: "0x...",
      platformProviderAddress: "0x...",
      newSuperAdminAddress: "0x...",
      randomizerContractAddress: null,
      splitProviderAddress: "0x...",
      startingProjectId: 0,
      autoApproveArtistSplitProposals: true,
      nullPlatformProvider: false,
      allowArtistProjectActivation: true,
    },
    adminACLContract: "0x...",
    salt: "0x0",
    transactionHash: null,
    // optionally define this to set default vertical name for the contract after deployment.
    // if not defined, the default vertical name will be "unassigned".
    // common values include `fullyonchain`, `flex`, or partnerships like `artblocksxpace`.
    // also note that if you desire to create a new veritcal, you will need to add the vertical name to the
    // `project_verticals` table in the database before running this deploy script.
    defaultVerticalName: "fullyonchain",
  },
];
