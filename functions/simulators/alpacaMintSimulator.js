const {
  simulateScript,
  decodeResult,
} = require("@chainlink/functions-toolkit");
const requestConfig = require("../configs/alpacaMintConfig");

// simulates what will happen in chainlink node
async function main() {
  const { responseBytesHexstring, errorString } = await simulateScript(
    requestConfig
  );

  if (responseBytesHexstring) {
    console.log(
      `Response returned by script: ${decodeResult(
        responseBytesHexstring,
        requestConfig.expectedReturnType
      ).toString()}\n`
    );
  }
  if (errorString) {
    console.log(`Error returned by script: ${errorString}\n`);
  }
}

main().catch((error) => {
  console.log(error);
  process.exitCode = 1;
});
