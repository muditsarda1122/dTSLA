# dTSLA

These smart contracts facilitate transforming your Tesla stocks to digital tokens(ERC20) Chainlink Functions are utilized to call Alpaca's API to get real time information about the account balance of the user. TSLA/USD price feed could not be found on Sepolia, hence LINK/ETH price feed is used as TSLA/LINK price feed can be found on Polygon. 

Function script can be run using the command
```
npm run simulate
```

Future work includes writing a script for facilitating selling of TSLA stocks on alpaca and sending back the USDC to the smart contracts. 
