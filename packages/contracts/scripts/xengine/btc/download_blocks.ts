import { BitcoinClient } from "../../../utils/bitcoin-rpc";
import { createWriteStream } from "fs";

const main = async () => {
  const client = new BitcoinClient(process.env.BITCOIN_RPC_CLIENT!);

  const fromBlockHeight = 828576; // 00000000000000000001aa9cefb939e2932546e5dd378cb0d07a77ec60a3d06f
  const toBlockHeight = fromBlockHeight + 2017;

  const parallelBlocks = 20;

  const totalChunks = Math.floor(
    (toBlockHeight - fromBlockHeight) / parallelBlocks,
  );

  const blocksStream = createWriteStream(
    `./BTC-blocks-${fromBlockHeight}-${toBlockHeight}.txt`,
  );

  const try_fetch_range = async (
    _from: number,
    _to: number,
  ): Promise<string[]> => {
    const chunk: Promise<string>[] = [];
    for (let i = _from; i < _to; i++) {
      chunk.push(
        new Promise(async (resolve, reject) => {
          try {
            resolve(
              await client.getRawBlockHeader(
                (await client.getBlockByNumber(i)).hash,
              ),
            );
          } catch (err) {
            reject(err);
          }
        }),
      );
    }

    return Promise.all(chunk);
  };

  const try_fetch = async (_c: number): Promise<string[]> => {
    return try_fetch_range(
      fromBlockHeight + _c * parallelBlocks + 1,
      fromBlockHeight + _c * parallelBlocks + parallelBlocks + 1,
    );
  };

  for (let c = 0; c < totalChunks; c++) {
    let blocks: string[] = [];
    while (blocks.length === 0) {
      try {
        blocks = await try_fetch(c);
      } catch (err) {
        console.log(err);
      }
    }

    blocks.forEach((block) => blocksStream.write(block));
    console.log(`Progress ${(c / totalChunks) * 100}% ...`);
  }

  const leftOver = (toBlockHeight - fromBlockHeight) % parallelBlocks;

  const lastC = totalChunks - 1;

  const lastCheckpoint =
    Number(fromBlockHeight) + lastC * parallelBlocks + parallelBlocks + 1;

  let blocks: string[] = [];
  while (blocks.length === 0) {
    try {
      blocks = await try_fetch_range(lastCheckpoint, lastCheckpoint + leftOver);
    } catch (err) {
      console.log(err);
    }
  }

  blocks.forEach((block) => blocksStream.write(block));
  blocksStream.close();
};

main();
