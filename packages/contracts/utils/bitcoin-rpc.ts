import fetch from "node-fetch";

export type BitcoinBlock = {
  readonly hash: string;
  readonly confirmations: number;
  readonly size: number;
  readonly height: number;
  readonly merkleroot: string;
  readonly nonce: number;
  readonly bits: string;
  readonly difficulty: number;
  readonly chainwork: string;
  readonly previousblockhash: string;
  readonly nextblockhash: string;
  readonly time: number;
  readonly version: number;
  readonly tx?: BitcoinTx[];
};

export type BitcoinTestMempoolAccept = {
  readonly "reject-reason": string;
  readonly allowed: boolean;
};

export type BitcoinTxInput = {
  readonly vout: number;
  readonly txid: string;
  readonly scriptSig: {
    asm: string;
    hex: string;
  };
  readonly sequence: number;
};

export type BitcoinTxOutput = {
  readonly value: number;
  readonly scriptPubKey: {
    readonly asm: string;
    readonly hex: string;
  };
};

export type BitcoinTx = {
  readonly txid: string;
  readonly hash: string;
  readonly blockhash: string;
  readonly version: number;
  readonly vin: BitcoinTxInput[];
  readonly vout: BitcoinTxOutput[];
};

export type BitcoinUserAuth = {
  readonly user: string;
  readonly password: string;
};

export class BitcoinClient {
  private idCounter = 0;

  constructor(
    private readonly rpcUrl: string,
    private auth?: BitcoinUserAuth,
  ) {
    const authData = process.env["BITCOIN_RPC_AUTH"];
    if (authData && !auth) {
      const splitResult = authData.split(":");
      this.auth = {
        user: splitResult[0],
        password: splitResult[1],
      };
    }
  }

  getDifficultyTarget(difficultyBits: string): string {
    const bits = BigInt(Number(`0x${difficultyBits}`));

    const exp = bits >> 24n;
    const mant = bits & 0xffffffn;
    const target = mant * (1n << (8n * (exp - 3n)));

    return `0x${target.toString(16)}`;
  }

  private async query<P, R>(method: string, params: P): Promise<R> {
    const request = await fetch(this.rpcUrl, {
      method: "POST",
      headers: this.auth
        ? {
            Authorization: `Basic ${Buffer.from(this.auth.user + ":" + this.auth.password).toString("base64")}`,
          }
        : undefined,
      body: JSON.stringify({
        jsonrpc: "2.0",
        method,
        params,
        id: this.idCounter++,
      }),
    });

    const response = await request.json();
    const jsonRpcResponse = response as {
      jsonrpc: "2.0";
      result: R;
      id: number;
    };

    return jsonRpcResponse.result;
  }

  async getBlockByNumber(height: number): Promise<BitcoinBlock> {
    return this.getBlock(await this.getBlockHash(height));
  }

  async getBlockHash(height: number): Promise<string> {
    return this.query<[number], string>("getblockhash", [height]);
  }

  async getBlock(hash: string, verbosity = 1): Promise<BitcoinBlock> {
    return this.query<[string, number], BitcoinBlock>("getblock", [
      hash,
      verbosity,
    ]);
  }

  async getRawBlockHeader(hash: string): Promise<string> {
    return this.query<[string, boolean], string>("getblockheader", [
      hash,
      false,
    ]);
  }

  async getLatestBlock(): Promise<BitcoinBlock> {
    const bestBlockHash = await this.query<[], string>("getbestblockhash", []);
    return this.getBlock(bestBlockHash);
  }

  async testTxInclusion(tx: string): Promise<BitcoinTestMempoolAccept> {
    const result = await this.query<[[string]], [BitcoinTestMempoolAccept]>(
      "testmempoolaccept",
      [[tx]],
    );

    return result[0];
  }

  async getTx<T>(txId: string, verbose = false): Promise<any> {
    return this.query<[string, boolean], any>("getrawtransaction", [
      txId,
      verbose,
    ]);
  }

  async getRawTx(txId: string): Promise<string> {
    return this.getTx<string>(txId);
  }

  async getVerboseTx(txId: string): Promise<BitcoinTx> {
    return this.getTx<BitcoinTx>(txId, true);
  }
}
