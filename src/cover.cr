require "uri"
require "http"
require "json"
require "db"
require "sqlite3"
require "option_parser"
require "yaml"
require "logger"

class Config
  getter providers : Array(String)
  getter port : Int32
  getter db : String
  getter sslport : (Int32|Nil)
  getter key : (String|Nil)
  getter cert : (String|Nil)
  getter log : (String|Nil)
  getter loglevel : (String|Nil)

  def initialize(config_file : String)
    yaml = File.open(config_file) {|file| YAML.parse(file) }

    # providers, db, and port are required.
    @providers = yaml["providers"].as_a.map { |name| name.as_s }
    @db = yaml["db"].as_s
    @port = yaml["port"].as_i

    # sslport, key, and cert are optional.
    if yaml["sslport"]?
      @sslport = yaml["sslport"].as_i
      @key = yaml["key"].as_s
      @cert = yaml["cert"].as_s
    end

    # log and loglevel are optional.
    if yaml["log"]?
      @log = yaml["log"].as_s
    end
    if yaml["loglevel"]?
      @loglevel = yaml["loglevel"].as_s
    end
  end
end

class MyLogger
  def initialize
    @log = uninitialized Logger
  end

  def configure(config : Config)
    levels = {
      "DEBUG"   => Logger::DEBUG,
      "ERROR"   => Logger::ERROR,
      "FATAL"   => Logger::FATAL,
      "INFO"    => Logger::INFO,
      "UNKNOWN" => Logger::UNKNOWN,
      "WARN"    => Logger::WARN
    }

    filename = config.log || ""
    loglevel = config.loglevel || "DEBUG"
    if filename.size > 0
      file = File.open(filename, "a+")
      @log = Logger.new(file)
    else
      @log = Logger.new(STDOUT)
    end
    @log.level = levels[loglevel.upcase]
  end

  macro dolog(name)
    def {{name}}(s : String)
      @log.{{name}}(s)
    end
  end

  dolog(debug)
  dolog(error)
  dolog(fatal)
  dolog(info)
  dolog(unknown)
  dolog(warn)

  def close
    @log.close
  end
end

LOG = MyLogger.new

class Provider
  def initialize(server : String,	# API server's base URL
		 prefix : String,	# prefix for query URL
		 suffix : String,	# suffix for query URL
                 image_tag : String,	# JSON tag for image info
		 dbname : String,	# sqlite3 database filename
		 table : String)	# table name for this provider
    # Set up the HTTP client for the API server.  Use this to fetch
    # cover image URLs that aren't in the cache.
    @server = server
    @prefix = prefix
    @suffix = suffix
    @image_tag = image_tag
    uri = URI.parse(@server)
    @client = HTTP::Client.new(uri)

    # Initialize the regular expression used to extract the image
    # URL from the JSON response returned by the API server.
    @regex = /#{@image_tag}\"\s*:\s*\"([^\"]+)\"/

    # Set up the database connection.  Use this to extract
    # URLs from the cache.
    @db = uninitialized DB::Database	# This avoids compiler error
    @db = DB.open dbname
    @dbname = dbname
    @table = table

    # Create the table if it does not already exist.
    sql = "CREATE TABLE IF NOT EXISTS #{@table} (isbn varchar primary key not null, url varchar not null)"
    LOG.debug "Executing #{sql}"
    @db.exec sql
  end

  def finalize
    if @db
      @db.close
    end
    if @client
      @client.close
    end
  end

  # Try to get a single image URL from the cache database.
  def get_db(isbn : String)
    url = nil
    if @db
      begin
	LOG.debug "Attempting to get URL for #{isbn} from #{@dbname}:#{@table}"
	sql = "select url from #{@table} where isbn = ? limit 1"
	LOG.debug "Executing #{sql}"
	@db.query sql, isbn do |rs|
	  rs.each do
	    url = rs.read(String)	# FIXME: should save URLs in array
	  end
	end
	if url
	  LOG.debug "Got url for #{isbn} from sqlite3 query: #{url}"
	else
	  LOG.debug "Unable to find #{isbn} in sqlite3"
	end
      rescue ex
	LOG.error "sqlite3 exception: #{ex.message}"
      end
    end
    return url
  end

  # Add an entry to the cache database
  def add_to_db(isbn : String, url : String)
    LOG.debug "Adding db entry for #{isbn} => #{url}"
    sql = "insert into #{@table} values (?, ?)"
    @db.exec sql, isbn, url
  end

  # Try to get a single image URL from the book API provider.
  def get_api(isbn : String)
    url = nil
    if @client
      LOG.debug "Attempting to get URL for #{isbn} from #{@server}"

      # Get JSON and extract thumbnail URL.
      request = @prefix + isbn + @suffix
      LOG.debug "Fetching #{@server}#{request}"
      response = @client.get(request)
      if response
	json = response.body
	LOG.debug "Response from #{@server}: #{json}"
	if json =~ @regex
	  url = $1.gsub("zoom=5", "zoom=1").
		   gsub("\\u0026", "&").
		   gsub("&edge=curl", "")
	else
	  LOG.debug "Unable to extract image URL from server's response"
	end
      else
	LOG.debug "Unable to get book info for #{isbn} from #{@server}"
      end
    end
    return url
  end

  def save_image(url : String, filename : String)
    LOG.debug "Fetching image from #{url}"
    jpeg = @client.get(url)
    f = File.open(filename, "wb")
    if f
      f.write(jpeg.body.to_slice)
    else
      LOG.debug "Unable to create #{filename}"
    end
    f.close
  end
end

class GoogleBooks < Provider
  def initialize(db : String)
    super("https://books.google.com", "/books?bibkeys=", "&jscmd=viewapi&amp;hl=en",
          "thumbnail_url",
          "sqlite3://#{db}", "gb")
  end
end

class OpenLibrary < Provider
  def initialize(db : String)
    super("https://openlibrary.org", "/api/books?bibkeys=ISBN:", "&jscmd=data&format=json",
          "medium",
          "sqlite3://#{db}", "ol")
  end
end

class Fetcher
  def initialize(config : Config)
    @config = config
    @providers = {} of String => Provider
    config.providers.each do |name|
      case name
      when "gb"
        @providers[name] = GoogleBooks.new(@config.db)
      when "ol"
        @providers[name] = OpenLibrary.new(@config.db)
      end
    end
  end

  # Get a single URL for a given ISBN.  Try
  # each provider in order and return the first
  # URL found.
  def get_image_url(isbn : String, provider_names : Array(String))
    if provider_names.size == 0
      provider_names = @config.providers
    end
    provider_names.each do |name|
      provider = @providers[name]?
      if provider
	url = provider.get_db(isbn)	# try cache first
	if url
	  return url
	end
	url = provider.get_api(isbn)	# try API server
	if url
	  provider.add_to_db(isbn, url)	# add to cache
	  return url
	end
      end
    end
    return nil
  end

  # Get the JSON representation of the image URLs
  # for an array of ISBNs.
  def get_images_json(isbns : Array(String), provider_names : Array(String))
    urls = {} of String => String
    isbns.each do |isbn|
      url = get_image_url(isbn, provider_names)
      if url
	urls[isbn] = url
      end
    end
    string = JSON.build do |json|
      json.object do
	if urls.size > 0
	  urls.each { |isbn, url| json.field isbn, url }
	else
	  json.field "error", "Bad id parameter"
	end
      end
    end
    LOG.debug "JSON response: #{string}"
    return string
  end

end

class Server
  def initialize(config : Config)
    @config = config
    @fetcher = Fetcher.new(config)
    @server = uninitialized HTTP::Server
  end

  def get_covers(context : HTTP::Server::Context)
    params = context.request.query_params
    id = params["id"]?
    provider = params["provider"]?
    callback = params["callback"]?
    response = "{}"
    if id
      isbns = id.split(",")
      if provider
	provider_names = provider.split(",")
      else
	provider_names = [] of String
      end
      # FIXME: pass providers list to fetcher.
      json = @fetcher.get_images_json(isbns, provider_names)
      if json
	LOG.debug "get_covers: JSON = #{json}"
	response = json
      else
	LOG.debug "get_covers: Unable to get JSON response for #{id}"
      end
    end
    if callback
      context.response.content_type = "application/javascript"
      context.response.print callback + "(" + response + ")"
    else
      context.response.content_type = "application/json"
      context.response.print response
    end
  end

  def process_request(context : HTTP::Server::Context)
    path = context.request.path
    LOG.debug "process_request: got path #{path}"

    case path
    when "/cover"
      get_covers(context)
    when "/"
      context.response.content_type = "text/plain"
      context.response.print "Welcome to cover"
    else
      context.response.content_type = "text/plain"
      context.response.print "Unrecognized request"
    end
  end

  def start
    @server = HTTP::Server.new do |context|
      process_request(context)
    end

    if @server
      address = @server.bind_tcp "0.0.0.0", @config.port
      LOG.debug "Listening on http://#{address}"
      if @config.sslport
	ssl_context = OpenSSL::SSL::Context::Server.new
	ssl_context.certificate_chain = @config.cert || ""
	ssl_context.private_key = @config.key || ""
	@server.bind_tls "0.0.0.0", @config.sslport || 0, ssl_context
	LOG.debug "Listening on SSL port #{@config.sslport}"
      end
      @server.listen
    end
  end

  def stop
    LOG.debug "Server::stop"
    if @server
      @server.close
    end
  end
end

def doit
  banner = <<-BANNER
cover [options] command [IBSN...]
commands:
  test - test fetching of cover URLs
  save - save a cover image
  init - initialize sqlite3 cache
  server - start cover cache server
BANNER

  config_file = "./cover.yml"

  OptionParser.parse! do |parser|
    parser.banner = banner
    parser.on("-c FILENAME", "--config=FILENAME",
              "Specifies the config filename") { |name| config_file = name }
  end

  # Read config file
  puts "Using config file " + config_file
  config = Config.new(config_file);

  # Must have at least a command name.
  if ARGV.size < 1
    puts banner
    exit 1
  end

  # Set up logging
  LOG.configure(config)

  cmd = ARGV[0]
  case cmd
  when "test"
    isbns = ARGV[1, ARGV.size - 1]
    if isbns.size == 0
      puts "Must specify at least one ISBN"
      return
    end
    fetcher = Fetcher.new(config)
    json = fetcher.get_images_json(isbns, config.providers)
    if json
      puts "JSON: #{json}"
    else
      puts "Unable to get JSON response for #{isbns}"
    end
  when "server"
    server = Server.new(config)
    server.start
    server.stop
  else
    puts "Unrecognized command #{cmd}"
  end
end

doit
