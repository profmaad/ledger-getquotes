# ledger-getquotes
Retrieve stock and currency quotes and maintain them in a ledger pricedb

## Config file
The tool reads a config file to retrieve API keys and the list of assets to maintain prices for.

To get API keys, you need to register with
- Alphavantage for stocks: https://www.alphavantage.co/support/#api-key
- Currencylayer for currencies: https://currencylayer.com/signup?plan=1

`lookback` determines how many days into the past prices should be updated for. Note that the currencylayer API requires one request per day, for any number of currencies. Alphavantage on the other hand requires one request per stock, but with full history.

`assets` defines the list of assets to maintain prices for. There are mainly two types of assets: `stock` and `currency`.
The format is: `type:data provider asset name:ledger asset name`. If the last part is ommited, the `data provider asset name` is used as a the `ledger asset name`, too.

Example:
```yaml
api_keys:
  alphavantage: FOOBAR
  currencylayer: BARFOO

lookback: 14

assets:
  - stock:IBM
  - stock:AAPL:AAPL US Equity
  - currency:AUD
  - currency:EUR:€
```

## Usage
Once you have a config file, you can run:
`bin/ledger-getquotes.rb update --config config.yaml --pricedb prices.ledger`

This will retrieve prices from yesterday up to `yesterday-lookback` and add those entries to the given `pricesdb` file.

There are two utility commands:
- `bin/ledger-getquotes.rb parse_pricedb --pricedb prices.ledger` will parse the given pricedb and dump out the internal representation
- `bin/ledger-getquotes.rb get --config ~/.ledger_getquotes.yaml --asset currency:AUD` will retrieve prices for a single asset and print out the corresponding pricedb lines
