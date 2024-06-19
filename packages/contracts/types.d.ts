type HexString = `0x${string}`;
declare module "@illuminex/contracts/deployments.json" {
  type SapphireChainConfig = Record<
    "multicall" | "factory" | "router" | "wrapperFactory" | "endpoint",
    HexString
  >;
  type SideChainConfig = Record<"endpoint", HexString>;

  type Config = Record<HexString, SapphireChainConfig | SideChainConfig>;
  export default Config;
}
