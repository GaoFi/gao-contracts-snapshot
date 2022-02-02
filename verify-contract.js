const axios = require("axios");
const fs = require("fs");
const { glob } = require("glob");
const solc = require("solc");

const getCompiler = async (version) => {
  return new Promise((resolve, reject) => {
    solc.loadRemoteVersion(version, (err, snapshot) => {
      if (err) return reject("Error getting remote version");
      resolve(snapshot);
    });
  });
};

const getFiles = async (dir) => {
  return new Promise((resolve, reject) => {
    glob(dir, (err, files) => {
      if (err) return reject("Error getting files in dir");
      resolve(files);
    });
  });
};

const getContractCreationBytecode = async (contract) => {
  const { data: contractInfo } = await axios.get(
    `https://tomoscan.io/api/account/${contract}`
  );

  const {
    data: { input: contractCreationData },
  } = await axios.get(
    `https://tomoscan.io/api/transaction/${contractInfo.contractCreatedAtTxHash}`
  );

  return contractCreationData;
};

const info = JSON.parse(
  fs.readFileSync(`${process.argv[2]}/info.json`, "utf8")
);

(async () => {
  const dir = `${info.contractAddress}/src/`;
  const sources = await getFiles(`${dir}/**/*.sol`);

  const sourcesByFileName = sources
    .map((fileName) => fileName.replace(dir, ""))
    .reduce(
      (acc, fileName) => ({
        ...acc,
        [fileName]: {
          content: fs.readFileSync(`${dir}${fileName}`, "utf-8"),
        },
      }),
      {}
    );

  const compilerSettings = {
    language: "Solidity",
    sources: sourcesByFileName,
    settings: {
      optimizer: {
        enabled: info.optimizations,
      },
      outputSelection: {
        [info.sourceName]: {
          [info.contractName]: ["evm.bytecode.object"],
        },
      },
    },
  };
  const compiler = await getCompiler(info.compilerVersion);
  const output = JSON.parse(compiler.compile(JSON.stringify(compilerSettings)));

  const compiledBytecode = `0x${
    output.contracts[info.sourceName][info.contractName].evm.bytecode.object
  }${info.constructorArgumentsEncoded}`;
  const contractCreationBytecode = await getContractCreationBytecode(
    info.contractAddress
  );
  if (compiledBytecode === contractCreationBytecode) {
    console.log("Source matches contract");
  } else {
    console.log("Source didn't match contract");
  }
})();
