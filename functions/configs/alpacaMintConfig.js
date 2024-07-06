const fs = require("fs");
const {
  Location,
  ReturnType,
  CodeLanguage,
} = require("@chainlink/functions-toolkit");

// we send our secrets to the DON, even the DON can not read and decrypt our secret. Then this DON will execute our API call.
const requestConfig = {
  // String containing the source code to be executed
  source: fs.readFileSync("./functions/sources/alpacaBalance.js").toString(),
  // Location of source code (only Inline is currently supported)
  codeLocation: Location.Inline,
  // the secrets will be sent to the DON
  secrets: {
    alpacaKey: process.env.ALPACA_API_KEY,
    alpacaSecret: process.env.ALPACA_SECRET_KEY,
  },
  secretsLocation: Location.DONHosted,
  // Args (string only array) can be accessed within the source code with `args[index]` (ie: args[0]).
  args: [],
  codeLanguage: CodeLanguage.JavaScript,
  expectedReturnType: ReturnType.uint256,
};

module.exports = requestConfig;
