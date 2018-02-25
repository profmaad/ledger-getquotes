#!/usr/bin/env ruby
require 'rubygems'
require 'yaml'
require 'commander/import'
require 'httparty'
require 'pp'

program :name, 'ledger-getquotes'
program :version, '0.0.1'
program :description, 'Retrieve stock and currency quotes and maintain them in a ledger pricedb'

class PriceDBEntry
  attr_reader :date, :asset, :base_currency, :price

  def initialize(date, asset, base_currency, price)
    @date = date
    @asset = asset
    @base_currency = base_currency
    @price = price
  end

  def to_s()
    "P #{self.date} 00:00:00 \"#{self.asset}\" \"#{self.base_currency}\" #{self.price}"
  end

  def self.parse(s)
    parts = s.scan(/(?:[^ "]|"[^"]*")+/).map {|p| p.gsub(/^"/, '').gsub(/"$/, '')}
    if parts.length == 6 and parts[0] == "P" then
      date = Date.parse(parts[1])
      self.new(date, parts[3], parts[4], parts[5].to_f)
    else
      raise "Invalid entry: #{s} (#{parts})"
    end
  end
end

class PriceDB
  attr_reader :entries

  def initialize(entries)
    @entries = {}
    entries.each {|entry| add (entry)}
  end

  def add(entry)
    @entries[entry.asset] ||= {}
    @entries[entry.asset][entry.date] = entry
  end

  def self.load(file)
    entries = File.readlines(file).map do |line|
      PriceDBEntry.parse(line.strip)
    end

    self.new(entries)
  end

  def save(file)
    all_entries = @entries.values.map {|h| h.values}.flatten(1)
    File.open(file, "w+") do |file|
      all_entries.sort_by {|entry| entry.date}.each do |entry|
        file.puts(entry.to_s)
      end
    end
  end
end

class Asset
  attr_reader :type
  attr_reader :asset
  attr_reader :ledger_asset

  def initialize(type, asset, ledger_asset)
    @type = type
    @asset = asset
    @ledger_asset = ledger_asset
  end

  def self.of_s(s)
    fields = s.split(':')
    type = fields[0].to_sym
    asset = fields[1]
    ledger_asset = fields[2] || asset

    case type
    when :stock
    when :currency
    when :bctmpf
    else
      raise ArgumentError.new("unknown asset type #{type}")
    end

    self.new(type, asset, ledger_asset)
  end

  def to_s()
    if @ledger_asset != @asset then
      "#{@type}:#{@asset}:#{@ledger_asset}"
    else
      "#{@type}:#{@asset}"
    end
  end
end

class Config
  attr_reader :alphavantage_key
  attr_reader :currencylayer_key
  attr_reader :lookback
  attr_reader :assets

  def initialize(alphavantage_key, currencylayer_key, lookback, assets)
    @alphavantage_key = alphavantage_key
    @currencylayer_key = currencylayer_key
    @lookback = lookback
    @assets = assets
  end

  def self.load(file)
    config = YAML.load_file(file)

    alphavantage_key = config['api_keys']['alphavantage']
    currencylayer_key = config['api_keys']['currencylayer']
    lookback = config['lookback']
    assets = config['assets'].map {|s| Asset.of_s s}

    self.new(alphavantage_key, currencylayer_key, lookback, assets)
  end
end

def get_stock_quote(asset, api_key)
  ticker = asset.asset
  response = HTTParty.get("https://www.alphavantage.co/query?function=TIME_SERIES_DAILY&symbol=#{ticker}&outputsize=full&apikey=#{api_key}")
  data = response.parsed_response
  if response.code != 200 then
    raise "Alpha Vantage API request failed: #{response.body}"
  else
    data["Time Series (Daily)"].map do |date, values|
      PriceDBEntry.new(Date.parse(date), asset.ledger_asset, "USD", values["4. close"].to_f)
    end
  end
end

def get_currency_quote(assets, api_key, date)
  currencies = assets.each_with_object({}) do |asset, currencies|
    currencies[asset.asset] = asset
  end

  currency_tickers = currencies.keys.join(',')

  response = HTTParty.get("http://apilayer.net/api/historical?access_key=#{api_key}&date=#{date}&currencies=#{currency_tickers}")
  data = response.parsed_response
  if response.code != 200 || (not data["success"]) then
    raise "currencylayer API request failed: #{response.body}"
  else
    base_currency = data["source"]
    data["quotes"].map do |currency, price|
      asset = currency.slice(base_currency.length .. -1)
      PriceDBEntry.new(date, currencies[asset].ledger_asset, base_currency, 1 / price.to_f)
    end
  end
end

def get_bctmpf_quote(asset)
  uri = URI.parse "https://www.bcthk.com/funds/DownloadFundPrice/fundprice_#{asset.asset}_1.csv"

  csv_s = Net::HTTP.get(uri)
  csv_s.force_encoding(Encoding::UTF_8)
  csv_s.sub!("\xEF\xBB\xBF", "")

  csv = CSV.parse(csv_s, headers: true)

  csv.map do |line|
    date = Date.parse(line['Price Date'])
    price = line['Fund Price (HKD)'].to_f
    PriceDBEntry.new(date, asset.ledger_asset, "HKD", price)
  end
end

def get_quotes(assets, config, start_date, end_date)
  by_type = assets.each_with_object({}) do |asset, by_type|
    by_type[asset.type] ||= []
    by_type[asset.type] << asset
  end

  prices = []

  (by_type[:stock] || []).each do |asset|
    prices += get_stock_quote(asset, config.alphavantage_key)
  end

  (by_type[:bctmpf] || []).each do |asset|
    prices += get_bctmpf_quote(asset)
  end

  unless by_type[:currency].nil? then
    currency_prices = (start_date .. end_date).map do |date|
      get_currency_quote(by_type[:currency], config.currencylayer_key, date)
    end.flatten

    prices += currency_prices
  end

  prices.find_all do |entry|
    entry.date >= start_date and entry.date <= end_date
  end
end

command :get do |c|
  c.syntax = 'ledger-getquotes get [options]'
  c.summary = 'Retrieve and output quotes'
  c.description = ''
  c.option '--asset STRING', String, 'Asset to retrieve quotes for (examples: stock:IVV, currency:HKD, currency:ETH)'
  c.option '--config STRING', String, 'API key for Alpha Vantage, used to retrieve stock quotes'
  c.option '--start-date DATE', String, "First date for which to retrieve/print prices (default: 14 days ago)"
  c.option '--end-date DATE', String, "Latest date for which to retrieve/print prices (default: yesterday)"
  c.action do |args, options|
    config = Config.load(options.config)

    asset = Asset.of_s(options.asset)

    end_date =
      if options.end_date.nil? then
        Date.today.prev_day
      else
        Date.parse(options.end_date)
      end

    start_date =
      if options.start_date.nil? then
        end_date - 14
      else
        Date.parse(options.start_date)
      end

    prices = get_quotes([asset], config, start_date, end_date)

    prices.sort_by {|entry| entry.date}.each do |entry|
      puts entry.to_s
    end
  end
end

command :parse_pricedb do |c|
  c.syntax = 'ledger-getquotes parse_pricedb [options]'
  c.summary = 'Parse a pricedb file and print the entries'
  c.description = ''
  c.option '--pricedb STRING', String, 'pricedb file to parse'
  c.action do |args, options|
    pricedb = PriceDB.load(options.pricedb)
    pp pricedb
  end
end

command :update do |c|
  c.syntax = 'ledger-getquotes update [options]'
  c.summary = 'Update pricedb file'
  c.description = ''
  c.option '--config STRING', String, 'Config file'
  c.option '--pricedb STRING', String, 'pricedb file to update'
  c.action do |args, options|
    config = Config.load(options.config)
    pricedb = PriceDB.load(options.pricedb)

    end_date = Date.today.prev_day
    start_date = end_date - config.lookback

    get_quotes(config.assets, config, start_date, end_date).each do |entry|
      pricedb.add(entry)
    end

    pricedb.save(options.pricedb)
  end
end
