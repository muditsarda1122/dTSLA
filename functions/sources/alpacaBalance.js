// secrets will never be stored on chain, it shall be uploaded on DON
// this javascript code will be onchain
if (secrets.alpacaKey == "" || secrets.alpacaSecret == "") {
  throw Error("Need Alpaca keys");
}

const alpacaRequest = Functions.makeHttpRequest({
  url: "https://paper-api.alpaca.markets/v2/account",
  headers: {
    accept: "application/json",
    "APCA-API-KEY-ID": secrets.alpacaKey,
    "APCA-API-SECRET-KEY": secrets.alpacaSecret,
  },
});

const [response] = await Promise.all([alpacaRequest]);

const portfolioBalance = response.data.portfolio_value;
console.log(`Alpaca portfolio balance: $${portfolioBalance}`);

// The source code MUST return a Buffer or the request will return an error message
// Use one of the following functions to convert to a Buffer representing the response bytes that are returned to the consumer smart contract:
// - Functions.encodeUint256
// - Functions.encodeInt256
// - Functions.encodeString
return Functions.encodeUint256(
  Math.round(portfolioBalance * 1000000000000000000)
);
