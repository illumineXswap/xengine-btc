export const rsToDer = (r: string, s: string): string => {
  const buff = Buffer.alloc(4 + 32 + 2 + 32);
  buff.writeUint8(0x30, 0);
  buff.writeUint8(32 + 32 + 4, 1);
  buff.writeUint8(0x2, 2);

  buff.writeUint8(32, 3);
  buff.write(r.slice(2), 4, "hex");

  buff.writeUint8(0x2, 4 + 32);

  buff.writeUint8(32, 4 + 32 + 1);
  buff.write(s.slice(2), 4 + 32 + 2, "hex");

  return `0x${buff.toString("hex")}`;
};
